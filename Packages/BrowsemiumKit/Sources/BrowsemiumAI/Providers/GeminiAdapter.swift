import BrowsemiumCore
import Foundation

public struct GeminiAdapter: AIProviderAdapter {
    public static let host = "generativelanguage.googleapis.com"

    public let id: AIProviderID = .gemini

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
        var components = URLComponents(string: "https://\(Self.host)/v1beta/models")!
        components.queryItems = [URLQueryItem(name: "pageSize", value: "200")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(credential, forHTTPHeaderField: "x-goog-api-key")

        let data = try await client.sendJSON(request, allowedHost: Self.host)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["models"] as? [[String: Any]] else {
            throw AIHTTPClient.HTTPError.invalidResponse
        }
        return entries.compactMap { entry in
            guard let rawName = entry["name"] as? String else { return nil }
            let modelID = Self.normalizedModelID(rawName)
            let display = entry["displayName"] as? String ?? modelID
            return AIModel(id: modelID, name: display, providerID: .gemini)
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
            if let message = ProviderJSON.errorMessage(object) {
                return .failed(message)
            }
            if let feedback = ProviderJSON.dictionary(object, "promptFeedback"),
               let reason = ProviderJSON.string(feedback, "blockReason") {
                return .failed("The provider blocked this request (\(reason)).")
            }
            guard let candidates = ProviderJSON.array(object, "candidates"),
                  let candidate = candidates.first,
                  let content = ProviderJSON.dictionary(candidate, "content"),
                  let parts = ProviderJSON.array(content, "parts") else {
                return .ignore
            }
            let text = parts.compactMap { ProviderJSON.string($0, "text") }.joined()
            if let finishReason = ProviderJSON.string(candidate, "finishReason"), !finishReason.isEmpty, finishReason != "FINISH_REASON_UNSPECIFIED" {
                if !text.isEmpty {
                    return .delta(text)
                }
                return .done
            }
            return text.isEmpty ? .ignore : .delta(text)
        }
    }

    public func makeRequest(_ request: AIRequest) throws -> URLRequest {
        let canonical = try AIRequestBuilder.build(
            request,
            policy: policy,
            supportsVision: capabilities.supportsVision(provider: .gemini, modelID: request.model.id)
        )

        let contents = try canonical.messages.map { message -> [String: Any] in
            let parts = try message.parts.map { part -> [String: Any] in
                switch part {
                case .text(let text):
                    return ["text": text]
                case .image(let image):
                    return [
                        "inline_data": [
                            "mime_type": image.mimeType,
                            "data": image.data.base64EncodedString()
                        ]
                    ]
                case .file(let file):
                    throw BrowsemiumError.fileNotAllowed("The Gemini adapter cannot receive \(file.filename) directly.")
                }
            }
            return [
                "role": message.role == .assistant ? "model" : "user",
                "parts": parts
            ]
        }

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": AIRequestBuilder.systemPrompt]]],
            "contents": contents,
            "generationConfig": ["maxOutputTokens": canonical.maxOutputTokens]
        ]

        let modelPath = Self.normalizedModelID(canonical.modelID)
        var components = URLComponents(string: "https://\(Self.host)/v1beta/models/\(modelPath):streamGenerateContent")!
        components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(credential, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    static func normalizedModelID(_ raw: String) -> String {
        raw.hasPrefix("models/") ? String(raw.dropFirst("models/".count)) : raw
    }
}
