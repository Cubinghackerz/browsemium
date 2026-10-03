import BrowsemiumAI
import BrowsemiumCore
import Foundation
import Testing

@Suite struct ProviderStreamRecoveryTests {
    @Test(arguments: ["[DONE]", "done", "eof"])
    func emptyCompletionFailsVisibly(termination: String) async throws {
        let upstream = AsyncThrowingStream<SSEParser.Event, Error> { continuation in
            if termination != "eof" { continuation.yield(.init(data: termination)) }
            continuation.finish()
        }
        var succeededWithEmptyText = false
        var failed = false
        do {
            for try await event in mapProviderStream(upstream, transform: { _, _ in .done }) {
                if case .completed(let message) = event { succeededWithEmptyText = message.content.isEmpty }
            }
        } catch { failed = true }
        #expect(failed)
        #expect(!succeededWithEmptyText)
    }

    @Test func normalReplyStillStreamsAndCompletes() async throws {
        let upstream = AsyncThrowingStream<SSEParser.Event, Error> { continuation in
            continuation.yield(.init(data: "Hello"))
            continuation.yield(.init(data: "[DONE]"))
            continuation.finish()
        }
        var text = ""
        var completed = ""
        for try await event in mapProviderStream(upstream, transform: { event, _ in .delta(event.data) }) {
            switch event {
            case .textDelta(let delta): text += delta
            case .completed(let message): completed = message.content
            }
        }
        #expect(text == "Hello")
        #expect(completed == text)
    }

    @Test func legacyEmptyAssistantHistoryDoesNotGoBackToTheProvider() throws {
        let request = AIRequest(model: AIModel(id: "fixture", name: "Fixture", providerID: .gemini), messages: [
            AIMessage(role: .user, content: "Earlier question"),
            AIMessage(role: .assistant, content: " \n"),
            AIMessage(role: .assistant, content: "Earlier answer"),
            AIMessage(role: .user, content: "Follow-up")
        ])
        let canonical = try AIRequestBuilder.build(request)
        #expect(canonical.messages.count == 3)
    }
}
