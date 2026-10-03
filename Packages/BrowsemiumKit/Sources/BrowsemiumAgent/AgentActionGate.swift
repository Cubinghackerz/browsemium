import BrowsemiumCore
import BrowsemiumEngineKit
import Foundation
import Observation

/// One line of the in-memory activity record. It names the action, the origin
/// and the outcome. It never holds typed values, tokens or page contents.
public struct AgentAuditEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let time: Date
    public let action: String
    public let origin: String
    public let result: String

    public init(id: UUID = UUID(), time: Date, action: String, origin: String, result: String) {
        self.id = id
        self.time = time
        self.action = action
        self.origin = origin
        self.result = result
    }
}

/// A native confirmation the person must answer before a click or typing runs.
///
/// `role` and `name` come from the page, so they are descriptions the page
/// chose, not evidence of what the control does. A button labelled "Save" can
/// submit an order. The card must present them as "the page calls this ..."
/// and must never imply the action is safe.
public struct AgentApprovalRequest: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case click, type }

    public let id: UUID
    public let taskID: UUID
    public let kind: Kind
    public let origin: AgentOrigin
    public let role: String
    public let name: String
    /// What would be typed, shown only on the confirmation card.
    public let typedText: String?
    public let expiresAt: Date
}

/// The sole path from an external client to a page.
///
/// The native grant (an `AgentTask`) is the authority. Everything a client can
/// send is untrusted: arguments are validated, ownership and scope are checked
/// before the actuator is called **and again after every await**, and page
/// output is normalised on the way back. No tool selects a profile, a data
/// store, an origin outside the grant, or a tab the task does not own.
///
/// Concurrency model: one operation at a time (a second call fails `busy`
/// rather than queueing). Each operation owns a token. Stop, takeover, expiry
/// and scope loss drop the token, so an old completion can neither continue
/// acting nor clear state belonging to a newer operation or task.
///
/// What this gate does **not** establish: that a page behaves harmlessly. A
/// click or keystroke runs arbitrary page handlers whose outcome the browser
/// cannot know, so in v1 every click and type pauses for native confirmation.
/// Reading and in-scope navigation run inside the grant without a prompt.
@MainActor @Observable
public final class AgentActionGate {
    public private(set) var task: AgentTask?
    public private(set) var state: AgentTaskState = .stopped
    public private(set) var tabs: [TabID] = []
    public private(set) var audit: [AgentAuditEntry] = []
    public private(set) var expiresAt: Date?
    public private(set) var callsUsed = 0
    public private(set) var pendingApproval: AgentApprovalRequest?

    /// Native check that the task's profile is still the selected one, the
    /// browser is unlocked, and the profile exists. Defaults to false, so a
    /// gate that nobody wired can never act.
    @ObservationIgnored public var scopeIsAccessible: (UUID) -> Bool = { _ in false }

    @ObservationIgnored private let actuator: any PageActuating
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let approvalTimeout: Duration
    @ObservationIgnored private var activeOperation: UUID?
    @ObservationIgnored private var requestIDs: Set<String> = []
    @ObservationIgnored private var approvalSlot: ApprovalSlot?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?

    private enum ApprovalOutcome { case approved, declined, cancelled }

    private struct ApprovalSlot {
        let id: UUID
        let continuation: CheckedContinuation<ApprovalOutcome, Never>
        let timeout: Task<Void, Never>
    }

    private final class Operation {
        let token = UUID()
        let taskID: UUID
        var origin: String?
        init(taskID: UUID) { self.taskID = taskID }
    }

    public init(
        actuator: any PageActuating,
        now: @escaping () -> Date = Date.init,
        approvalTimeout: Duration = .seconds(AgentLimits.approvalTimeout)
    ) {
        self.actuator = actuator
        self.now = now
        self.approvalTimeout = approvalTimeout
    }

    public var callsRemaining: Int { max(0, AgentLimits.maxCalls - callsUsed) }

    // MARK: - Grant (native only)

