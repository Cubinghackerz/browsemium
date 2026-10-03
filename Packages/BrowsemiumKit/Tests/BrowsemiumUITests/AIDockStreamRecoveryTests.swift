@testable import BrowsemiumUI
import BrowsemiumCore
import Foundation
import Testing

private struct FixtureReplyAdapter: AIProviderAdapter {
    let id: AIProviderID = .ollama
    let events: [AIEvent]
    let staysOpen: Bool
    func validateCredential() async throws {}
    func listModels() async throws -> [AIModel] { [] }
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            if !staysOpen { continuation.finish() }
        }
    }
}

@Suite(.serialized) @MainActor struct AIDockStreamRecoveryTests {
    private func dock(events: [AIEvent], staysOpen: Bool = false, timeout: Duration = .seconds(120)) -> AIDockViewModel {
        let ai = AIDockViewModel(environment: .inMemory(engine: StubEngine()), requestTimeout: timeout, adapterFactory: { _, _ in
            FixtureReplyAdapter(events: events, staysOpen: staysOpen)
        })
        ai.provider = .ollama
        ai.mode = .api
        ai.models = [AIModel(id: "fixture", name: "Fixture", providerID: .ollama)]
        return ai
    }

    private func send(_ ai: AIDockViewModel) async {
        ai.draft = "Summarize the fixture"
        ai.beginReview()
        await ai.confirmSend(tabID: nil)
    }

    private func settled(_ ai: AIDockViewModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ai.isStreaming, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!ai.isStreaming)
    }

    @Test func emptyCompletedReplyDoesNotLeaveAPermanentSpinner() async throws {
        let ai = dock(events: [.completed(AIMessage(role: .assistant, content: ""))])
        await send(ai)
        try await settled(ai)
        #expect(ai.messages.filter { $0.role == .assistant }.isEmpty)
        #expect(ai.errorMessage != nil)
        #expect(ai.lastFailedSend != nil)
    }

    @Test func completionEndsTheRequestEvenIfUpstreamStaysOpen() async throws {
        let ai = dock(events: [.completed(AIMessage(role: .assistant, content: "Fixture answer"))], staysOpen: true)
        await send(ai)
        // A terminal event must settle without relying on network EOF.
        try await settled(ai)
        #expect(ai.messages.last?.content == "Fixture answer")
        ai.stop()
    }

    @Test func stopRemovesOnlyThePendingEmptyReply() async {
        let ai = dock(events: [], staysOpen: true)
        ai.messages = [AIMessage(role: .assistant, content: "Earlier answer")]
        await send(ai)
        ai.stop()
        #expect(!ai.isStreaming)
        #expect(ai.messages.filter { $0.role == .assistant }.map(\.content) == ["Earlier answer"])
    }

    @Test func stalledReplyTimesOutAndCanBeRetried() async throws {
        let ai = dock(events: [], staysOpen: true, timeout: .milliseconds(20))
        await send(ai)
        try await settled(ai)
        #expect(ai.messages.filter { $0.role == .assistant }.isEmpty)
        #expect(ai.errorMessage?.contains("too long") == true)
        #expect(ai.lastFailedSend?.prompt == "Summarize the fixture")
        ai.stop()
    }

    @Test func requestCannotBeSubmittedWithoutAnOpenReview() async {
        let ai = dock(events: [], staysOpen: true)
        ai.reviewPrompt = "Stale reviewed text"
        await ai.confirmSend(tabID: nil)
        #expect(ai.messages.isEmpty)
        #expect(!ai.isStreaming)
        ai.stop()
    }

    @Test func emptyEOFIsARecoverableFailure() async throws {
        let ai = dock(events: [])
        await send(ai)
        try await settled(ai)
        #expect(ai.errorMessage != nil)
        #expect(ai.lastFailedSend != nil)
        #expect(ai.messages.filter { $0.role == .assistant }.isEmpty)
    }

    @Test func onlyTheCurrentReplyCanShowLoadingAndBusyActionsCannotOpenAReview() async {
        let engine = StubEngine()
        let model = BrowserWindowModel(environment: .inMemory(engine: engine))
        let ai = AIDockViewModel(environment: model.environment, adapterFactory: { _, _ in
            FixtureReplyAdapter(events: [], staysOpen: true)
        })
        ai.provider = .ollama
        ai.mode = .api
        ai.models = [AIModel(id: "fixture", name: "Fixture", providerID: .ollama)]
        let old = AIMessage(role: .assistant, content: "")
        ai.messages = [old]
        await send(ai)
        let pending = ai.messages.last!
        #expect(!ai.isGeneratingReply(old.id))
        #expect(ai.isGeneratingReply(pending.id))
        ai.draft = "Second question"
        ai.beginReview()
        await ai.runQuickAction(.keyPoints, tabID: model.session.activeTabID)
        #expect(!ai.isReviewPresented)
        #expect(engine.capturedTabs.isEmpty)
        #expect(ai.messages.filter { $0.role == .user }.count == 1)
        ai.stop()
        #expect(!ai.isGeneratingReply(pending.id))
    }

    @Test func lateCompletionAfterStopCannotReinsertTheReply() async throws {
        let pair = AsyncThrowingStream<AIEvent, Error>.makeStream()
        let ai = AIDockViewModel(environment: .inMemory(engine: StubEngine()), adapterFactory: { _, _ in
            ControlledReplyAdapter(events: pair.stream)
        })
        ai.provider = .ollama
        ai.mode = .api
        ai.models = [AIModel(id: "fixture", name: "Fixture", providerID: .ollama)]
        await send(ai)
        ai.stop()
        pair.continuation.yield(.completed(AIMessage(role: .assistant, content: "Late reply")))
        pair.continuation.finish()
        // Let the cancelled consumer finish. The generation check is also exercised
        // by the terminal event test; no network or real credential is involved.
        await Task.yield()
        #expect(ai.messages.filter { $0.role == .assistant }.isEmpty)
        #expect(!ai.isStreaming)
        #expect(ai.errorMessage == nil)
    }

    @Test func reopeningAnOldConversationDropsEmptyAssistantPlaceholders() throws {
        let model = BrowserWindowModel(environment: .inMemory(engine: StubEngine()))
        let repo = model.environment.conversationRepository
        let id = try repo.createConversation(title: "Fixture recovery")
        try repo.appendMessage(conversationID: id, role: .user, content: "Earlier question")
        try repo.appendMessage(conversationID: id, role: .assistant, content: "")
        try repo.appendMessage(conversationID: id, role: .assistant, content: "Useful answer")
        let ai = AIDockViewModel(windowModel: model)
        ai.openConversation(id)
        #expect(ai.messages.map(\.content) == ["Earlier question", "Useful answer"])
        // Loading is non-destructive; stored records remain available.
        #expect(try repo.messages(conversationID: id).count == 3)
    }

    @Test func clearingAConversationAlsoClearsItsRetryPayload() async throws {
        let ai = dock(events: [])
        await send(ai)
        try await settled(ai)
        #expect(ai.lastFailedSend != nil)
        ai.clearConversation()
        #expect(ai.lastFailedSend == nil)
    }
}

private struct ControlledReplyAdapter: AIProviderAdapter {
    let id: AIProviderID = .ollama
    let events: AsyncThrowingStream<AIEvent, Error>
    func validateCredential() async throws {}
    func listModels() async throws -> [AIModel] { [] }
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> { events }
}
