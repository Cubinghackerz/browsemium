import BrowsemiumAgent
import CryptoKit
import Foundation
import Testing

// MARK: - HTTP parser

private func raw(_ lines: [String], body: String = "") -> Data {
    Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
}

private func post(_ body: String, extra: [String] = []) -> Data {
    raw(["POST /mcp HTTP/1.1", "Host: 127.0.0.1:9", "Content-Length: \(body.utf8.count)"] + extra, body: body)
}

@Suite("HTTP request parser")
struct HTTPRequestParserTests {
    @Test func aWellFormedPostIsParsedWithLowercasedHeaders() throws {
        guard case .request(let request) = HTTPRequestParser.parse(post("{}", extra: ["Content-Type: application/json"])) else {
            Issue.record("expected a request"); return
        }
        #expect(request.method == "POST")
        #expect(request.target == "/mcp")
        #expect(request.body == Data("{}".utf8))
        #expect(request.header("HOST") == "127.0.0.1:9")
        #expect(request.header("content-type") == "application/json")
    }

    @Test func aPartialRequestWaitsForMoreBytes() {
        let full = post("{\"a\":1}")
        #expect(HTTPRequestParser.parse(full.prefix(10)) == .needMore)
        // Headers complete, body short by one byte.
        #expect(HTTPRequestParser.parse(full.dropLast()) == .needMore)
    }

    @Test func bytesAfterTheDeclaredBodyAreNeverReadAsPartOfIt() {
        var data = post("{}")
        data.append(Data("GET /smuggled HTTP/1.1\r\n\r\n".utf8))
        guard case .request(let request) = HTTPRequestParser.parse(data) else {
            Issue.record("expected a request"); return
        }
        #expect(request.body == Data("{}".utf8))
    }

    @Test func anOversizedDeclaredBodyIsRefusedBeforeItIsRead() {
        let big = raw(["POST /mcp HTTP/1.1", "Host: x", "Content-Length: \(HTTPRequestParser.maxBodyBytes + 1)"])
        #expect(HTTPRequestParser.parse(big) == .failure(.payloadTooLarge))
        let limit = raw(["POST /mcp HTTP/1.1", "Host: x", "Content-Length: \(HTTPRequestParser.maxBodyBytes)"])
        #expect(HTTPRequestParser.parse(limit) == .needMore)
    }

    @Test func anEndlessHeaderBlockIsCutOff() {
        let flood = Data(repeating: UInt8(ascii: "a"), count: HTTPRequestParser.maxHeaderBytes + 1)
        #expect(HTTPRequestParser.parse(flood) == .failure(.headerFieldsTooLarge))
        let many = raw(["POST /mcp HTTP/1.1", "Host: x"] + (0..<80).map { "X-\($0): 1" } + ["Content-Length: 0"])
        #expect(HTTPRequestParser.parse(many) == .failure(.headerFieldsTooLarge))
    }

    @Test(arguments: [
        "Host: a\r\nHost: b",                       // duplicate Host
        "Content-Length: 1\r\nContent-Length: 1",    // duplicate length
        "Authorization: x\r\nAuthorization: y"       // duplicate credential
    ])
    func duplicateHeadersAreRefused(_ extra: String) {
        let data = raw(["POST /mcp HTTP/1.1", "Host: h", "Content-Length: 1", extra], body: "{")
        #expect(HTTPRequestParser.parse(data) == .failure(.badRequest))
    }

