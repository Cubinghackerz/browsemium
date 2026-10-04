import BrowsemiumAgent
import Foundation
import Network
import Testing

private let token = "socket-test-token-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

/// A one-shot raw TCP client, so tests control every byte (a URL loader would
/// normalize the Host header and refuse to send hostile shapes).
@MainActor
private final class RawClient {
    private let connection: NWConnection
    private var buffer = Data()
    private var waiting: CheckedContinuation<String?, Never>?
    private var finished = false
    private var result: String?
    private var opened = false

    init(host: NWEndpoint.Host, port: UInt16) {
        connection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    /// Sends `bytes` and returns everything the server wrote before closing,
    /// or nil if the connection could not be made or was closed with no data.
    func exchange(_ bytes: Data?, timeout: Duration = .seconds(8)) async -> String? {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.opened = true
                    if let bytes {
                        self.connection.send(content: bytes, completion: .contentProcessed { _ in })
                    }
                    self.read()
                case .failed, .cancelled:
                    self.finish()
                case .waiting:
                    // No route / refused: nothing will ever arrive.
                    self.finish()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        let guardTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finish()
        }
        let text = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            if finished { continuation.resume(returning: result) } else { waiting = continuation }
        }
        guardTask.cancel()
        connection.cancel()
        return text
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return }
                if let data { self.buffer.append(data) }
                if isComplete || error != nil { self.finish() } else { self.read() }
            }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        result = buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
        waiting?.resume(returning: result)
        waiting = nil
    }

    /// Holds a socket open without sending anything.
    func hold() {
        connection.start(queue: .main)
    }

    func cancel() { connection.cancel() }
}

private func status(_ response: String?) -> Int? {
    guard let line = response?.split(separator: "\r\n").first, line.hasPrefix("HTTP/1.1 ") else { return nil }
    return Int(line.dropFirst(9).prefix(3))
}

private func body(_ response: String?) -> String {
    response?.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n") ?? ""
}

private func header(_ response: String?, _ name: String) -> String? {
    for line in (response ?? "").components(separatedBy: "\r\n") {
        if line.lowercased().hasPrefix(name.lowercased() + ": ") { return String(line.dropFirst(name.count + 2)) }
    }
    return nil
}

private func http(
    _ method: String = "POST",
    port: UInt16,
    host: String? = nil,
    auth: String? = "Bearer \(token)",
    body: String = "",
    extra: [String] = []
) -> Data {
    var lines = ["\(method) /mcp HTTP/1.1", "Host: \(host ?? "127.0.0.1:\(port)")"]
    if let auth { lines.append("Authorization: \(auth)") }
    if method == "POST" { lines.append("Content-Type: application/json") }
    lines.append("Content-Length: \(body.utf8.count)")
    lines += extra
    return Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
}

private let initializeBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"Socket Test"}}}"#

