import BrowsemiumAI
import BrowsemiumCore
import Foundation
import Testing

/// Ollama speaks the OpenAI chat-completions shape, over loopback HTTP.
@Test
func ollamaRequestTargetsLocalServerWithChatCompletionsShape() throws {
    let adapter = OllamaAdapter()
    let request = AIRequest(
        model: AIModel(id: "llama3.2", name: "llama3.2", providerID: .ollama),
        messages: [AIMessage(role: .user, content: "Hello")],
        attachments: []
    )
    let urlRequest = try adapter.makeRequest(request)

    #expect(urlRequest.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
    #expect(urlRequest.httpMethod == "POST")
    // No Authorization header: a local server has no credential.
    #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == nil)

    let body = try #require(urlRequest.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == "llama3.2")
    #expect(json["stream"] as? Bool == true)
    let messages = try #require(json["messages"] as? [[String: Any]])
    #expect(messages.first?["role"] as? String == "system")
    #expect(messages.last?["role"] as? String == "user")
}

/// The HTTP client allows loopback over HTTP but still requires HTTPS for
/// remote providers.
@Test
func httpClientAllowsLoopbackButNotRemoteHTTP() async throws {
    let client = AIHTTPClient()
    var remote = URLRequest(url: URL(string: "http://api.example.com/v1/models")!)
    remote.httpMethod = "GET"
    await #expect(throws: AIHTTPClient.HTTPError.self) {
        _ = try await client.sendJSON(remote, allowedHost: "api.example.com")
    }
}
