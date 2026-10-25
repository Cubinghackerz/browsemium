import BrowsemiumAgent
import BrowsemiumCore
import Foundation
import Testing

private let loopbackToken = "loopback-client-token-cccccccccccccccccccccccccccccccccc"

/// A client the way a real agent runs: `URLSession` over the loopback
/// interface, with the headers MCP clients send. Everything else in the
/// transport suite uses a raw socket; this proves an ordinary HTTP client works.
@Suite("MCP loopback: separate URLSession client", .serialized)
@MainActor
struct MCPLoopbackClientTests {
    private struct Reply {
        let status: Int
        let headers: [String: String]
        let json: [String: Any]?
    }

    private struct SetupFailure: Error, CustomStringConvertible {
        let description: String
    }

    private func start() async throws -> (MCPHarness, MCPHTTPServer, UInt16) {
        let h = try MCPHarness()
        let server = MCPHTTPServer(service: h.service, token: loopbackToken, port: 0)
        server.start()
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            if case .listening(let port) = server.state { return (h, server, port) }
            if case .failed(let message) = server.state { throw SetupFailure(description: message) }
            if ContinuousClock.now > deadline { throw SetupFailure(description: "listener never became ready") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }

    private func post(
        _ client: URLSession, port: UInt16, token: String? = loopbackToken,
        session id: String? = nil, _ object: [String: Any]
    ) async throws -> Reply {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let id {
            request.setValue(id, forHTTPHeaderField: "Mcp-Session-Id")
            request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: object)
        let (data, response) = try await client.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields { headers["\(key)".lowercased()] = "\(value)" }
        return Reply(
            status: http.statusCode, headers: headers,
            json: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        )
    }

    @Test func initializeThenListThenADeclinedTaskOverRealHTTP() async throws {
        let (h, server, port) = try await start()
        defer { server.stop() }
        h.recorder.error = AgentError.declined
        let client = session()

        let initialize = try await post(client, port: port, [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "URLSession Client"]]
        ])
        #expect(initialize.status == 200)
        let sessionID = try #require(initialize.headers["mcp-session-id"])
        #expect((initialize.json?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")

        let tools = try await post(client, port: port, session: sessionID, [
            "jsonrpc": "2.0", "id": 2, "method": "tools/list"
        ])
        #expect(tools.status == 200)
        let names = ((tools.json?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String } ?? []
        #expect(names.contains("browsemium_request_task"))
        #expect(names.contains("browsemium_page_tool_call"))

        let requested = try await post(client, port: port, session: sessionID, [
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "browsemium_request_task",
                       "arguments": ["title": "Check an order", "origins": ["https://fixture.test"]]]
        ])
        #expect(requested.status == 200)
        let result = try #require(requested.json?["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true, "The person declined, so the tool reports an error")
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(text.contains("declined"))

        // The card was shown once, and nothing started.
        #expect(h.recorder.requests.count == 1)
        #expect(h.recorder.requests.first?.clientName == "URLSession Client")
        #expect(h.gateHarness.gate.task == nil)
        #expect(h.gateHarness.actuator.calls.isEmpty, "No page was created for a declined task")
    }

    @Test func aMissingOrWrongTokenIsRefusedWithAChallenge() async throws {
        let (_, server, port) = try await start()
        defer { server.stop() }
        let client = session()
        let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "ping"]

        let missing = try await post(client, port: port, token: nil, body)
        #expect(missing.status == 401)
        #expect(missing.headers["www-authenticate"] != nil)
        let wrong = try await post(client, port: port, token: "not-the-token", body)
        #expect(wrong.status == 401)
    }

    @Test func theLoopbackServerNeedsNoEntitlementBeyondTheOneAlreadyShipped() throws {
        // The WebKit app carries network.server for this listener only; the
        // Chromium edition must not gain it, and nothing else may be added.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let webkit = try plist(root.appendingPathComponent("BrowsemiumApp/Config/Browsemium.entitlements"))
        #expect(webkit["com.apple.security.network.server"] as? Bool == true)
        #expect(webkit["com.apple.security.network.client"] as? Bool == true)
        let networkKeys = webkit.keys.filter { $0.hasPrefix("com.apple.security.network.") }.sorted()
        #expect(networkKeys == ["com.apple.security.network.client", "com.apple.security.network.server"])
        #expect(webkit["com.apple.security.temporary-exception.apple-events"] == nil)
        let chromium = root.appendingPathComponent("BrowsemiumChromiumApp/Config/BrowsemiumChromium.entitlements")
        if FileManager.default.fileExists(atPath: chromium.path) {
            #expect(try plist(chromium)["com.apple.security.network.server"] == nil)
        }
    }

    private func plist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }
}
