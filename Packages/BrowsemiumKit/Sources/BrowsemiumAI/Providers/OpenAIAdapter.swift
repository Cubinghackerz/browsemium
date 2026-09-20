import BrowsemiumCore
import Foundation

public struct OpenAIAdapter: AIProviderAdapter {
    public static let host = "api.openai.com"

    public let id: AIProviderID = .openAI

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
        var request = URLRequest(url: URL(string: "https://\(Self.host)/v1/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")

        let data = try await client.sendJSON(request, allowedHost: Self.host)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else {
            throw AIHTTPClient.HTTPError.invalidResponse
        }
        return entries.compactMap { entry in
            guard let modelID = entry["id"] as? String else { return nil }
            return AIModel(id: modelID, name: modelID, providerID: .openAI)
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
            case "response.output_text.delta":
                if let delta = ProviderJSON.string(object, "delta") {
                    return .delta(delta)
                }
                return .ignore
            case "response.completed":
                return .done
            case "response.failed", "error":
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
            supportsVision: capabilities.supportsVision(provider: .openAI, modelID: request.model.id),
            supportsFiles: true
        )

        let input = try canonical.messages.map { message -> [String: Any] in
            let content = try message.parts.map { part -> [String: Any] in
                switch part {
                case .text(let text):
                    return ["type": "input_text", "text": text]
                case .image(let image):
                    return ["type": "input_image", "image_url": ProviderJSON.dataURL(for: image)]
                case .file(let file):
                    let data = try Data(contentsOf: file.fileURL, options: [.mappedIfSafe])
                    return [
                        "type": "input_file",
                        "filename": file.filename,
                        "file_data": "data:\(file.mimeType);base64,\(data.base64EncodedString())"
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
            "instructions": AIRequestBuilder.systemPrompt,
            "input": input,
            "stream": true,
            "store": false,
            "max_output_tokens": canonical.maxOutputTokens
        ]

        var urlRequest = URLRequest(url: URL(string: "https://\(Self.host)/v1/responses")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }
}