@Suite("MCP loopback server", .serialized)
@MainActor
struct MCPServerSocketTests {
    private func started(token: String = token, requestDeadline: Duration = .seconds(10)) async throws -> (MCPHarness, MCPHTTPServer, UInt16) {
        let h = try MCPHarness()
        let server = MCPHTTPServer(service: h.service, token: token, port: 0)
        server.requestDeadline = requestDeadline
        server.start()
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            if case .listening(let port) = server.state { return (h, server, port) }
            if case .failed(let message) = server.state { throw TestFailure(message) }
            if ContinuousClock.now > deadline { throw TestFailure("listener never became ready") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @Test func aSeparateConnectionCanInitializeAndListTools() async throws {
        let (h, server, port) = try await started()
        defer { server.stop() }

        let initialize = await RawClient(host: .ipv4(.loopback), port: port)
            .exchange(http(port: port, body: initializeBody))
        #expect(status(initialize) == 200)
        let session = try #require(header(initialize, "Mcp-Session-Id"))
        #expect(body(initialize).contains("\"protocolVersion\":\"2025-06-18\""))
        #expect(header(initialize, "Connection") == "close")
        #expect(header(initialize, "Access-Control-Allow-Origin") == nil)

        let list = await RawClient(host: .ipv4(.loopback), port: port).exchange(http(
            port: port, body: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, extra: ["Mcp-Session-Id: \(session)"]))
        #expect(status(list) == 200)
        #expect(body(list).contains("browsemium_request_task"))
        #expect(h.gateHarness.actuator.calls.isEmpty)
    }

    @Test func theHostnameFormOfLoopbackWorksToo() async throws {
        let (_, server, port) = try await started()
        defer { server.stop() }
        let reply = await RawClient(host: .ipv4(.loopback), port: port)
            .exchange(http(port: port, host: "localhost:\(port)", body: initializeBody))
        #expect(status(reply) == 200)
    }

    @Test func missingOrWrongCredentialsAreRefusedBeforeAnyJsonIsRead() async throws {
        let (h, server, port) = try await started()
        defer { server.stop() }
        for auth in [nil, "Bearer nope", "Basic \(token)"] as [String?] {
            let reply = await RawClient(host: .ipv4(.loopback), port: port)
                .exchange(http(port: port, auth: auth, body: initializeBody))
            #expect(status(reply) == 401, "\(String(describing: auth))")
            #expect(header(reply, "WWW-Authenticate") == "Bearer")
            #expect(!body(reply).contains("protocolVersion"))
        }
        #expect(h.service.registry.sessions.isEmpty)
    }

    @Test func aRebindingHostOrABrowserOriginIsRefusedEvenWithTheToken() async throws {
        let (h, server, port) = try await started()
        defer { server.stop() }
        let rebinding = await RawClient(host: .ipv4(.loopback), port: port)
            .exchange(http(port: port, host: "evil.example:\(port)", body: initializeBody))
        #expect(status(rebinding) == 403)
        let browser = await RawClient(host: .ipv4(.loopback), port: port)
            .exchange(http(port: port, body: initializeBody, extra: ["Origin: https://evil.example"]))
        #expect(status(browser) == 403)
        #expect(h.service.registry.sessions.isEmpty)
    }

    @Test func getIsNotOfferedAndAnEmptyDeleteIsNotFound() async throws {
        let (_, server, port) = try await started()
        defer { server.stop() }
        let get = await RawClient(host: .ipv4(.loopback), port: port).exchange(http("GET", port: port))
        #expect(status(get) == 405)
        #expect(header(get, "Allow") == "POST, DELETE")
        let delete = await RawClient(host: .ipv4(.loopback), port: port).exchange(http("DELETE", port: port))
        #expect(status(delete) == 404)
    }

    @Test func malformedAndOversizedRequestsAreRefusedWithoutReadingTheBody() async throws {
        let (_, server, port) = try await started()
        defer { server.stop() }
        let huge = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: \(HTTPRequestParser.maxBodyBytes + 1)\r\n\r\n".utf8)
        #expect(status(await RawClient(host: .ipv4(.loopback), port: port).exchange(huge)) == 413)
        #expect(status(await RawClient(host: .ipv4(.loopback), port: port).exchange(Data("garbage\r\n\r\n".utf8))) == 400)
        #expect(status(await RawClient(host: .ipv4(.loopback), port: port)
            .exchange(Data("POST /mcp HTTP/1.0\r\n\r\n".utf8))) == 505)
        let flood = Data(repeating: UInt8(ascii: "a"), count: HTTPRequestParser.maxHeaderBytes + 100)
        #expect(status(await RawClient(host: .ipv4(.loopback), port: port).exchange(flood)) == 431)
    }

    @Test func aBodyJustUnderTheCeilingIsAccepted() async throws {
        let (_, server, port) = try await started()
        defer { server.stop() }
        let padding = String(repeating: " ", count: HTTPRequestParser.maxBodyBytes - initializeBody.utf8.count)
        let reply = await RawClient(host: .ipv4(.loopback), port: port)
            .exchange(http(port: port, body: initializeBody + padding), timeout: .seconds(15))
        #expect(status(reply) == 200)
    }