    /// Starts a task from a native approval. Only app code that has shown the
    /// grant card may call this; it is not reachable from any tool. The data
    /// store comes from `task`, so no argument can select another profile.
    public func grant(_ task: AgentTask) throws -> TabID {
        guard self.task == nil || state == .finished || state == .stopped,
              scopeIsAccessible(task.profileID) else {
            throw AgentError.denied
        }
        dismissWorkspace()
        self.task = task
        callsUsed = 0
        activeOperation = nil
        requestIDs.removeAll()
        audit.removeAll()
        expiresAt = now().addingTimeInterval(AgentLimits.lifetime)
        state = .ready
        record(task.id, "Started", task.origins.map(\.description).sorted().joined(separator: ", "), "Granted")
        do {
            actuator.setAgentAccess(true)
            let tab = try openTab(for: task)
            scheduleDeadline(for: task.id)
            return tab
        } catch {
            end(.stopped, reason: "Could not start")
            dismissWorkspace()
            throw AgentError.unavailable
        }
    }

    // MARK: - Native controls

    /// The person took over. Authority ends immediately and queued or running
    /// work is invalidated, but the pages stay exactly as they are.
    public func pause() {
        guard task != nil, state.hasAuthority else { return }
        invalidateWork()
        state = .paused
        actuator.setAgentAccess(false)
        recordCurrent("Take over", "Paused")
    }

    /// Hands control back. The 15-minute clock does not stop during takeover.
    /// Pages the person moved off-scope stay unusable until they return.
    public func resume() throws {
        guard let task, state == .paused else { throw AgentError.denied }
        guard enforceDeadline() else { throw state == .finished ? AgentError.expired : AgentError.denied }
        guard scopeIsAccessible(task.profileID) else { end(.stopped, reason: "Scope unavailable"); throw AgentError.denied }
        state = .ready
        actuator.setAgentAccess(true)
        recordCurrent("Resume", "Handed back")
    }

    /// Ends the task. Pages remain for the person unless `closePages` is set.
    public func stop(closePages: Bool = false) {
        end(.stopped, reason: "Stopped")
        if closePages { dismissWorkspace() }
    }

    /// Closes every task-owned page. Locking and profile changes use this so a
    /// locked or switched-away workspace shows nothing.
    public func dismissWorkspace() {
        for tab in tabs { actuator.closeTab(tab) }
        tabs.removeAll()
    }

    public func clientDisconnected(_ client: UUID) {
        guard let task, task.clientID == client, state.hasAuthority || state == .paused else { return }
        end(.stopped, reason: "Client disconnected")
    }

    /// Answers the pending native confirmation. A stale or unknown id is
    /// ignored, so a late click can never approve a different request.
    public func resolveApproval(id: UUID, approved: Bool) {
        resolveApproval(id, approved ? .approved : .declined)
    }

    /// Enforces the deadline and scope. Called before every operation, from the
    /// navigation callback, and by the scheduled timer. Returns whether the
    /// task still holds authority or is paused.
    @discardableResult
    public func enforceDeadline() -> Bool {
        guard let task, state.hasAuthority || state == .paused else { return false }
        if let expiresAt, expiresAt <= now() {
            end(.finished, reason: "Expired")
            return false
        }
        guard scopeIsAccessible(task.profileID) else {
            end(.stopped, reason: "Scope unavailable")
            return false
        }
        return true
    }

    // MARK: - Client calls

    public func status(client: UUID) throws -> AgentStatusSnapshot {
        guard let task, task.clientID == client else { throw AgentError.denied }
        _ = enforceDeadline()
        return AgentStatusSnapshot(
            taskID: task.id,
            title: task.title,
            state: state,
            expiresAt: expiresAt,
            callsRemaining: callsRemaining,
            tabs: tabInfo(),
            permittedOrigins: task.origins.map(\.description).sorted(),
            capabilities: task.capabilities.sorted { $0.rawValue < $1.rawValue }
        )
    }

    public func listTabs(client: UUID) throws -> [AgentTabInfo] {
        guard let task, task.clientID == client, enforceDeadline(), state.hasAuthority else {
            throw AgentError.denied
        }
        return tabInfo()
    }

    /// The client reports it is done. Not a tool call, so it spends no budget.
    public func finish(client: UUID) throws {
        guard let task, task.clientID == client else { throw AgentError.denied }
        end(.finished, reason: "Finished by client")
    }

    public func addTab(client: UUID, requestID: String) async throws -> TabID {
        try await run("Open tab", client: client, capability: .navigate, tab: nil, requestID: requestID) { _ in
            guard let task = self.task else { throw AgentError.denied }
            guard self.tabs.count < AgentLimits.maxTabs else { throw AgentError.tabLimit }
            return try self.openTab(for: task)
        }
    }

