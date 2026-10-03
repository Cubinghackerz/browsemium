import BrowsemiumAgent
import BrowsemiumCore
import BrowsemiumEngineKit
import Foundation
import Testing

/// Holds an actuator call open until a test releases it, so a test can change
/// authority (Stop, takeover, expiry) while work is genuinely in flight.
@MainActor
final class Latch {
    private(set) var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
        isWaiting = false
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

final class FakeClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds) }
}

/// Records every call and, crucially, every call made while agent access was
/// off. The gate must never produce one, so tests assert `violations.isEmpty`.
@MainActor
final class FakeActuator: PageActuating {
    private(set) var calls: [String] = []
    private(set) var violations: [String] = []
    private(set) var createdStores: [UUID] = []
    private(set) var closed: [TabID] = []
    private(set) var accessEnabled = false
    private(set) var performed: [AgentPageAction] = []
    private(set) var resolveCount = 0

    var origins: [TabID: AgentOrigin] = [:]
    var authorizers: [TabID: @MainActor (URL) -> Bool] = [:]
    var elements: [String: AgentElement] = [:]
    var snapshotValue: AgentPageSnapshot?
    var textValue = "page text"
    var screenshotValue = Data([1, 2, 3])
    var latches: [String: Latch] = [:]
    var failures: [String: any Error] = [:]
    var resolveHook: (@MainActor (Int) -> Void)?
    /// Navigations that redirect: requested host -> final URL.
    var redirects: [String: URL] = [:]

    private func enter(_ name: String) async throws {
        calls.append(name)
        if !accessEnabled { violations.append(name) }
        if let latch = latches[name] { await latch.wait() }
        if let failure = failures[name] { throw failure }
    }

    func createTab(
        _ id: TabID,
        dataStoreID: UUID,
        authorizeNavigation: @escaping @MainActor (URL) -> Bool
    ) throws {
        calls.append("createTab")
        if !accessEnabled { violations.append("createTab") }
        if let failure = failures["createTab"] { throw failure }
        createdStores.append(dataStoreID)
        authorizers[id] = authorizeNavigation
    }

    func setAgentAccess(_ enabled: Bool) {
        accessEnabled = enabled
    }

    func closeTab(_ id: TabID) {
        closed.append(id)
    }

    func currentOrigin(_ id: TabID) -> AgentOrigin? { origins[id] }

    func navigate(_ id: TabID, to url: URL) async throws {
        try await enter("navigate")
        var final = url
        // Mirrors the real actuator: each hop is authorized before it loads.
        if let authorize = authorizers[id] {
            guard authorize(url) else { throw AgentError.denied }
            if let next = redirects[url.host ?? ""] {
                guard authorize(next) else { throw AgentError.denied }
                final = next
            }
        }
        origins[id] = try AgentOrigin(final)
    }

    func snapshot(_ id: TabID) async throws -> AgentPageSnapshot {
        try await enter("snapshot")
        guard let value = snapshotValue, origins[id] != nil else { throw AgentError.unavailable }
        return value
    }

    func readText(_ id: TabID) async throws -> String {
        try await enter("readText")
        return textValue
    }

    func screenshot(_ id: TabID) async throws -> Data {
        try await enter("screenshot")
        return screenshotValue
    }

    func resolve(_ reference: String, in id: TabID) async throws -> AgentElement {
        try await enter("resolve")
        resolveCount += 1
        resolveHook?(resolveCount)
        guard let element = elements[reference] else { throw AgentError.staleElement }
        return element
    }

    func perform(_ action: AgentPageAction, in id: TabID) async throws {
        try await enter("perform")
        performed.append(action)
    }
}

/// A granted task over a fake actuator and a controllable clock.
@MainActor
final class GateHarness {
    let actuator = FakeActuator()
    let clock = FakeClock()
    let gate: AgentActionGate
    let client = UUID()
    let profileID = UUID()
    let dataStoreID = UUID()
    let origin: AgentOrigin
    var task: AgentTask
    var tab: TabID?
    var scopeOpen = true
    private var counter = 0

    init(
        capabilities: Set<AgentCapability> = [.read, .navigate, .interact],
        approvalTimeout: Duration = .seconds(120),
        grant: Bool = true
    ) throws {
        let clock = self.clock
        gate = AgentActionGate(actuator: actuator, now: { clock.date }, approvalTimeout: approvalTimeout)
        origin = try AgentOrigin(string: "https://fixture.test")
        task = try AgentTask(
            clientID: client,
            clientName: "Fixture client",
            title: "Fixture task",
            profileID: profileID,
            dataStoreID: dataStoreID,
            origins: [origin],
            capabilities: capabilities
        )
        gate.scopeIsAccessible = { [weak self] _ in self?.scopeOpen ?? false }
        if grant { try start() }
    }

    @discardableResult
    func start() throws -> TabID {
        let created = try gate.grant(task)
        tab = created
        actuator.origins[created] = origin
        return created
    }

    func newTask(client: UUID? = nil) throws -> AgentTask {
        try AgentTask(
            clientID: client ?? self.client,
            clientName: "Second client",
            title: "Second task",
            profileID: profileID,
            dataStoreID: dataStoreID,
            origins: [origin],
            capabilities: [.read, .navigate, .interact]
        )
    }

    var requestID: String {
        counter += 1
        return "request-\(counter)"
    }

    @discardableResult
    func element(
        id: String = "e1",
        role: String = "button",
        name: String = "Continue",
        fingerprint: String = "fp-1",
        editable: Bool = false,
        sensitive: Bool = false,
        origin: AgentOrigin? = nil
    ) -> AgentElement {
        let value = AgentElement(
            id: id,
            role: role,
            name: name,
            origin: origin ?? self.origin,
            fingerprint: fingerprint,
            isEditable: editable,
            isSensitive: sensitive
        )
        actuator.elements[id] = value
        return value
    }

    /// Waits for a condition on the main actor without a fixed sleep.
    func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    func approveNext(_ approved: Bool = true) async -> AgentApprovalRequest? {
        guard await waitUntil({ self.gate.pendingApproval != nil }),
              let request = gate.pendingApproval else { return nil }
        gate.resolveApproval(id: request.id, approved: approved)
        return request
    }
}

/// Asserts that `operation` throws exactly `expected`.
@MainActor
func expectAgentError<T>(
    _ expected: AgentError,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        Issue.record("Expected \(expected) but the call succeeded", sourceLocation: sourceLocation)
    } catch {
        #expect((error as? AgentError) == expected, "Got \(error)", sourceLocation: sourceLocation)
    }
}
