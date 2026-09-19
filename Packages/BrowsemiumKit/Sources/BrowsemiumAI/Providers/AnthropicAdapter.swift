import BrowsemiumCore
import Foundation

public struct AnthropicAdapter: AIProviderAdapter {
    public static let host = "api.anthropic.com"
    public static let apiVersion = "2023-06-01"

    public let id: AIProviderID = .anthropic

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
        var components = URLComponents(string: "https://\(Self.host)/v1/models")!
        components.queryItems = [URLQueryItem(name: "limit", value: "100")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(credential, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")

        let data = try await client.sendJSON(request, allowedHost: Self.host)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else {
            throw AIHTTPClient.HTTPError.invalidResponse
        }
        return entries.compactMap { entry in
            guard let modelID = entry["id"] as? String else { return nil }
            let name = entry["display_name"] as? String ?? modelID
            return AIModel(id: modelID, name: name, providerID: .anthropic)
        }
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        let urlRequest: URLRequest
        do {
            urlRequest = try makeRequest(request)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return mapProviderStream(client.streamSSE(urlRequest, allowedHost: Self.host)) { event, _ in
            guard let object = ProviderJSON.object(from: event.data) else {
                return .ignore
            }
            switch ProviderJSON.string(object, "type") {
            case "content_block_delta":
                if let delta = ProviderJSON.dictionary(object, "delta"),
                   let text = ProviderJSON.string(delta, "text") {
                    return .delta(text)
                }
                return .ignore
            case "message_stop":
                return .done
            case "error":
                return .failed(ProviderJSON.errorMessage(object) ?? "The provider reported a failure.")
            default:
                return .ignore
            }
        }
    }

    public func makeRequest(_ request: AIRequest) throws -> URLRequest {
        let canonical = try AIRequestBuilder.build(
            request,
            policy: policy,
            supportsVision: capabilities.supportsVision(provider: .anthropic, modelID: request.model.id)
        )

        let messages = canonical.messages.map { message -> [String: Any] in
            let content = message.parts.map { part -> [String: Any] in
                switch part {
                case .text(let text):
                    return ["type": "text", "text": text]
                case .image(let image):
                    return [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": image.mimeType,
                            "data": image.data.base64EncodedString()
                        ]
                    ]
                }
            }
            return [
                "role": message.role == .assistant ? "assistant" : "user",
                "content": content
            ]
        }

        let body: [String: Any] = [
            "model": canonical.modelID,
            "system": AIRequestBuilder.systemPrompt,
            "messages": messages,
            "max_tokens": canonical.maxOutputTokens,
            "stream": true
        ]

        var urlRequest = URLRequest(url: URL(string: "https://\(Self.host)/v1/messages")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(credential, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }
}