    @Test func requestSmugglingShapesAreRefused() {
        // Transfer-Encoding is not supported at all.
        #expect(HTTPRequestParser.parse(raw(["POST /mcp HTTP/1.1", "Host: h", "Transfer-Encoding: chunked"]))
                == .failure(.notImplemented))
        // A signed, spaced or hex length is not a length.
        for value in ["-1", "+5", "0x10", "1 2", "", "99999999"] {
            let data = raw(["POST /mcp HTTP/1.1", "Host: h", "Content-Length: \(value)"])
            guard case .failure = HTTPRequestParser.parse(data) else {
                Issue.record("Content-Length \(value.debugDescription) was accepted"); continue
            }
        }
        // Obsolete line folding.
        #expect(HTTPRequestParser.parse(raw(["POST /mcp HTTP/1.1", "Host: h", " folded: x", "Content-Length: 0"]))
                == .failure(.badRequest))
        // Bare LF inside a header line.
        let bareLF = Data("POST /mcp HTTP/1.1\r\nHost: h\nX: y\r\nContent-Length: 0\r\n\r\n".utf8)
        #expect(HTTPRequestParser.parse(bareLF) == .failure(.badRequest))
        // NUL byte.
        var nul = post("{}"); nul.insert(0, at: 20)
        #expect(HTTPRequestParser.parse(nul) == .failure(.badRequest))
    }

    @Test func onlyOriginFormHttp11RequestsAreAccepted() {
        #expect(HTTPRequestParser.parse(raw(["POST /mcp HTTP/1.0", "Host: h", "Content-Length: 0"])) == .failure(.versionNotSupported))
        #expect(HTTPRequestParser.parse(raw(["POST http://evil/mcp HTTP/1.1", "Host: h", "Content-Length: 0"])) == .failure(.badRequest))
        #expect(HTTPRequestParser.parse(raw(["POST //evil/mcp HTTP/1.1", "Host: h", "Content-Length: 0"])) == .failure(.badRequest))
        #expect(HTTPRequestParser.parse(raw(["post /mcp HTTP/1.1", "Host: h", "Content-Length: 0"])) == .failure(.badRequest))
        #expect(HTTPRequestParser.parse(raw(["POST /mcp HTTP/1.1 extra", "Host: h"])) == .failure(.badRequest))
    }

    @Test func aPostWithoutALengthAndABodyOnGetAreRefused() {
        #expect(HTTPRequestParser.parse(raw(["POST /mcp HTTP/1.1", "Host: h"])) == .failure(.lengthRequired))
        let getWithBody = raw(["GET /mcp HTTP/1.1", "Host: h", "Content-Length: 2"], body: "{}")
        #expect(HTTPRequestParser.parse(getWithBody) == .failure(.badRequest))
    }

    @Test func responsesNeverCarryCorsHeadersAndCloseTheConnection() {
        let text = String(decoding: HTTPResponse.json(.ok, Data("{}".utf8)).serialized(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(!text.lowercased().contains("access-control"))
        #expect(text.contains("Connection: close"))
        #expect(text.contains("Cache-Control: no-store"))
        #expect(text.contains("Content-Length: 2"))
        // A header value can never split the response.
        let split = HTTPResponse(status: .ok, headers: ["X-Test": "a\r\nSet-Cookie: x=1"]).serialized()
        #expect(!String(decoding: split, as: UTF8.self).contains("\r\nSet-Cookie"))
    }
}

// MARK: - Endpoint policy

private let token = "t0ken-for-tests-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

private func request(
    method: String = "POST",
    target: String = "/mcp",
    host: String? = "127.0.0.1:4000",
    auth: String? = "Bearer \(token)",
    contentType: String? = "application/json",
    extra: [String: String] = [:]
) -> HTTPRequest {
    var headers: [String: String] = [:]
    if let host { headers["host"] = host }
    if let auth { headers["authorization"] = auth }
    if let contentType { headers["content-type"] = contentType }
    for (key, value) in extra { headers[key] = value }
    return HTTPRequest(method: method, target: target, headers: headers)
}

@Suite("MCP endpoint policy")
struct MCPEndpointPolicyTests {
    private let policy = MCPEndpointPolicy(port: 4000, token: token)

    @Test func aCorrectRequestPasses() {
        #expect(policy.refusal(for: request()) == nil)
        #expect(policy.refusal(for: request(host: "localhost:4000")) == nil)
        #expect(policy.refusal(for: request(host: "LOCALHOST:4000")) == nil)
        #expect(policy.refusal(for: request(method: "DELETE", contentType: nil)) == nil)
        #expect(policy.refusal(for: request(contentType: "application/json; charset=utf-8")) == nil)
    }

    @Test(arguments: [
        "evil.example:4000",       // DNS-rebinding name
        "127.0.0.1",               // missing port
        "127.0.0.1:4001",          // wrong port
        "127.0.0.1:4000.evil.test",
        "[::1]:4000",              // not bound
        "0.0.0.0:4000",
        "127.0.0.1:4000, evil"
    ])
    func anyHostButOursIsForbidden(_ host: String) {
        #expect(policy.refusal(for: request(host: host))?.status == .forbidden)
    }

    @Test func aMissingHostIsABadRequest() {
        #expect(policy.refusal(for: request(host: nil))?.status == .badRequest)
    }

    @Test(arguments: ["https://evil.example", "null", "http://127.0.0.1:4000", ""])
    func anyBrowserOriginIsForbiddenEvenWithAValidToken(_ origin: String) {
        #expect(policy.refusal(for: request(extra: ["origin": origin]))?.status == .forbidden)
    }

    @Test(arguments: [nil, "", "Bearer", "Bearer ", "Basic \(token)", "Bearer wrong", "bearer \(token)x", "Token \(token)"])
    func aMissingOrWrongTokenIs401WithAChallenge(_ auth: String?) {
        let refusal = policy.refusal(for: request(auth: auth))
        #expect(refusal?.status == .unauthorized)
        #expect(refusal?.headers["WWW-Authenticate"] == "Bearer")
    }

    @Test func theSchemeIsCaseInsensitiveButTheTokenIsExact() {
        #expect(policy.refusal(for: request(auth: "bearer \(token)")) == nil)
        #expect(policy.refusal(for: request(auth: "BEARER \(token)")) == nil)
        #expect(policy.refusal(for: request(auth: "Bearer \(token.uppercased())"))?.status == .unauthorized)
        // An absurdly long header is rejected without hashing it.
        #expect(policy.refusal(for: request(auth: "Bearer " + String(repeating: "a", count: 5_000)))?.status == .unauthorized)
    }

    @Test func onlyTheMcpPathExists() {
        for target in ["/", "/mcp/", "/mcp?x=1", "/MCP", "/admin"] {
            #expect(policy.refusal(for: request(target: target))?.status == .notFound, "\(target)")
        }
    }

    @Test func getAndEverythingElseAreMethodNotAllowed() {
        for method in ["GET", "PUT", "PATCH", "OPTIONS", "HEAD"] {
            let refusal = policy.refusal(for: request(method: method))
            #expect(refusal?.status == .methodNotAllowed, "\(method)")
            #expect(refusal?.headers["Allow"] == "POST, DELETE")
        }
    }

    @Test func postMustBeJson() {
        for type in [nil, "text/plain", "application/x-www-form-urlencoded", "multipart/form-data; boundary=x"] {
            #expect(policy.refusal(for: request(contentType: type))?.status == .unsupportedMediaType, "\(String(describing: type))")
        }
    }

    @Test func hostAndOriginAreCheckedBeforeTheTokenSoAProbeLearnsNothing() {
        // A page on another site gets 403 whether or not it knows the token.
        #expect(policy.refusal(for: request(host: "evil.example:4000", auth: nil))?.status == .forbidden)
        #expect(policy.refusal(for: request(auth: nil, extra: ["origin": "https://evil.example"]))?.status == .forbidden)
        // The method is only revealed to an authenticated caller.
        #expect(policy.refusal(for: request(method: "GET", auth: nil))?.status == .unauthorized)
    }

    @Test func refusalsNeverEchoTheCallersInputOrTheToken() {
        let hostile = request(host: "evil.example:4000", auth: "Bearer \(token)",
                              extra: ["origin": "https://evil.example"])
        let text = String(decoding: policy.refusal(for: hostile)!.serialized(), as: UTF8.self)
        #expect(!text.contains(token))
        #expect(!text.contains("evil.example"))
    }

    @Test func tokensOfDifferentLengthNeverCompareEqual() {
        #expect(!MCPEndpointPolicy.constantTimeEqual(Data([1, 2]), Data([1, 2, 3])))
        #expect(MCPEndpointPolicy.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 3])))
        #expect(!MCPEndpointPolicy.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 4])))
    }
}

// MARK: - Rate limiter and sessions

@Suite("MCP rate limiting and sessions")
struct MCPRateLimiterTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theBucketAllowsABurstThenRefusesThenRefills() {
        var config = MCPRateLimiter.Configuration()
        config.capacity = 5
        config.refillPerSecond = 1
        var limiter = MCPRateLimiter(configuration: config, now: start)
        for _ in 0..<5 {
            let admitted = limiter.admit(now: start)
            #expect(admitted)
        }
        let sixth = limiter.admit(now: start)
        let tooSoon = limiter.admit(now: start.addingTimeInterval(0.5))
        let refilled = limiter.admit(now: start.addingTimeInterval(1.5))
        #expect(!sixth)
        #expect(!tooSoon)
        #expect(refilled)
        // Refill never exceeds capacity.
        var count = 0
        while limiter.admit(now: start.addingTimeInterval(1_000)) { count += 1 }
        #expect(count == 5)
    }

    @Test func repeatedAuthenticationFailuresLockEvenAGoodCallerOutForAWhile() {
        var config = MCPRateLimiter.Configuration()
        config.failureLimit = 3
        config.lockout = 30
        var limiter = MCPRateLimiter(configuration: config, now: start)
        for i in 0..<3 { limiter.recordAuthenticationFailure(now: start.addingTimeInterval(Double(i))) }
        let during = limiter.admit(now: start.addingTimeInterval(5))
        let stillLocked = limiter.admit(now: start.addingTimeInterval(31))
        let after = limiter.admit(now: start.addingTimeInterval(33))
        #expect(!during)
        #expect(!stillLocked)
        #expect(after)
    }

    @Test func failuresSpreadOutInTimeDoNotLockOut() {
        var config = MCPRateLimiter.Configuration()
        config.failureLimit = 3
        config.failureWindow = 10
        var limiter = MCPRateLimiter(configuration: config, now: start)
        for i in 0..<10 { limiter.recordAuthenticationFailure(now: start.addingTimeInterval(Double(i) * 20)) }
        let admitted = limiter.admit(now: start.addingTimeInterval(200))
        #expect(admitted)
    }

    @Test func sessionsAreCappedAndTheLeastRecentlyUsedIsEvicted() {
        var registry = MCPSessionRegistry()
        var ids: [String] = []
        for i in 0..<MCPSessionRegistry.maxSessions {
            ids.append(registry.start(clientName: "c\(i)", protocolVersion: "v", now: start.addingTimeInterval(Double(i))).session.id)
        }
        _ = registry.touch(ids[0], now: start.addingTimeInterval(100))   // refreshed: no longer the oldest
        let started = registry.start(clientName: "new", protocolVersion: "v", now: start.addingTimeInterval(101))
        #expect(started.evicted?.id == ids[1])
        #expect(registry.sessions.count == MCPSessionRegistry.maxSessions)
        #expect(registry.sessions[ids[0]] != nil)
    }

    @Test func idleSessionsExpireAndEndedOnesAreGone() {
        var registry = MCPSessionRegistry()
        let session = registry.start(clientName: "c", protocolVersion: "v", now: start).session
        let early = registry.expire(now: start.addingTimeInterval(MCPSessionRegistry.idleLimit - 1))
        let late = registry.expire(now: start.addingTimeInterval(MCPSessionRegistry.idleLimit + 1))
        let touched = registry.touch(session.id, now: start)
        #expect(early.isEmpty)
        #expect(late.map(\.id) == [session.id])
        #expect(touched == nil)
        let other = registry.start(clientName: "d", protocolVersion: "v", now: start).session
        let ended = registry.end(other.id)
        let endedAgain = registry.end(other.id)
        #expect(ended?.id == other.id)
        #expect(endedAgain == nil)
    }

    @Test func sessionIdsAreUnguessableAndClientIdsAreSeparate() {
        var registry = MCPSessionRegistry()
        let a = registry.start(clientName: "a", protocolVersion: "v", now: start).session
        let b = registry.start(clientName: "a", protocolVersion: "v", now: start).session
        #expect(a.id != b.id)
        #expect(a.clientID != b.clientID)
        #expect(UUID(uuidString: a.id) != nil)
    }
}