    public func navigate(client: UUID, tab: TabID, url: URL, requestID: String) async throws {
        try await run("Navigate", client: client, capability: .navigate, tab: tab, requestID: requestID) { op in
            guard url.absoluteString.utf8.count <= 2_048 else { throw AgentError.invalidArguments }
            let target = try AgentOrigin(url)
            op.origin = target.description
            guard self.task?.origins.contains(target) == true else { throw AgentError.denied }
            // The page being left may be anywhere (the person may have moved
            // it); only the destination must be in scope.
            _ = try self.verify(op, tab: tab, requireOrigin: false)
            try await self.actuator.navigate(tab, to: url)
            _ = try self.verify(op, tab: tab, requireOrigin: true)
        }
    }

    public func snapshot(client: UUID, tab: TabID, requestID: String) async throws -> AgentPageSnapshot {
        try await run("Snapshot", client: client, capability: .read, tab: tab, requestID: requestID) { op in
            let origin = try self.requireOrigin(self.verify(op, tab: tab, requireOrigin: true))
            let value = try await self.actuator.snapshot(tab)
            let after = try self.requireOrigin(self.verify(op, tab: tab, requireOrigin: true))
            guard value.origin == origin, after == origin,
                  value.elements.allSatisfy({ $0.origin == origin }) else { throw AgentError.denied }
            let limit = AgentLimits.maxSnapshotElements
            return AgentPageSnapshot(
                title: String(value.title.prefix(300)),
                origin: origin,
                elements: Array(value.elements.prefix(limit)),
                isTruncated: value.isTruncated || value.elements.count > limit
            )
        }
    }

    public func readText(client: UUID, tab: TabID, requestID: String) async throws -> String {
        try await run("Read", client: client, capability: .read, tab: tab, requestID: requestID) { op in
            _ = try self.verify(op, tab: tab, requireOrigin: true)
            let value = try await self.actuator.readText(tab)
            _ = try self.verify(op, tab: tab, requireOrigin: true)
            return String(value.prefix(AgentLimits.maxReadCharacters))
        }
    }

    public func screenshot(client: UUID, tab: TabID, requestID: String) async throws -> Data {
        try await run("Screenshot", client: client, capability: .screenshot, tab: tab, requestID: requestID) { op in
            _ = try self.verify(op, tab: tab, requireOrigin: true)
            let value = try await self.actuator.screenshot(tab)
            _ = try self.verify(op, tab: tab, requireOrigin: true)
            guard value.count <= AgentLimits.maxScreenshotBytes else { throw AgentError.unavailable }
            return value
        }
    }

    public func click(client: UUID, tab: TabID, reference: String, requestID: String) async throws {
        try await interact("Click", client: client, tab: tab, reference: reference, text: nil, requestID: requestID)
    }

    public func type(client: UUID, tab: TabID, reference: String, text: String, requestID: String) async throws {
        try await interact("Type", client: client, tab: tab, reference: reference, text: text, requestID: requestID)
    }

    // MARK: - Interaction

    private func interact(
        _ name: String,
        client: UUID,
        tab: TabID,
        reference: String,
        text: String?,
        requestID: String
    ) async throws {
        try await run(name, client: client, capability: .interact, tab: tab, requestID: requestID) { op in
            guard !reference.isEmpty, reference.count <= AgentLimits.maxReferenceLength,
                  (text?.utf8.count ?? 0) <= AgentLimits.maxTypedBytes else {
                throw AgentError.invalidArguments
            }
            let origin = try self.requireOrigin(self.verify(op, tab: tab, requireOrigin: true))
            let element = try await self.actuator.resolve(reference, in: tab)
            let afterResolve = try self.requireOrigin(self.verify(op, tab: tab, requireOrigin: true))
            guard element.origin == origin, afterResolve == origin else { throw AgentError.denied }
            guard !element.isSensitive else { throw AgentError.sensitiveField }
            if text != nil, !element.isEditable { throw AgentError.denied }
            let action: AgentPageAction = text.map { .type(element, $0) } ?? .click(element)

            // Arbitrary page handlers make every click or keystroke an unknown
            // outcome. Labels cannot prove otherwise, so ask the person.
            state = .waiting
            let outcome = await self.requestApproval(for: action, origin: origin, op: op)
            switch outcome {
            case .approved: break
            case .declined: throw AgentError.declined
            case .cancelled: throw AgentError.denied
            }
            let afterApproval = try self.requireOrigin(self.verify(op, tab: tab, requireOrigin: true))
            guard afterApproval == origin else { throw AgentError.denied }

            state = .acting
            let current = try await self.actuator.resolve(reference, in: tab)
            _ = try self.verify(op, tab: tab, requireOrigin: true)
            guard current == element, !current.isSensitive else { throw AgentError.staleElement }
            try await self.actuator.perform(action, in: tab)
            // Past this point the page has already acted; report the truth
            // rather than a denial that would hide it.
        }
    }

