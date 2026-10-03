@testable import BrowsemiumAI
import BrowsemiumCore
import Foundation
import Testing

@Suite struct GeminiStreamRecoveryTests {
    private func stream(_ frames: [String], staysOpen: Bool = false) -> AsyncThrowingStream<AIEvent, Error> {
        GeminiAdapter.mapStream(AsyncThrowingStream { continuation in
            for frame in frames { continuation.yield(.init(data: frame)) }
            if !staysOpen { continuation.finish() }
        })
    }

    @Test func candidateSafetyFailureWithoutContentIsReported() async {
        var didFail = false
        do {
            for try await _ in stream([#"{"candidates":[{"finishReason":"SAFETY"}]}"#]) {}
        } catch { didFail = error.localizedDescription.contains("SAFETY") }
        #expect(didFail)
    }

    @Test func terminalTextIsDeliveredAndFinishesImmediately() async throws {
        var completed = ""
        // Terminal text must include completion; a subsequent bad frame must never be consumed.
        for try await event in stream([
            #"{"candidates":[{"content":{"parts":[{"text":"Fixture answer"}]},"finishReason":"STOP"}]}"#,
            #"{"error":{"message":"Must not be reached"}}"#
        ]) {
            if case .completed(let message) = event { completed = message.content }
        }
        #expect(completed == "Fixture answer")
    }

    @Test func thoughtTextIsNotPresentedAsTheAnswer() async throws {
        var text = ""
        for try await event in stream([
            #"{"candidates":[{"content":{"parts":[{"text":"Internal reasoning","thought":true}]}}]}"#,
            #"{"candidates":[{"content":{"parts":[{"text":"Visible answer"}]},"finishReason":"STOP"}]}"#
        ]) {
            if case .completed(let message) = event { text = message.content }
        }
        #expect(text == "Visible answer")
    }

    @Test func modelPickerExcludesEmbeddingAndOtherUnsupportedModels() {
        let models = GeminiAdapter.models(from: [
            ["name": "models/chat", "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/embedding", "supportedGenerationMethods": ["embedContent"]],
            ["name": "models/predict", "supportedGenerationMethods": ["predict"]],
            ["name": "models/unadvertised"]
        ])
        #expect(models.map(\.id) == ["chat"])
    }
}
