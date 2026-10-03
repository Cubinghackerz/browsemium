import BrowsemiumAgent
import BrowsemiumCore
import Foundation
import Testing

// MARK: - Grant and scope

@Suite("Agent gate: grant and scope") @MainActor
struct AgentGateGrantTests {
    @Test func aGateNobodyWiredCanNeverStartATask() throws {
        let actuator = FakeActuator()
        let gate = AgentActionGate(actuator: actuator)
        let harness = try GateHarness(grant: false)
        #expect(throws: AgentError.denied) { _ = try gate.grant(harness.task) }
        #expect(actuator.calls.isEmpty)
    }

    @Test func grantRefusesWhenTheProfileScopeIsNotAccessible() throws {
        let harness = try GateHarness(grant: false)
        harness.scopeOpen = false
        #expect(throws: AgentError.denied) { _ = try harness.start() }
        #expect(harness.actuator.calls.isEmpty)
        #expect(harness.gate.state == .stopped)
    }

    @Test func theDataStoreComesFromTheGrantNotFromAnyArgument() throws {
        let harness = try GateHarness()
        #expect(harness.actuator.createdStores == [harness.dataStoreID])
    }

    @Test func everyAddedTabUsesTheGrantedDataStore() async throws {
        let harness = try GateHarness()
        _ = try await harness.gate.addTab(client: harness.client, requestID: harness.requestID)
        _ = try await harness.gate.addTab(client: harness.client, requestID: harness.requestID)
        #expect(harness.actuator.createdStores == Array(repeating: harness.dataStoreID, count: 3))
    }

    @Test func noToolReachesTheActuatorWithoutAValidGrant() async throws {
        let actuator = FakeActuator()
        let gate = AgentActionGate(actuator: actuator)
        gate.scopeIsAccessible = { _ in true }
        let client = UUID(), tab = TabID()
        let url = try #require(URL(string: "https://fixture.test/"))
        await expectAgentError(.denied) { try await gate.navigate(client: client, tab: tab, url: url, requestID: "a") }
        await expectAgentError(.denied) { _ = try await gate.snapshot(client: client, tab: tab, requestID: "b") }
        await expectAgentError(.denied) { _ = try await gate.readText(client: client, tab: tab, requestID: "c") }
        await expectAgentError(.denied) { _ = try await gate.screenshot(client: client, tab: tab, requestID: "d") }
        await expectAgentError(.denied) { try await gate.click(client: client, tab: tab, reference: "e1", requestID: "e") }
        await expectAgentError(.denied) { try await gate.type(client: client, tab: tab, reference: "e1", text: "x", requestID: "f") }
        await expectAgentError(.denied) { _ = try await gate.addTab(client: client, requestID: "g") }
        #expect(actuator.calls.isEmpty)
    }

