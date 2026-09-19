import BrowsemiumCore
import Foundation

public enum ProviderStreamSignal: Sendable {
    case ignore
    case delta(String)
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
                        continuation.yield(.completed(AIMessage(role: .assistant, content: accumulated)))
                        continuation.finish()
                        return
                    }
                    switch transform(event, &accumulated) {
                    case .ignore:
                        continue
                    case .delta(let text):
                        accumulated += text
                        continuation.yield(.textDelta(text))
                    case .done:
                        continuation.yield(.completed(AIMessage(role: .assistant, content: accumulated)))
                        continuation.finish()
                        return
                    case .failed(let message):
                        continuation.finish(throwing: AIHTTPClient.HTTPError.status(502, message))
                        return
                    }
                }
                continuation.yield(.completed(AIMessage(role: .assistant, content: accumulated)))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
    }
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
