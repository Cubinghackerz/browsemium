import BrowsemiumAgent
import BrowsemiumCore
import BrowsemiumData
import Foundation
import Security
import Testing
@testable import BrowsemiumUI

/// An in-memory keychain that counts decrypting reads, so a test can prove
/// that drawing Settings never asks macOS to decrypt the endpoint token.
private final class AgentTestKeychain: KeychainAPI, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private(set) var reads = 0

    func store(service: String, account: String, data: Data) -> OSStatus {
        values["\(service)|\(account)"] = data
        return errSecSuccess
    }

    func read(service: String, account: String) -> (status: OSStatus, data: Data?) {
        reads += 1
        guard let value = values["\(service)|\(account)"] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, value)
    }

    func delete(service: String, account: String) -> OSStatus {
        values["\(service)|\(account)"] = nil
        return errSecSuccess
    }

    func exists(service: String, account: String) -> Bool {
        values["\(service)|\(account)"] != nil
    }
}

@MainActor
private struct AgentHarness {
    let keychain = AgentTestKeychain()
    let model: BrowserWindowModel
    let coordinator: AgentCoordinator

    var environment: BrowserEnvironment { model.environment }

    init() {
        let store = KeychainStore(service: "agent-coordinator-\(UUID().uuidString)", api: keychain)
        let environment = BrowserEnvironment.inMemory(engine: StubEngine(), keychain: store)
        model = BrowserWindowModel(environment: environment)
        coordinator = environment.agent
        // No NSApplication in tests, no real port, and a deterministic
        // early-approval window (individual tests override it).
        coordinator.showsPanel = false
        coordinator.listenPort = 0
        coordinator.approveWindow = 0
    }

    func request(title: String = "Check a page") throws -> AgentGrantRequest {
        AgentGrantRequest(
            clientID: UUID(),
            clientName: "Fixture client",
            title: title,
            origins: [try AgentOrigin(string: "https://example.com")],
            capabilities: [.read, .navigate]
        )
    }

    /// Starts a grant and waits until the card has been shown.
    func beginGrant(_ request: AgentGrantRequest) async throws -> Task<Void, any Error> {
        let task = Task { @MainActor in try await coordinator.presentGrant(request) }
        try #require(await waitFor { coordinator.pendingGrant != nil })
        return task
    }
}

private func outcome(of task: Task<Void, any Error>) async -> AgentError? {
    do {
        try await task.value
        return nil
    } catch {
        return error as? AgentError
    }
}

// MARK: - Grant

@Test @MainActor
func approvingTheGrantCardStartsTheTaskInTheActiveProfile() async throws {
    let harness = AgentHarness()
    let coordinator = harness.coordinator
    let task = try await harness.beginGrant(harness.request())
    #expect(coordinator.pendingGrant?.request.title == "Check a page")
    #expect(coordinator.gate.task == nil, "Nothing may start before the person answers")

    coordinator.answerGrant(true)

    #expect(await outcome(of: task) == nil)
    #expect(coordinator.pendingGrant == nil)
    #expect(coordinator.gate.state == .ready)
    #expect(coordinator.gate.tabs.count == 1)
    #expect(coordinator.gate.task?.profileID == harness.environment.activeProfile.id)
    #expect(coordinator.gate.task?.dataStoreID == harness.environment.activeProfile.dataStoreUUID)
    #expect(coordinator.selectedTab == coordinator.gate.tabs.first)
}

@Test @MainActor
func decliningTheGrantCardStartsNothing() async throws {
    let harness = AgentHarness()
    let task = try await harness.beginGrant(harness.request())

    harness.coordinator.answerGrant(false)

    #expect(await outcome(of: task) == .declined)
    #expect(harness.coordinator.gate.task == nil)
    #expect(harness.coordinator.gate.tabs.isEmpty)
    #expect(harness.coordinator.pendingGrant == nil)
}