    @Test func aDifferentClientCannotUseAnotherClientsTask() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        let intruder = UUID()
        let url = try #require(URL(string: "https://fixture.test/x"))
        await expectAgentError(.denied) { try await harness.gate.navigate(client: intruder, tab: tab, url: url, requestID: "x") }
        await expectAgentError(.denied) { _ = try await harness.gate.readText(client: intruder, tab: tab, requestID: "y") }
        #expect(throws: AgentError.denied) { _ = try harness.gate.status(client: intruder) }
        #expect(throws: AgentError.denied) { _ = try harness.gate.listTabs(client: intruder) }
        #expect(harness.actuator.calls == ["createTab"])
        #expect(harness.gate.callsUsed == 0)
    }

    @Test func aCapabilityTheGrantLacksIsDenied() async throws {
        let harness = try GateHarness(capabilities: [.read, .navigate])
        let tab = try #require(harness.tab)
        await expectAgentError(.denied) { _ = try await harness.gate.screenshot(client: harness.client, tab: tab, requestID: "s") }
        await expectAgentError(.denied) { try await harness.gate.click(client: harness.client, tab: tab, reference: "e1", requestID: "c") }
        #expect(!harness.actuator.calls.contains("screenshot"))
        #expect(!harness.actuator.calls.contains("resolve"))
    }

    @Test func aSecondGrantIsRefusedWhileATaskIsActive() throws {
        let harness = try GateHarness()
        let other = try harness.newTask()
        #expect(throws: AgentError.denied) { _ = try harness.gate.grant(other) }
        #expect(harness.gate.task?.id == harness.task.id)
    }

    @Test func aPausedTaskStillBlocksANewGrant() throws {
        let harness = try GateHarness()
        harness.gate.pause()
        let other = try harness.newTask()
        #expect(throws: AgentError.denied) { _ = try harness.gate.grant(other) }
    }

    @Test func aNewGrantResetsBudgetAuditAndClosesTheOldWorkspace() async throws {
        let harness = try GateHarness()
        let oldTab = try #require(harness.tab)
        _ = try await harness.gate.readText(client: harness.client, tab: oldTab, requestID: harness.requestID)
        harness.gate.stop()
        harness.task = try harness.newTask()
        _ = try harness.start()
        #expect(harness.gate.callsUsed == 0)
        #expect(harness.gate.audit.map(\.action) == ["Started"])
        #expect(harness.actuator.closed == [oldTab])
    }

    @Test func aFailedTabCreationLeavesNoAuthorityBehind() throws {
        let harness = try GateHarness(grant: false)
        harness.actuator.failures["createTab"] = AgentError.unavailable
        #expect(throws: AgentError.unavailable) { _ = try harness.start() }
        #expect(harness.gate.state == .stopped)
        #expect(!harness.actuator.accessEnabled)
    }
}

// MARK: - Expiry and budget

@Suite("Agent gate: expiry and budget") @MainActor
struct AgentGateBudgetTests {
    @Test func theGrantExpiresAfterFifteenMinutesWithoutTouchingTheActuator() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        harness.clock.advance(15 * 60 + 1)
        let before = harness.actuator.calls.count
        await expectAgentError(.expired) { _ = try await harness.gate.readText(client: harness.client, tab: tab, requestID: "late") }
        #expect(harness.gate.state == .finished)
        #expect(!harness.actuator.accessEnabled)
        #expect(harness.actuator.calls.count == before)
    }

    @Test func aCallJustInsideTheDeadlineStillRuns() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        harness.clock.advance(15 * 60 - 1)
        let text = try await harness.gate.readText(client: harness.client, tab: tab, requestID: "ok")
        #expect(text == "page text")
    }

    @Test func theNavigationCallbackRefusesAfterExpiry() throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        let authorize = try #require(harness.actuator.authorizers[tab])
        let url = try #require(URL(string: "https://fixture.test/page"))
        #expect(authorize(url))
        harness.clock.advance(15 * 60 + 1)
        #expect(!authorize(url))
        #expect(harness.gate.state == .finished)
    }

    @Test func theHundredthCallEndsTheTask() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        for _ in 0..<100 {
            _ = try await harness.gate.readText(client: harness.client, tab: tab, requestID: harness.requestID)
        }
        #expect(harness.gate.callsUsed == 100)
        #expect(harness.gate.state == .finished)
        #expect(!harness.actuator.accessEnabled)
        await expectAgentError(.expired) { _ = try await harness.gate.readText(client: harness.client, tab: tab, requestID: "101") }
        #expect(harness.actuator.violations.isEmpty)
    }

    @Test func aReusedExecutionIDIsRefusedAndSpendsNothing() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        _ = try await harness.gate.readText(client: harness.client, tab: tab, requestID: "same")
        await expectAgentError(.denied) { _ = try await harness.gate.readText(client: harness.client, tab: tab, requestID: "same") }
        #expect(harness.gate.callsUsed == 1)
    }

    @Test func emptyAndOversizedExecutionIDsAreRefused() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        await expectAgentError(.denied) { _ = try await harness.gate.readText(client: harness.client, tab: tab, requestID: "") }
        await expectAgentError(.denied) {
            _ = try await harness.gate.readText(client: harness.client, tab: tab, requestID: String(repeating: "a", count: 129))
        }
        #expect(harness.gate.callsUsed == 0)
    }

    @Test func aFifthTabIsRefusedAndAForeignTabIsNotOwned() async throws {
        let harness = try GateHarness()
        for _ in 0..<3 {
            _ = try await harness.gate.addTab(client: harness.client, requestID: harness.requestID)
        }
        #expect(harness.gate.tabs.count == 4)
        await expectAgentError(.tabLimit) { _ = try await harness.gate.addTab(client: harness.client, requestID: harness.requestID) }
        await expectAgentError(.denied) {
            _ = try await harness.gate.readText(client: harness.client, tab: TabID(), requestID: harness.requestID)
        }
    }

    @Test func losingTheProfileScopeStopsTheTaskBeforeAnyActuatorCall() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        harness.scopeOpen = false
        let before = harness.actuator.calls.count
        await expectAgentError(.denied) { _ = try await harness.gate.readText(client: harness.client, tab: tab, requestID: "x") }
        #expect(harness.gate.state == .stopped)
        #expect(harness.actuator.calls.count == before)
    }

    @Test func theDeadlineTimerEndsAnIdleTask() async throws {
        let harness = try GateHarness()
        harness.clock.advance(15 * 60 + 1)
        harness.gate.enforceDeadline()
        #expect(harness.gate.state == .finished)
        #expect(!harness.actuator.accessEnabled)
    }
}