    private func requestApproval(
        for action: AgentPageAction,
        origin: AgentOrigin,
        op: Operation
    ) async -> ApprovalOutcome {
        let element = action.element
        let typed: String?
        let kind: AgentApprovalRequest.Kind
        switch action {
        case .click: kind = .click; typed = nil
        case .type(_, let text): kind = .type; typed = text
        }
        let request = AgentApprovalRequest(
            id: UUID(),
            taskID: op.taskID,
            kind: kind,
            origin: origin,
            role: String(element.role.prefix(60)),
            name: String(element.name.prefix(200)),
            typedText: typed,
            expiresAt: now().addingTimeInterval(TimeInterval(approvalTimeout.components.seconds))
        )
        let limit = approvalTimeout
        return await withCheckedContinuation { continuation in
            let id = request.id
            let timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                self?.resolveApproval(id, .declined)
            }
            approvalSlot = ApprovalSlot(id: id, continuation: continuation, timeout: timeout)
            pendingApproval = request
        }
    }

    private func resolveApproval(_ id: UUID, _ outcome: ApprovalOutcome) {
        guard let slot = approvalSlot, slot.id == id else { return }
        approvalSlot = nil
        pendingApproval = nil
        slot.timeout.cancel()
        slot.continuation.resume(returning: outcome)
    }

    private func cancelApproval() {
        if let slot = approvalSlot { resolveApproval(slot.id, .cancelled) }
    }

    // MARK: - Operation plumbing

    /// Runs one serialized, budgeted operation. Every error leaves through the
    /// same path, so the in-flight marker is always released, and only for the
    /// operation that set it.
    private func run<T>(
        _ name: String,
        client: UUID,
        capability: AgentCapability,
        tab: TabID?,
        requestID: String,
        _ body: @MainActor (Operation) async throws -> T
    ) async throws -> T {
        let op = try begin(client: client, capability: capability, tab: tab, requestID: requestID)
        state = capability == .read || capability == .screenshot ? .reading : .acting
        do {
            let value = try await body(op)
            complete(op, name: name, tab: tab, result: "Finished")
            return value
        } catch {
            let mapped = Self.map(error)
            complete(op, name: name, tab: tab, result: Self.auditResult(for: mapped))
            throw mapped
        }
    }

    private func begin(client: UUID, capability: AgentCapability, tab: TabID?, requestID: String) throws -> Operation {
        guard let task, task.clientID == client, task.capabilities.contains(capability) else {
            throw AgentError.denied
        }
        guard state.hasAuthority else { throw state == .finished ? AgentError.expired : AgentError.denied }
        guard enforceDeadline() else { throw state == .finished ? AgentError.expired : AgentError.denied }
        if let tab, !tabs.contains(tab) { throw AgentError.denied }
        guard activeOperation == nil else { throw AgentError.busy }
        guard !requestID.isEmpty, requestID.count <= AgentLimits.maxRequestIDLength,
              !requestIDs.contains(requestID) else { throw AgentError.denied }
        guard callsUsed < AgentLimits.maxCalls else {
            end(.finished, reason: "Call limit reached")
            throw AgentError.expired
        }
        requestIDs.insert(requestID)
        callsUsed += 1
        let op = Operation(taskID: task.id)
        activeOperation = op.token
        return op
    }

    /// Re-validates everything after an await. Throws if this operation was
    /// invalidated, the task changed, authority ended, the tab is no longer
    /// owned, or the page is outside the grant. With `requireOrigin` false the
    /// caller is about to leave the page, so its current origin is neither
    /// required nor judged; the destination is checked by the caller.
    private func verify(_ op: Operation, tab: TabID, requireOrigin: Bool) throws -> AgentOrigin? {
        guard activeOperation == op.token, let task, task.id == op.taskID, state.hasAuthority else {
            throw AgentError.denied
        }
        guard enforceDeadline() else { throw state == .finished ? AgentError.expired : AgentError.denied }
        guard tabs.contains(tab) else { throw AgentError.denied }
        guard requireOrigin else { return nil }
        guard let origin = actuator.currentOrigin(tab) else { throw AgentError.unavailable }
        op.origin = origin.description
        guard task.origins.contains(origin) else { throw AgentError.denied }
        return origin
    }

    private func requireOrigin(_ origin: AgentOrigin?) throws -> AgentOrigin {
        guard let origin else { throw AgentError.unavailable }
        return origin
    }

    private func complete(_ op: Operation, name: String, tab: TabID?, result: String) {
        let origin = op.origin ?? tab.flatMap { actuator.currentOrigin($0)?.description } ?? ""
        let interrupted = activeOperation != op.token
        record(op.taskID, name, origin, interrupted && result == "Failed" ? "Interrupted" : result)
        guard !interrupted else { return }
        activeOperation = nil
        if state.hasAuthority { state = .ready }
        if callsUsed >= AgentLimits.maxCalls { end(.finished, reason: "Call limit reached") }
    }

    private func openTab(for task: AgentTask) throws -> TabID {
        let id = TabID()
        let taskID = task.id
        try actuator.createTab(id, dataStoreID: task.dataStoreID) { [weak self] url in
            guard let self, self.task?.id == taskID, self.state.hasAuthority, self.enforceDeadline(),
                  let origin = try? AgentOrigin(url) else { return false }
            return self.task?.origins.contains(origin) == true
        }
        tabs.append(id)
        return id
    }

    private func invalidateWork() {
        activeOperation = nil
        cancelApproval()
    }

    private func end(_ newState: AgentTaskState, reason: String) {
        guard task != nil, state != .stopped, state != .finished else { return }
        invalidateWork()
        deadlineTask?.cancel()
        deadlineTask = nil
        state = newState
        expiresAt = nil
        actuator.setAgentAccess(false)
        recordCurrent(reason, newState == .finished ? "Finished" : "Stopped")
    }

    private func scheduleDeadline(for taskID: UUID) {
        deadlineTask?.cancel()
        deadlineTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.deadlineDelay(for: taskID) else { return }
                if delay <= 0 {
                    self?.enforceDeadline()
                    return
                }
                try? await Task.sleep(for: .seconds(min(delay, 30)))
            }
        }
    }

    private func deadlineDelay(for taskID: UUID) -> TimeInterval? {
        guard task?.id == taskID, state.hasAuthority || state == .paused, let expiresAt else { return nil }
        return expiresAt.timeIntervalSince(now())
    }

    private func tabInfo() -> [AgentTabInfo] {
        tabs.map { AgentTabInfo(id: $0.rawValue, origin: actuator.currentOrigin($0)?.description) }
    }

    private func recordCurrent(_ action: String, _ result: String) {
        guard let task else { return }
        record(task.id, action, "", result)
    }

    private func record(_ taskID: UUID, _ action: String, _ origin: String, _ result: String) {
        // An operation that outlives its task must not write into a newer one.
        guard task?.id == taskID else { return }
        audit.append(AgentAuditEntry(time: now(), action: action, origin: origin, result: result))
        if audit.count > AgentLimits.maxAuditEntries {
            audit.removeFirst(audit.count - AgentLimits.maxAuditEntries)
        }
    }

    /// Actuator and WebKit errors can carry page-controlled strings; clients
    /// get a fixed vocabulary instead.
    nonisolated private static func map(_ error: any Error) -> AgentError {
        (error as? AgentError) ?? .unavailable
    }

    nonisolated private static func auditResult(for error: AgentError) -> String {
        switch error {
        case .denied, .sensitiveField, .invalidOrigin: "Denied"
        case .declined: "Declined"
        case .expired: "Expired"
        default: "Failed"
        }
    }
}
