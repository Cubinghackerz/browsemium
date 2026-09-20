import BrowsemiumCore
import Foundation

/// Talks to a local Ollama server. No credential is involved: the server is
/// on this Mac, which is the point — prompts and context never leave it.
///
/// Uses Ollama's OpenAI-compatible endpoint (`/v1/chat/completions`) because
/// the Responses API shape the other adapters speak is not implemented there.
public struct OllamaAdapter: AIProviderAdapter {
    public static let host = "localhost"
    public static let baseURL = "http://localhost:11434"

    public let id: AIProviderID = .ollama

    private let client: AIHTTPClient
    private let policy: AIContextPolicy
    private let capabilities: ModelCapabilityCatalog

    public init(
        client: AIHTTPClient = AIHTTPClient(),
        policy: AIContextPolicy = AIContextPolicy(),
        capabilities: ModelCapabilityCatalog = .bundled
    ) {
        self.client = client
        self.policy = policy
        self.capabilities = capabilities
    }

    public func validateCredential() async throws {
        _ = try await listModels()
    }

    public func listModels() async throws -> [AIModel] {
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/tags")!)
        request.httpMethod = "GET"

        let data = try await client.sendJSON(request, allowedHost: Self.host)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            throw AIHTTPClient.HTTPError.invalidResponse
        }
        return models.compactMap { entry -> AIModel? in
            guard let name = entry["name"] as? String else { return nil }
            return AIModel(id: name, name: name, providerID: .ollama)
        }
        .sorted { $0.id < $1.id }
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        let urlRequest: URLRequest
        do {
            urlRequest = try makeRequest(request)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return mapProviderStream(client.streamSSE(urlRequest, allowedHost: Self.host)) { event, _ in
            if event.data.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                return .done
            }
            guard let object = ProviderJSON.object(from: event.data) else {
                return .ignore
            }
            if let error = object["error"] as? [String: Any] {
                return .failed((error["message"] as? String) ?? "Ollama reported an error.")
            }
            guard let choices = object["choices"] as? [[String: Any]],
                  let first = choices.first else {
                return .ignore
            }
            if let delta = first["delta"] as? [String: Any],
               let content = delta["content"] as? String,
               !content.isEmpty {
                return .delta(content)
            }
            return .ignore
        }
    }

    public func makeRequest(_ request: AIRequest) throws -> URLRequest {
        let canonical = try AIRequestBuilder.build(
            request,
            policy: policy,
            supportsVision: capabilities.supportsVision(provider: .ollama, modelID: request.model.id)
        )

        var messages: [[String: Any]] = [
            ["role": "system", "content": AIRequestBuilder.systemPrompt]
        ]
        for message in canonical.messages {
            let content = try message.parts.map { part -> [String: Any] in
                switch part {
                case .text(let text):
                    return ["type": "text", "text": text]
                case .image(let image):
                    return ["type": "image_url", "image_url": ["url": ProviderJSON.dataURL(for: image)]]
                case .file(let file):
                    throw BrowsemiumError.fileNotAllowed("The Ollama adapter cannot receive \(file.filename) directly.")
                }
            }
            messages.append([
                "role": message.role == .assistant ? "assistant" : "user",
                "content": content
            ])
        }

        let body: [String: Any] = [
            "model": canonical.modelID,
            "messages": messages,
            "stream": true,
            "max_tokens": canonical.maxOutputTokens
        ]

        var urlRequest = URLRequest(url: URL(string: "\(Self.baseURL)/v1/chat/completions")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }
}
