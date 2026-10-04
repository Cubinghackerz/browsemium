import AppKit
import BrowsemiumAgent
import BrowsemiumCore
import BrowsemiumData
import BrowsemiumEngine
import BrowsemiumEngineKit
import Foundation
import Observation
import os
import Security

/// Owns the one external-agent task, its pages, the local MCP endpoint and the
/// native grant flow. Everything an agent can do passes through `gate`; this
/// type only decides *when* a person's approval exists and wires lifecycle
/// events (profile change, lock, quit) to revocation.
@MainActor
@Observable
public final class AgentCoordinator {
    public enum EndpointState: Equatable, Sendable {
        case off
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    /// A grant waiting for the person. Everything shown on the card derives
    /// from here, so the text the person approves is the text that is granted.
    public struct PendingGrant: Identifiable, Equatable {
        public let id = UUID()
        public let request: AgentGrantRequest
        public let shownAt: Date
    }

    /// Fixed so client configuration keeps working across launches.
    public static let port: UInt16 = 47831
    public static let enabledDefaultsKey = "browsemium.agent.endpointEnabled"
    static let tokenAccount = "agent.mcp.endpoint-token"
    private static let log = Logger(subsystem: "com.browsemium.agent", category: "coordinator")
    /// An unanswered grant declines itself.
    public static let grantTimeout: Duration = .seconds(120)
    /// Approval is ignored this soon after the card appears, so a keystroke or
    /// click aimed at something else cannot grant a task.
    public static let approveDelay: TimeInterval = 0.8

    public let gate: AgentActionGate
    public let actuator: WebKitPageActuator
    public private(set) var endpoint: EndpointState = .off
    public private(set) var pendingGrant: PendingGrant?
    public private(set) var tokenExists = false
    public private(set) var notice: String?
    public var selectedTab: TabID?

    @ObservationIgnored private weak var environment: BrowserEnvironment?
    @ObservationIgnored private var server: MCPHTTPServer?
    @ObservationIgnored private var grantWaiter: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var grantTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var panelController: AgentPanelController?
    /// How long an unanswered grant waits. Instance-level so tests need not
    /// wait two minutes; production keeps the static default.
    @ObservationIgnored var grantTimeout: Duration = AgentCoordinator.grantTimeout
    /// Tests run without an NSApplication, so they turn the real window off.
    @ObservationIgnored var showsPanel = true
    /// Port 0 (a free port) in tests; the fixed port in the app.
    @ObservationIgnored var listenPort: UInt16 = AgentCoordinator.port
    /// The early-approval window answerGrant enforces. Instance-level so tests
    /// can make it deterministic; the card's own button arming uses the static.
    @ObservationIgnored var approveWindow: TimeInterval = AgentCoordinator.approveDelay

    public init(environment: BrowserEnvironment) {
        self.environment = environment
        let actuator = WebKitPageActuator()
        self.actuator = actuator
        self.gate = AgentActionGate(actuator: actuator)
        // Defaults to false in the gate; only a task whose profile is still
        // the one in force may act.
        gate.scopeIsAccessible = { [weak environment] profileID in
            environment?.activeProfile.id == profileID
        }
        refreshTokenState()
    }

    // MARK: - Endpoint

    /// The profile a grant would apply to, read live.
    public var profileName: String { environment?.activeProfile.name ?? "" }

    public var isEndpointEnabled: Bool {
        environment?.userDefaults.bool(forKey: Self.enabledDefaultsKey) ?? false
    }

    /// Called once at launch. Does nothing unless the person turned the
    /// endpoint on; the default install opens no port.
    public func startIfEnabled() {
        if isEndpointEnabled { startEndpoint() }
    }

    public func setEndpointEnabled(_ enabled: Bool) {
        environment?.userDefaults.set(enabled, forKey: Self.enabledDefaultsKey)
        if enabled { startEndpoint() } else { stopEndpoint() }
    }

    private func startEndpoint() {
        guard server == nil else { return }
        do {
            let token = try existingOrNewToken()
            let service = MCPService(gate: gate, serverVersion: Self.appVersion) { [weak self] request in
                guard let self else { throw AgentError.unavailable }
                try await self.presentGrant(request)
            }
            let server = MCPHTTPServer(service: service, token: token, port: listenPort)
            server.onStateChange = { [weak self] state in self?.endpointChanged(state) }
            self.server = server
            notice = nil
            server.start()
        } catch {
            Self.log.error("Endpoint could not start: \(String(describing: error), privacy: .public)")
            endpoint = .failed("The access token could not be read or saved.")
        }
        refreshTokenState()
    }

    private func stopEndpoint() {
        server?.stop()
        server = nil
        endpoint = .off
    }

    private func endpointChanged(_ state: MCPHTTPServer.State) {
        Self.log.notice("Endpoint state: \(String(describing: state), privacy: .public)")
        switch state {
        case .stopped: endpoint = .off
        case .starting: endpoint = .starting
        case .listening(let port): endpoint = .listening(port: port)
        case .failed(let message):
            endpoint = .failed(message)
            server = nil
        }
    }

    // MARK: - Token

    public func refreshTokenState() {
        tokenExists = (try? environment?.keychain.hasSecret(account: Self.tokenAccount)) == true
    }

