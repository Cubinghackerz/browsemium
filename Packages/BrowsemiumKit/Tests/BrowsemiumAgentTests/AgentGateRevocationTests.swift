import BrowsemiumAgent
import BrowsemiumCore
import Foundation
import Testing

// MARK: - Serialization, Stop, takeover

@Suite("Agent gate: concurrency and revocation") @MainActor
struct AgentGateConcurrencyTests {
    @Test func aSecondCallWhileOneRunsIsBusyAndTheFirstStillFinishes() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        let latch = Latch()
        harness.actuator.latches["readText"] = latch
        let first = Task { try await harness.gate.readText(client: harness.client, tab: tab, requestID: "first") }
        #expect(await harness.waitUntil { latch.isWaiting })

        await expectAgentError(.busy) { _ = try await harness.gate.readText(client: harness.client, tab: tab, requestID: "second") }
        await expectAgentError(.busy) { _ = try await harness.gate.addTab(client: harness.client, requestID: "third") }
        #expect(harness.gate.callsUsed == 1)

        latch.release()
        #expect(try await first.value == "page text")
        #expect(harness.gate.state == .ready)
        _ = try await harness.gate.readText(client: harness.client, tab: tab, requestID: "fourth")
    }

    @Test func anActuatorErrorAlwaysReleasesTheOperationSlot() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        harness.actuator.failures["readText"] = URLError(.timedOut)
        await expectAgentError(.unavailable) { _ = try await harness.gate.readText(client: harness.client, tab: tab, requestID: "a") }
        #expect(harness.gate.state == .ready)
        harness.actuator.failures["readText"] = nil
        #expect(try await harness.gate.readText(client: harness.client, tab: tab, requestID: "b") == "page text")
        #expect(harness.gate.audit.map(\.result).suffix(2) == ["Failed", "Finished"])
    }

    @Test func pageControlledErrorTextNeverReachesTheClient() async throws {
        struct Leaky: Error, LocalizedError { var errorDescription: String? { "secret page text 4242" } }
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        harness.actuator.failures["readText"] = Leaky()
        do {
            _ = try await harness.gate.readText(client: harness.client, tab: tab, requestID: "a")
            Issue.record("expected a failure")
        } catch {
            #expect(!"\(error.localizedDescription)".contains("4242"))
            #expect((error as? AgentError) == .unavailable)
        }
    }

    @Test func stopDuringARunInvalidatesItAndNothingIsReturned() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        let latch = Latch()
        harness.actuator.latches["readText"] = latch
        let running = Task { try await harness.gate.readText(client: harness.client, tab: tab, requestID: "r") }
        #expect(await harness.waitUntil { latch.isWaiting })

        harness.gate.stop()
        latch.release()
        let result = await running.result
        if case .success = result { Issue.record("Content was returned after Stop") }
        #expect(harness.gate.state == .stopped)
        #expect(!harness.actuator.accessEnabled)
        #expect(harness.actuator.violations.isEmpty)
    }

    @Test func anOldCompletionNeverClearsANewerTasksOperation() async throws {
        let harness = try GateHarness()
        let oldTab = try #require(harness.tab)
        let oldLatch = Latch()
        harness.actuator.latches["readText"] = oldLatch
        let old = Task { try await harness.gate.readText(client: harness.client, tab: oldTab, requestID: "old") }
        #expect(await harness.waitUntil { oldLatch.isWaiting })

        harness.gate.stop()
        harness.task = try harness.newTask()
        let newTab = try harness.start()

        let newLatch = Latch()
        harness.actuator.latches["readText"] = newLatch
        let fresh = Task { try await harness.gate.readText(client: harness.client, tab: newTab, requestID: "new") }
        #expect(await harness.waitUntil { newLatch.isWaiting })

        oldLatch.release()
        _ = await old.result

        // The old completion must not have freed the slot the new task holds.
        await expectAgentError(.busy) { _ = try await harness.gate.readText(client: harness.client, tab: newTab, requestID: "intruder") }
        #expect(!harness.gate.audit.contains { $0.action == "Read" && $0.result == "Interrupted" })
        #expect(harness.gate.state == .reading)

        newLatch.release()
        #expect(try await fresh.value == "page text")
        #expect(harness.gate.state == .ready)
    }

    @Test func workStartedBeforeATakeoverCannotFinishAfterHandBack() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        let latch = Latch()
        harness.actuator.latches["readText"] = latch
        let running = Task { try await harness.gate.readText(client: harness.client, tab: tab, requestID: "old") }
        #expect(await harness.waitUntil { latch.isWaiting })

        // Authority is revoked and then restored before the old call returns.
        harness.gate.pause()
        try harness.gate.resume()
        #expect(harness.gate.state == .ready)

        latch.release()
        if case .success = await running.result {
            Issue.record("A call from before the takeover returned content after hand-back")
        }
        // The slot is free for a fresh call, and the old one left no mark on it.
        harness.actuator.latches["readText"] = nil
        #expect(try await harness.gate.readText(client: harness.client, tab: tab, requestID: "fresh") == "page text")
    }

    @Test func takeoverInvalidatesWorkButKeepsThePages() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        let latch = Latch()
        harness.actuator.latches["readText"] = latch
        let running = Task { try await harness.gate.readText(client: harness.client, tab: tab, requestID: "r") }
        #expect(await harness.waitUntil { latch.isWaiting })

        harness.gate.pause()
        latch.release()
        if case .success = await running.result { Issue.record("Content was returned after takeover") }

        #expect(harness.gate.state == .paused)
        #expect(harness.gate.tabs == [tab])
        #expect(harness.actuator.closed.isEmpty)
        #expect(!harness.actuator.accessEnabled)
        await expectAgentError(.denied) { _ = try await harness.gate.readText(client: harness.client, tab: tab, requestID: "again") }
        #expect(harness.actuator.violations.isEmpty)
    }

    @Test func handingBackRestoresAuthorityWithinTheSameDeadline() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        harness.gate.pause()
        try harness.gate.resume()
        #expect(harness.actuator.accessEnabled)
        #expect(try await harness.gate.readText(client: harness.client, tab: tab, requestID: "r") == "page text")

        harness.gate.pause()
        harness.clock.advance(15 * 60 + 1)
        #expect(throws: AgentError.expired) { try harness.gate.resume() }
        #expect(harness.gate.state == .finished)
    }

    @Test func resumeIsRefusedWhenTheTaskIsNotPaused() throws {
        let harness = try GateHarness()
        #expect(throws: AgentError.denied) { try harness.gate.resume() }
        harness.gate.stop()
        #expect(throws: AgentError.denied) { try harness.gate.resume() }
    }

    @Test func stopKeepsPagesUnlessToldToCloseThem() throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        harness.gate.stop()
        #expect(harness.actuator.closed.isEmpty)
        #expect(harness.gate.tabs == [tab])
        harness.gate.dismissWorkspace()
        #expect(harness.actuator.closed == [tab])
        #expect(harness.gate.tabs.isEmpty)
    }

    @Test func lockingClosesThePagesSoNothingStaysVisible() throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        harness.gate.stop(closePages: true)
        #expect(harness.actuator.closed == [tab])
    }

    @Test func aDisconnectEndsOnlyTheOwnersTask() throws {
        let harness = try GateHarness()
        harness.gate.clientDisconnected(UUID())
        #expect(harness.gate.state == .ready)
        harness.gate.clientDisconnected(harness.client)
        #expect(harness.gate.state == .stopped)
        #expect(!harness.actuator.accessEnabled)
    }

    @Test func theOwnerCanStillReadAnEndedTasksStatus() throws {
        let harness = try GateHarness()
        harness.gate.stop()
        let status = try harness.gate.status(client: harness.client)
        #expect(status.state == .stopped)
        #expect(status.permittedOrigins == ["https://fixture.test"])
        #expect(throws: AgentError.denied) { _ = try harness.gate.listTabs(client: harness.client) }
    }

    @Test func theClientFinishingEndsTheTaskWithoutSpendingBudget() throws {
        let harness = try GateHarness()
        try harness.gate.finish(client: harness.client)
        #expect(harness.gate.state == .finished)
        #expect(harness.gate.callsUsed == 0)
        #expect(throws: AgentError.denied) { try harness.gate.finish(client: UUID()) }
    }

    @Test func statusCostsNothingAndLeaksNoContent() throws {
        let harness = try GateHarness()
        for _ in 0..<150 { _ = try harness.gate.status(client: harness.client) }
        #expect(harness.gate.callsUsed == 0)
        let status = try harness.gate.status(client: harness.client)
        #expect(status.callsRemaining == 100)
        #expect(status.tabs.count == 1)
    }
}