    @Test func aSilentClientIsCutOffAtTheDeadline() async throws {
        let (_, server, port) = try await started(requestDeadline: .milliseconds(300))
        defer { server.stop() }
        let started = ContinuousClock.now
        let partial = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n".utf8)   // never finishes
        let reply = await RawClient(host: .ipv4(.loopback), port: port).exchange(partial, timeout: .seconds(5))
        #expect(status(reply) == 400)
        #expect(ContinuousClock.now - started < .seconds(4))
    }

    @Test func connectionsAreBoundedAndTheServerRecoversWhenTheyClose() async throws {
        let (_, server, port) = try await started(requestDeadline: .seconds(30))
        defer { server.stop() }
        var holders: [RawClient] = []
        for _ in 0..<MCPHTTPServer.maxConnections {
            let client = RawClient(host: .ipv4(.loopback), port: port)
            client.hold()
            holders.append(client)
        }
        try await Task.sleep(for: .milliseconds(500))
        let extra = await RawClient(host: .ipv4(.loopback), port: port)
            .exchange(http(port: port, body: initializeBody), timeout: .seconds(2))
        #expect(extra == nil, "the connection over the limit must be dropped, not served")

        for holder in holders { holder.cancel() }
        try await Task.sleep(for: .milliseconds(500))
        let after = await RawClient(host: .ipv4(.loopback), port: port).exchange(http(port: port, body: initializeBody))
        #expect(status(after) == 200)
    }

    @Test func aFloodIsRateLimited() async throws {
        let (_, server, port) = try await started()
        defer { server.stop() }
        var limited = 0
        for _ in 0..<80 {
            let reply = await RawClient(host: .ipv4(.loopback), port: port)
                .exchange(http(port: port, body: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#))
            if status(reply) == 429 { limited += 1 }
        }
        #expect(limited > 0)
    }

    @Test func guessingTheTokenLocksTheEndpointEvenForTheRealToken() async throws {
        let (_, server, port) = try await started()
        defer { server.stop() }
        for _ in 0..<10 {
            _ = await RawClient(host: .ipv4(.loopback), port: port).exchange(http(port: port, auth: "Bearer guess", body: initializeBody))
        }
        let locked = await RawClient(host: .ipv4(.loopback), port: port).exchange(http(port: port, body: initializeBody))
        #expect(status(locked) == 429)
    }

    @Test func theListenerIsNotReachableOnAnyNetworkInterface() async throws {
        let (_, server, port) = try await started()
        defer { server.stop() }
        guard let lan = Self.nonLoopbackIPv4() else {
            // No other interface (e.g. offline VM): nothing to probe. The
            // loopback tests above still cover the reachable side.
            return
        }
        let reply = await RawClient(host: .ipv4(lan), port: port)
            .exchange(http(port: port, host: "\(lan):\(port)", body: initializeBody), timeout: .seconds(4))
        #expect(reply == nil, "the endpoint answered on \(lan)")
    }

    @Test func stoppingClosesTheListenerAndRevokesEverySession() async throws {
        let (h, server, port) = try await started()
        _ = await RawClient(host: .ipv4(.loopback), port: port).exchange(http(port: port, body: initializeBody))
        #expect(h.service.registry.sessions.count == 1)
        server.stop()
        #expect(server.state == .stopped)
        #expect(h.service.registry.sessions.isEmpty)
        let after = await RawClient(host: .ipv4(.loopback), port: port)
            .exchange(http(port: port, body: initializeBody), timeout: .seconds(3))
        #expect(after == nil)
    }

    @Test func aPortThatIsTakenReportsAFailureInsteadOfSharing() async throws {
        let (_, first, port) = try await started()
        defer { first.stop() }
        let h = try MCPHarness()
        let second = MCPHTTPServer(service: h.service, token: token, port: port)
        second.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while second.state == .starting, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        defer { second.stop() }
        guard case .failed = second.state else {
            Issue.record("expected failure, got \(second.state)"); return
        }
    }

    private static func nonLoopbackIPv4() -> IPv4Address? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        for cursor in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = cursor.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var copy = value
            let data = Data(bytes: &copy, count: MemoryLayout<in_addr>.size)
            if let ip = IPv4Address(data), !ip.isLinkLocal { return ip }
        }
        return nil
    }
}