// MARK: - Scope of pages and navigation

@Suite("Agent gate: navigation and page scope") @MainActor
struct AgentGateScopeTests {
    @Test func navigatingOutsideTheGrantIsDeniedBeforeTheActuatorLoads() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        let outside = try #require(URL(string: "https://evil.test/"))
        await expectAgentError(.denied) {
            try await harness.gate.navigate(client: harness.client, tab: tab, url: outside, requestID: "n")
        }
        #expect(!harness.actuator.calls.contains("navigate"))
        #expect(harness.gate.audit.last?.result == "Denied")
        #expect(harness.gate.audit.last?.origin == "https://evil.test")
    }

    @Test func nearMissOriginsAreNotTheGrantedOrigin() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        let misses = [
            "http://fixture.test/", "https://fixture.test:8443/", "https://sub.fixture.test/",
            "https://fixture.test.evil.test/", "https://evilfixture.test/"
        ]
        for miss in misses {
            let url = try #require(URL(string: miss))
            await expectAgentError(.denied) {
                try await harness.gate.navigate(client: harness.client, tab: tab, url: url, requestID: harness.requestID)
            }
        }
        #expect(!harness.actuator.calls.contains("navigate"))
    }

    @Test func credentialsInTheURLAreRefused() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        let url = try #require(URL(string: "https://user:pass@fixture.test/"))
        await expectAgentError(.invalidOrigin) {
            try await harness.gate.navigate(client: harness.client, tab: tab, url: url, requestID: "c")
        }
        #expect(!harness.actuator.calls.contains("navigate"))
    }

    @Test func aNavigationInsideTheGrantRuns() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        let url = try #require(URL(string: "https://fixture.test/next"))
        try await harness.gate.navigate(client: harness.client, tab: tab, url: url, requestID: "n")
        #expect(harness.actuator.calls.contains("navigate"))
        #expect(harness.gate.audit.last?.result == "Finished")
    }

    @Test func aCrossOriginRedirectIsRefusedByTheCallbackBeforeItLoads() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        let start = try #require(URL(string: "https://fixture.test/go"))
        harness.actuator.redirects["fixture.test"] = try #require(URL(string: "https://evil.test/landing"))
        await expectAgentError(.denied) {
            try await harness.gate.navigate(client: harness.client, tab: tab, url: start, requestID: "r")
        }
        // The page never moved to the redirect target.
        #expect(harness.actuator.origins[tab] == harness.origin)
    }

    @Test func theNavigationCallbackOnlyPermitsGrantedOrigins() throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        let authorize = try #require(harness.actuator.authorizers[tab])
        #expect(authorize(try #require(URL(string: "https://fixture.test/a"))))
        #expect(!authorize(try #require(URL(string: "https://other.test/"))))
        #expect(!authorize(try #require(URL(string: "http://fixture.test/"))))
        #expect(!authorize(try #require(URL(string: "javascript:alert(1)"))))
        #expect(!authorize(try #require(URL(string: "file:///etc/hosts"))))
        #expect(!authorize(try #require(URL(string: "data:text/html,hi"))))
    }

    @Test func theNavigationCallbackRefusesOnceTheTaskIsStopped() throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        let authorize = try #require(harness.actuator.authorizers[tab])
        harness.gate.stop()
        #expect(!authorize(try #require(URL(string: "https://fixture.test/a"))))
    }

    @Test func aPageThatLeftTheGrantReturnsNothing() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        harness.actuator.origins[tab] = try AgentOrigin(string: "https://elsewhere.test")
        harness.actuator.snapshotValue = AgentPageSnapshot(title: "x", origin: harness.origin, elements: [])
        await expectAgentError(.denied) { _ = try await harness.gate.snapshot(client: harness.client, tab: tab, requestID: "s") }
        await expectAgentError(.denied) { _ = try await harness.gate.readText(client: harness.client, tab: tab, requestID: "t") }
        #expect(!harness.actuator.calls.contains("snapshot"))
        #expect(!harness.actuator.calls.contains("readText"))
    }

    @Test func aTabThePersonMovedOffScopeCanBeNavigatedBackIn() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        harness.actuator.origins[tab] = try AgentOrigin(string: "https://elsewhere.test")
        let url = try #require(URL(string: "https://fixture.test/back"))
        try await harness.gate.navigate(client: harness.client, tab: tab, url: url, requestID: "back")
        #expect(harness.actuator.origins[tab] == harness.origin)
    }

    @Test func snapshotsAreCappedAndForeignElementsRejected() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        let many = (0..<500).map {
            AgentElement(id: "e\($0)", role: "button", name: "b\($0)", origin: harness.origin, fingerprint: "f", isEditable: false, isSensitive: false)
        }
        harness.actuator.snapshotValue = AgentPageSnapshot(title: String(repeating: "t", count: 900), origin: harness.origin, elements: many)
        let value = try await harness.gate.snapshot(client: harness.client, tab: tab, requestID: "s")
        #expect(value.elements.count == 200)
        #expect(value.isTruncated)
        #expect(value.title.count == 300)

        let foreign = AgentElement(id: "x", role: "link", name: "x", origin: try AgentOrigin(string: "https://evil.test"), fingerprint: "f", isEditable: false, isSensitive: false)
        harness.actuator.snapshotValue = AgentPageSnapshot(title: "x", origin: harness.origin, elements: [foreign])
        await expectAgentError(.denied) { _ = try await harness.gate.snapshot(client: harness.client, tab: tab, requestID: "s2") }
    }

    @Test func textAndScreenshotsAreBounded() async throws {
        let harness = try GateHarness(capabilities: [.read, .navigate, .screenshot])
        let tab = try #require(harness.tab)
        harness.actuator.textValue = String(repeating: "a", count: 200_000)
        let text = try await harness.gate.readText(client: harness.client, tab: tab, requestID: "r")
        #expect(text.count == 60_000)
        harness.actuator.screenshotValue = Data(count: 3_500_001)
        await expectAgentError(.unavailable) { _ = try await harness.gate.screenshot(client: harness.client, tab: tab, requestID: "s") }
        harness.actuator.screenshotValue = Data(count: 1_000)
        let image = try await harness.gate.screenshot(client: harness.client, tab: tab, requestID: "s2")
        #expect(image.count == 1_000)
    }
}