    /// Reads the token to hand it to the person. Only an explicit "Copy"
    /// action calls this; drawing Settings never decrypts it.
    public func revealToken() -> String? {
        try? environment?.keychain.secret(account: Self.tokenAccount)
    }

    /// Replaces the token. Every client holding the old one stops working and
    /// any running task ends with its session.
    public func rotateToken() {
        guard let environment else { return }
        let wasRunning = server != nil
        if wasRunning { stopEndpoint() }
        var rotated = false
        do {
            try environment.keychain.setSecret(Self.makeToken(), account: Self.tokenAccount)
            rotated = true
        } catch {}
        refreshTokenState()
        if wasRunning { startEndpoint() }
        // After the restart: starting an endpoint clears any earlier notice.
        notice = rotated
            ? "The access token was replaced. Update your agent client."
            : "The access token could not be replaced."
    }

    private func existingOrNewToken() throws -> String {
        guard let environment else { throw AgentError.unavailable }
        if let existing = try environment.keychain.secret(account: Self.tokenAccount), !existing.isEmpty {
            return existing
        }
        let token = Self.makeToken()
        try environment.keychain.setSecret(token, account: Self.tokenAccount)
        return token
    }

    /// 256 bits from the system CSPRNG, URL-safe.
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "The system random generator failed.")
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "bm_" + encoded
    }

    // MARK: - Grant

    /// Shows the native grant card and returns once the person has decided.
    /// Throws `.declined` for a decline or a timeout.
    func presentGrant(_ request: AgentGrantRequest) async throws {
        guard let environment else { throw AgentError.unavailable }
        guard pendingGrant == nil, grantWaiter == nil else { throw AgentError.busy }
        // Refuse unusable text before asking: a title the card could not
        // display faithfully must never reach the person.
        _ = try AgentTask(
            clientID: request.clientID, clientName: request.clientName, title: request.title,
            profileID: environment.activeProfile.id, dataStoreID: environment.activeProfile.dataStoreUUID,
            origins: Set(request.origins), capabilities: request.capabilities
        )

        pendingGrant = PendingGrant(request: request, shownAt: Date())
        showPanel(attention: true)
        let approved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            grantWaiter = continuation
            grantTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: self?.grantTimeout ?? Self.grantTimeout)
                guard !Task.isCancelled else { return }
                self?.finishGrant(false)
            }
        }
        guard approved else {
            if gate.task == nil { closePanelIfIdle() }
            throw AgentError.declined
        }

        // The profile in force now is the profile the card named: the card
        // reads it live, and a switch while it was open dismissed the card.
        let profile = environment.activeProfile
        let task = try AgentTask(
            clientID: request.clientID, clientName: request.clientName, title: request.title,
            profileID: profile.id, dataStoreID: profile.dataStoreUUID,
            origins: Set(request.origins), capabilities: request.capabilities
        )
        let first = try gate.grant(task)
        selectedTab = first
        showPanel(attention: false)
    }

    /// The person's answer on the grant card.
    public func answerGrant(_ approved: Bool) {
        guard let pending = pendingGrant else { return }
        if approved, Date().timeIntervalSince(pending.shownAt) < approveWindow { return }
        finishGrant(approved)
    }

    private func finishGrant(_ approved: Bool) {
        grantTimeoutTask?.cancel()
        grantTimeoutTask = nil
        pendingGrant = nil
        let waiter = grantWaiter
        grantWaiter = nil
        waiter?.resume(returning: approved)
    }

    // MARK: - Native controls

    public func takeOver() { gate.pause() }
    public func handBack() { try? gate.resume() }
    public func stopTask() { gate.stop() }

    /// Ends the task and removes its pages and window.
    public func closeWorkspace() {
        gate.stop(closePages: true)
        finishGrant(false)
        panelController?.close()
    }

    // MARK: - Revocation hooks

    /// The selected profile changed or a space locked: nothing from the old
    /// context may stay visible or actionable.
    public func contextBecameUnavailable() {
        finishGrant(false)
        guard gate.task != nil else { return }
        gate.stop(closePages: true)
        panelController?.close()
    }

    /// App quit or endpoint teardown.
    public func shutdown() {
        stopEndpoint()
        finishGrant(false)
        gate.stop(closePages: true)
        panelController?.close()
    }

    // MARK: - Panel

    private func showPanel(attention: Bool) {
        guard showsPanel else { return }
        if panelController == nil { panelController = AgentPanelController(coordinator: self) }
        panelController?.show(attention: attention)
    }

    private func closePanelIfIdle() {
        guard gate.task == nil || !(gate.state.hasAuthority || gate.state == .paused) else { return }
        panelController?.close()
    }

    /// The person closed the window: that is a Stop.
    func panelDidClose() {
        finishGrant(false)
        if gate.task != nil { gate.stop(closePages: true) }
    }

    func requestAttention() {
        showPanel(attention: true)
    }

    // MARK: - Client configuration text

    public static func claudeCodeCommand(token: String) -> String {
        "claude mcp add --transport http browsemium http://127.0.0.1:\(port)/mcp --header \"Authorization: Bearer \(token)\""
    }

    public static func jsonConfiguration(token: String) -> String {
        """
        {
          "mcpServers": {
            "browsemium": {
              "type": "http",
              "url": "http://127.0.0.1:\(port)/mcp",
              "headers": { "Authorization": "Bearer \(token)" }
            }
          }
        }
        """
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}