@Test @MainActor
func approvalInsideTheDelayWindowIsIgnored() async throws {
    let harness = AgentHarness()
    harness.coordinator.approveWindow = 3600
    let task = try await harness.beginGrant(harness.request())

    harness.coordinator.answerGrant(true)

    #expect(harness.coordinator.pendingGrant != nil, "A stray click or keystroke must not grant a task")
    #expect(harness.coordinator.gate.task == nil)

    // Declining is always immediate.
    harness.coordinator.answerGrant(false)
    #expect(await outcome(of: task) == .declined)
}

@Test @MainActor
func anUnansweredGrantDeclinesItself() async throws {
    let harness = AgentHarness()
    harness.coordinator.grantTimeout = .milliseconds(60)
    let task = try await harness.beginGrant(harness.request())

    #expect(await outcome(of: task) == .declined)
    #expect(harness.coordinator.pendingGrant == nil)
    #expect(harness.coordinator.gate.task == nil)
}

@Test @MainActor
func aSecondGrantWhileOneIsOpenIsBusyAndDoesNotReplaceTheCard() async throws {
    let harness = AgentHarness()
    let first = try harness.request(title: "First")
    let task = try await harness.beginGrant(first)
    let shownID = harness.coordinator.pendingGrant?.id

    let second = Task { @MainActor in try await harness.coordinator.presentGrant(try harness.request(title: "Second")) }

    #expect(await outcome(of: second) == .busy)
    #expect(harness.coordinator.pendingGrant?.id == shownID)
    #expect(harness.coordinator.pendingGrant?.request.title == "First")

    harness.coordinator.answerGrant(false)
    #expect(await outcome(of: task) == .declined)
}

@Test @MainActor
func aTitleTheCardCouldNotShowFaithfullyIsRefusedBeforeAsking() async throws {
    let harness = AgentHarness()
    // Bidirectional override characters could make the card read differently
    // from what is granted.
    let hostile = try harness.request(title: "Pay \u{202E}gnisrever\u{202C} now")
    let task = Task { @MainActor in try await harness.coordinator.presentGrant(hostile) }

    #expect(await outcome(of: task) != nil)
    #expect(harness.coordinator.pendingGrant == nil, "No card may be shown for text that is not displayable")
    #expect(harness.coordinator.gate.task == nil)
}

// MARK: - Revocation

@Test @MainActor
func switchingProfileEndsARunningTaskAndClosesItsPages() async throws {
    let harness = AgentHarness()
    let task = try await harness.beginGrant(harness.request())
    harness.coordinator.answerGrant(true)
    #expect(await outcome(of: task) == nil)
    #expect(harness.coordinator.gate.state.hasAuthority)

    _ = try #require(harness.model.createProfile(named: "Other", switchToIt: true))

    #expect(!harness.coordinator.gate.state.hasAuthority)
    #expect(harness.coordinator.gate.tabs.isEmpty, "Pages from the old profile must not stay reachable")
    #expect(harness.coordinator.gate.task?.profileID != harness.environment.activeProfile.id)
}

@Test @MainActor
func switchingProfileDismissesAnOpenGrantCard() async throws {
    let harness = AgentHarness()
    let task = try await harness.beginGrant(harness.request())

    _ = try #require(harness.model.createProfile(named: "Other", switchToIt: true))

    #expect(await outcome(of: task) == .declined)
    #expect(harness.coordinator.pendingGrant == nil)
    #expect(harness.coordinator.gate.task == nil)
}

@Test @MainActor
func lockingASpaceEndsARunningTask() async throws {
    let harness = AgentHarness()
    let model = harness.model
    let secret = model.createGroup(named: "Secret")
    model.setSpaceLocked(secret, locked: true)
    model.spaceUnlockAuthenticator = AgentAuthenticator()
    model.switchGroup(secret)
    try #require(await waitFor { model.session.activeSpaceID == secret })

    let task = try await harness.beginGrant(harness.request())
    harness.coordinator.answerGrant(true)
    #expect(await outcome(of: task) == nil)
    #expect(harness.coordinator.gate.state.hasAuthority)

    model.lockSpaceNow(secret)

    #expect(!harness.coordinator.gate.state.hasAuthority)
    #expect(harness.coordinator.gate.tabs.isEmpty)
}

@MainActor
private final class AgentAuthenticator: SpaceUnlockAuthenticating {
    func authenticate(reason: String) async -> Bool { true }
}

