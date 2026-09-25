import BrowsemiumCore
import Foundation

/// Talks to Vercel's v0 generative-UI API. The user's own v0 API key is the
/// credential — nothing is proxied through Browsemium and no account is
/// required beyond the key the user chose to paste in.
///
/// v0 speaks OpenAI-compatible chat completions over SSE, so the request and
/// stream mapping follow the Ollama adapter's shape with Bearer auth.
public struct V0Adapter: AIProviderAdapter {
    public static let host = "api.v0.dev"
    public static let baseURL = "https://api.v0.dev"

    public let id: AIProviderID = .vercelV0

    private let credential: String
    private let client: AIHTTPClient
    private let policy: AIContextPolicy
    private let capabilities: ModelCapabilityCatalog

    public init(
        credential: String,
        client: AIHTTPClient = AIHTTPClient(),
        policy: AIContextPolicy = AIContextPolicy(),
        capabilities: ModelCapabilityCatalog = .bundled
    ) {
        self.credential = credential
        self.client = client
        self.policy = policy
        self.capabilities = capabilities
    }

    public func validateCredential() async throws {
        _ = try await listModels()
    }

    public func listModels() async throws -> [AIModel] {
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/v1/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")

        let data = try await client.sendJSON(request, allowedHost: Self.host)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else {
            throw AIHTTPClient.HTTPError.invalidResponse
        }
        let models = entries.compactMap { entry -> AIModel? in
            guard let modelID = entry["id"] as? String else { return nil }
            return AIModel(id: modelID, name: modelID, providerID: .vercelV0)
        }
        return models.isEmpty ? [AIModel(id: Self.defaultModelID, name: Self.defaultModelID, providerID: .vercelV0)] : models
    }

    /// The model used when the account's model list cannot be fetched.
    public static let defaultModelID = "v0-1.5-md"

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
                return .failed((error["message"] as? String) ?? "v0 reported an error.")
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
            supportsVision: capabilities.supportsVision(provider: .vercelV0, modelID: request.model.id)
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
                    throw BrowsemiumError.fileNotAllowed("The v0 adapter cannot receive \(file.filename) directly.")
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
        urlRequest.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }
}
