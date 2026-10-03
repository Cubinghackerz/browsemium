import BrowsemiumCore
import Foundation

public enum ProviderStreamSignal: Sendable {
    case ignore
    case delta(String)
    case deltaAndDone(String)
    case done
    case failed(String)
}

public func mapProviderStream(
    _ upstream: AsyncThrowingStream<SSEParser.Event, Error>,
    transform: @escaping @Sendable (SSEParser.Event, inout String) -> ProviderStreamSignal
) -> AsyncThrowingStream<AIEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            var accumulated = ""
            do {
                for try await event in upstream {
                    if event.data == "[DONE]" {
                        completeProviderStream(accumulated, continuation: continuation)
                        return
                    }
                    switch transform(event, &accumulated) {
                    case .ignore:
                        continue
                    case .delta(let text):
                        accumulated += text
                        continuation.yield(.textDelta(text))
                    case .done:
                        completeProviderStream(accumulated, continuation: continuation)
                        return
                    case .deltaAndDone(let text):
                        accumulated += text
                        if !text.isEmpty { continuation.yield(.textDelta(text)) }
                        completeProviderStream(accumulated, continuation: continuation)
                        return
                    case .failed(let message):
                        continuation.finish(throwing: AIHTTPClient.HTTPError.status(502, message))
                        return
                    }
                }
                completeProviderStream(accumulated, continuation: continuation)
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
    }
}

private func completeProviderStream(_ content: String, continuation: AsyncThrowingStream<AIEvent, Error>.Continuation) {
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        continuation.finish(throwing: AIHTTPClient.HTTPError.emptyResponse)
        return
    }
    continuation.yield(.completed(AIMessage(role: .assistant, content: content)))
    continuation.finish()
}

enum ProviderJSON {
    static func object(from data: String) -> [String: Any]? {
        guard let raw = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return nil
        }
        return object
    }

    static func string(_ object: [String: Any], _ key: String) -> String? {
        object[key] as? String
    }

    static func dictionary(_ object: [String: Any], _ key: String) -> [String: Any]? {
        object[key] as? [String: Any]
    }

    static func array(_ object: [String: Any], _ key: String) -> [[String: Any]]? {
        object[key] as? [[String: Any]]
    }

    static func errorMessage(_ object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any] {
            if let message = error["message"] as? String {
                return message
            }
            return nil
        }
        if let message = object["message"] as? String {
            return message
        }
        return nil
    }

    static func dataURL(for image: PageImageContext) -> String {
        "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
    }
}