@Test @MainActor
func shutdownEndsTheTaskTheEndpointAndTheGrant() async throws {
    let harness = AgentHarness()
    harness.coordinator.setEndpointEnabled(true)
    let task = try await harness.beginGrant(harness.request())
    harness.coordinator.answerGrant(true)
    #expect(await outcome(of: task) == nil)

    harness.environment.runTerminationTasks()

    #expect(!harness.coordinator.gate.state.hasAuthority)
    #expect(harness.coordinator.gate.tabs.isEmpty)
    #expect(harness.coordinator.endpoint == .off)
}

// MARK: - Endpoint and token

@Test @MainActor
func theEndpointIsOffAndOpensNoPortUnlessTheUserTurnedItOn() async throws {
    let harness = AgentHarness()

    harness.coordinator.startIfEnabled()

    #expect(harness.coordinator.endpoint == .off)
    #expect(!harness.coordinator.isEndpointEnabled)
    #expect(!harness.coordinator.tokenExists, "Creating the coordinator must not create a secret")
    #expect(harness.keychain.reads == 0)
}

@Test @MainActor
func enablingTheEndpointListensOnLoopbackAndDisablingStopsIt() async throws {
    let harness = AgentHarness()
    let coordinator = harness.coordinator

    coordinator.setEndpointEnabled(true)
    try #require(await waitFor(timeout: .seconds(10)) {
        if case .listening = coordinator.endpoint { return true }
        return false
    })
    #expect(coordinator.isEndpointEnabled)
    #expect(coordinator.tokenExists)
    let token = try #require(coordinator.revealToken())
    #expect(token.hasPrefix("bm_") && token.count >= 40)

    coordinator.setEndpointEnabled(false)
    #expect(coordinator.endpoint == .off)
    #expect(!coordinator.isEndpointEnabled)
}

@Test @MainActor
func checkingForTheTokenNeverDecryptsIt() async throws {
    let harness = AgentHarness()
    let coordinator = harness.coordinator
    coordinator.setEndpointEnabled(true)
    coordinator.setEndpointEnabled(false)
    let readsAfterCreation = harness.keychain.reads

    coordinator.refreshTokenState()
    coordinator.refreshTokenState()

    #expect(coordinator.tokenExists)
    #expect(harness.keychain.reads == readsAfterCreation, "Opening Settings must not trigger a keychain prompt")
}

@Test @MainActor
func rotatingTheTokenReplacesItAndKeepsTheEndpointRunning() async throws {
    let harness = AgentHarness()
    let coordinator = harness.coordinator
    coordinator.setEndpointEnabled(true)
    let before = try #require(coordinator.revealToken())

    coordinator.rotateToken()

    let after = try #require(coordinator.revealToken())
    #expect(after != before)
    #expect(coordinator.notice?.contains("replaced") == true)
    try #require(await waitFor(timeout: .seconds(10)) {
        if case .listening = coordinator.endpoint { return true }
        return false
    })
    coordinator.setEndpointEnabled(false)
}

@Test @MainActor
func generatedTokensAreLongUniqueAndURLSafe() {
    let tokens = (0..<50).map { _ in AgentCoordinator.makeToken() }
    #expect(Set(tokens).count == tokens.count)
    for token in tokens {
        #expect(token.count >= 40)
        #expect(token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
    }
}

@Test @MainActor
func clientConfigurationTextCarriesTheTokenAndTheFixedLoopbackAddress() {
    let command = AgentCoordinator.claudeCodeCommand(token: "bm_fixture")
    #expect(command.contains("http://127.0.0.1:\(AgentCoordinator.port)/mcp"))
    #expect(command.contains("Authorization: Bearer bm_fixture"))

    let json = AgentCoordinator.jsonConfiguration(token: "bm_fixture")
    let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    let servers = object?["mcpServers"] as? [String: Any]
    let entry = servers?["browsemium"] as? [String: Any]
    #expect(entry?["url"] as? String == "http://127.0.0.1:\(AgentCoordinator.port)/mcp")
    #expect((entry?["headers"] as? [String: String])?["Authorization"] == "Bearer bm_fixture")
}