// MARK: - Confirmation and interaction

@Suite("Agent gate: clicks and typing") @MainActor
struct AgentGateInteractionTests {
    @Test func aClickWaitsForNativeApprovalAndThenRunsOnce() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        let element = harness.element(name: "Continue")
        let click = Task { try await harness.gate.click(client: harness.client, tab: tab, reference: "e1", requestID: "c") }

        let request = try #require(await harness.approveNext(true))
        #expect(request.kind == .click)
        #expect(request.name == "Continue")
        #expect(request.origin == harness.origin)
        try await click.value
        #expect(harness.actuator.performed == [.click(element)])
        #expect(harness.gate.pendingApproval == nil)
        #expect(harness.gate.state == .ready)
    }

    @Test func nothingRunsWhileTheConfirmationIsPending() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        harness.element()
        let click = Task { try await harness.gate.click(client: harness.client, tab: tab, reference: "e1", requestID: "c") }
        #expect(await harness.waitUntil { harness.gate.pendingApproval != nil })
        #expect(harness.gate.state == .waiting)
        #expect(harness.actuator.performed.isEmpty)
        _ = await harness.approveNext(false)
        _ = await click.result
    }

    @Test func decliningDoesNothingAndReportsDeclined() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        harness.element()
        let click = Task { try await harness.gate.click(client: harness.client, tab: tab, reference: "e1", requestID: "c") }
        _ = await harness.approveNext(false)
        let result = await click.result
        #expect((result.error as? AgentError) == .declined)
        #expect(harness.actuator.performed.isEmpty)
        #expect(harness.gate.audit.last?.result == "Declined")
    }

    @Test func anUnansweredConfirmationDeclinesItself() async throws {
        let harness = try GateHarness(approvalTimeout: .milliseconds(60))
        let tab = try #require(harness.tab)
        harness.element()
        await expectAgentError(.declined) {
            try await harness.gate.click(client: harness.client, tab: tab, reference: "e1", requestID: "c")
        }
        #expect(harness.actuator.performed.isEmpty)
        #expect(harness.gate.pendingApproval == nil)
    }

    @Test func harmlessLookingLabelsStillNeedConfirmation() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        for (index, label) in ["Read more", "Save", "Next", "Delete account", "Place order"].enumerated() {
            harness.element(id: "e\(index)", name: label)
            let click = Task {
                try await harness.gate.click(client: harness.client, tab: tab, reference: "e\(index)", requestID: "c\(index)")
            }
            let request = try #require(await harness.approveNext(false))
            #expect(request.name == label)
            _ = await click.result
        }
        // Not one of them ran: the label is the page's claim, not evidence.
        #expect(harness.actuator.performed.isEmpty)
    }

    @Test func stopWhileAConfirmationIsPendingCancelsItAndNothingRuns() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        harness.element()
        let click = Task { try await harness.gate.click(client: harness.client, tab: tab, reference: "e1", requestID: "c") }
        #expect(await harness.waitUntil { harness.gate.pendingApproval != nil })
        let staleID = try #require(harness.gate.pendingApproval?.id)

        harness.gate.stop()
        #expect(harness.gate.pendingApproval == nil)
        let result = await click.result
        #expect((result.error as? AgentError) == .denied)
        #expect(harness.actuator.performed.isEmpty)

        // A late tap on the old card must not approve anything.
        harness.gate.resolveApproval(id: staleID, approved: true)
        #expect(harness.actuator.performed.isEmpty)
    }

    @Test func takeoverWhileAConfirmationIsPendingCancelsIt() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        harness.element()
        let click = Task { try await harness.gate.click(client: harness.client, tab: tab, reference: "e1", requestID: "c") }
        #expect(await harness.waitUntil { harness.gate.pendingApproval != nil })
        harness.gate.pause()
        let result = await click.result
        #expect((result.error as? AgentError) == .denied)
        #expect(harness.gate.pendingApproval == nil)
        #expect(harness.actuator.performed.isEmpty)
        #expect(harness.gate.state == .paused)
    }

    @Test func anApprovalForAnOlderRequestCannotApproveANewerOne() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        harness.element()
        let first = Task { try await harness.gate.click(client: harness.client, tab: tab, reference: "e1", requestID: "c1") }
        let oldID = try #require(await harness.approveNext(false)).id
        _ = await first.result

        let second = Task { try await harness.gate.click(client: harness.client, tab: tab, reference: "e1", requestID: "c2") }
        #expect(await harness.waitUntil { harness.gate.pendingApproval != nil })
        harness.gate.resolveApproval(id: oldID, approved: true)
        #expect(harness.gate.pendingApproval != nil)
        #expect(harness.actuator.performed.isEmpty)
        _ = await harness.approveNext(false)
        _ = await second.result
    }

    @Test func sensitiveFieldsAreRefusedWithoutEvenAskingThePerson() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        harness.element(id: "pw", role: "textbox", name: "Password", editable: true, sensitive: true)
        await expectAgentError(.sensitiveField) {
            try await harness.gate.type(client: harness.client, tab: tab, reference: "pw", text: "hunter2", requestID: "t")
        }
        await expectAgentError(.sensitiveField) {
            try await harness.gate.click(client: harness.client, tab: tab, reference: "pw", requestID: "c")
        }
        #expect(harness.gate.pendingApproval == nil)
        #expect(harness.actuator.performed.isEmpty)
    }

    @Test func typingIntoANonEditableElementIsRefused() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        harness.element(role: "button", editable: false)
        await expectAgentError(.denied) {
            try await harness.gate.type(client: harness.client, tab: tab, reference: "e1", text: "x", requestID: "t")
        }
        #expect(harness.actuator.performed.isEmpty)
    }

    @Test func aPageThatChangedTheElementAfterApprovalIsRejectedAsStale() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        harness.element(name: "Continue", fingerprint: "fp-1")
        harness.actuator.resolveHook = { count in
            // The second resolve happens after the person approved.
            if count == 2 {
                harness.actuator.elements["e1"] = harness.element(name: "Pay now", fingerprint: "fp-2")
            }
        }
        let click = Task { try await harness.gate.click(client: harness.client, tab: tab, reference: "e1", requestID: "c") }
        _ = await harness.approveNext(true)
        let result = await click.result
        #expect((result.error as? AgentError) == .staleElement)
        #expect(harness.actuator.performed.isEmpty)
    }

    @Test func anElementFromAnotherOriginIsRefused() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        harness.element(origin: try AgentOrigin(string: "https://evil.test"))
        await expectAgentError(.denied) {
            try await harness.gate.click(client: harness.client, tab: tab, reference: "e1", requestID: "c")
        }
        #expect(harness.gate.pendingApproval == nil)
    }

    @Test func aPageThatMovedDuringApprovalIsNotActedOn() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        harness.element()
        let click = Task { try await harness.gate.click(client: harness.client, tab: tab, reference: "e1", requestID: "c") }
        #expect(await harness.waitUntil { harness.gate.pendingApproval != nil })
        harness.actuator.origins[tab] = try AgentOrigin(string: "https://evil.test")
        _ = await harness.approveNext(true)
        let result = await click.result
        #expect((result.error as? AgentError) == .denied)
        #expect(harness.actuator.performed.isEmpty)
    }

    @Test func typedValuesNeverEnterTheAuditRecord() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        let secret = "correct-horse-battery-staple-8841"
        let field = harness.element(id: "q", role: "textbox", name: "Search", editable: true)
        let typing = Task { try await harness.gate.type(client: harness.client, tab: tab, reference: "q", text: secret, requestID: "t") }
        let request = try #require(await harness.approveNext(true))
        #expect(request.typedText == secret)
        try await typing.value
        #expect(harness.actuator.performed == [.type(field, secret)])
        let dump = harness.gate.audit.map { "\($0.action)|\($0.origin)|\($0.result)" }.joined()
        #expect(!dump.contains(secret))
        #expect(!"\(harness.gate.audit)".contains(secret))
    }

    @Test func oversizedTextAndReferencesAreRefusedBeforeTheActuator() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        harness.element(id: "q", role: "textbox", editable: true)
        await expectAgentError(.invalidArguments) {
            try await harness.gate.type(client: harness.client, tab: tab, reference: "q", text: String(repeating: "a", count: 8_001), requestID: "t")
        }
        await expectAgentError(.invalidArguments) {
            try await harness.gate.click(client: harness.client, tab: tab, reference: String(repeating: "r", count: 101), requestID: "c")
        }
        await expectAgentError(.invalidArguments) {
            try await harness.gate.click(client: harness.client, tab: tab, reference: "", requestID: "c2")
        }
        #expect(!harness.actuator.calls.contains("resolve"))
    }

    @Test func nothingReachesTheActuatorWhenAccessIsOff() async throws {
        let harness = try GateHarness()
        let tab = try #require(harness.tab)
        harness.element()
        harness.gate.pause()
        await expectAgentError(.denied) { try await harness.gate.click(client: harness.client, tab: tab, reference: "e1", requestID: "c") }
        await expectAgentError(.denied) { _ = try await harness.gate.snapshot(client: harness.client, tab: tab, requestID: "s") }
        #expect(harness.actuator.violations.isEmpty)
        #expect(!harness.actuator.calls.contains("resolve"))
    }
}

private extension Result {
    var error: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
