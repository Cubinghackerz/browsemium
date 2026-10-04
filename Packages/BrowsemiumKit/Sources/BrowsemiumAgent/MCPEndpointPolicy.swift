import CryptoKit
import Foundation

/// Decides, before any JSON is read, whether a request may reach the MCP
/// service. The order is deliberate: Host and Origin first (DNS rebinding and
/// browser pages), then the path, then the bearer token, and only then the
/// method — an unauthenticated caller learns nothing beyond "refused".
public struct MCPEndpointPolicy: Sendable {
    public static let path = "/mcp"

    public let port: UInt16
    private let tokenDigest: Data

    public init(port: UInt16, token: String) {
        self.port = port
        self.tokenDigest = Data(SHA256.hash(data: Data(token.utf8)))
    }

    /// Returns a refusal, or nil when the request may proceed.
    public func refusal(for request: HTTPRequest) -> HTTPResponse? {
        guard let host = request.header("host")?.lowercased() else { return .refusal(.badRequest) }
        // Exactly the loopback names on exactly our port. A page reaching us
        // through a rebound DNS name sends that name here and is refused.
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else { return .refusal(.forbidden) }

        // Browsers attach Origin to cross-site requests and to every
        // fetch/XHR POST. Non-browser MCP clients do not send it. Any value —
        // including "null" — is refused, and no CORS headers are ever sent.
        guard request.header("origin") == nil else { return .refusal(.forbidden) }

        guard request.target == Self.path else { return .refusal(.notFound) }

        guard isAuthorized(request.header("authorization")) else {
            return .refusal(.unauthorized, headers: ["WWW-Authenticate": "Bearer"])
        }

        switch request.method {
        case "POST":
            let type = request.header("content-type")?
                .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard type == "application/json" else { return .refusal(.unsupportedMediaType) }
            return nil
        case "DELETE":
            return nil
        default:
            // This server offers no SSE stream, so GET is not supported.
            return .refusal(.methodNotAllowed, headers: ["Allow": "POST, DELETE"])
        }
    }

    private func isAuthorized(_ header: String?) -> Bool {
        guard let header, header.count <= 600 else { return false }
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        let presented = Data(SHA256.hash(data: Data(parts[1].utf8)))
        return Self.constantTimeEqual(presented, tokenDigest)
    }

    public static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}

/// A token bucket plus an authentication-failure lockout. One bucket covers
/// the whole endpoint, so no tool (status polling, opening tabs) can be used
/// to flood the browser, and a guesser is slowed to a crawl.
public struct MCPRateLimiter: Sendable {
    public struct Configuration: Sendable {
        public var capacity: Double = 60
        public var refillPerSecond: Double = 10
        public var failureLimit = 10
        public var failureWindow: TimeInterval = 60
        public var lockout: TimeInterval = 30

        public init() {}
    }

    private let configuration: Configuration
    private var tokens: Double
    private var lastRefill: Date
    private var failures: [Date] = []
    private var lockedUntil: Date?

    public init(configuration: Configuration = Configuration(), now: Date = Date()) {
        self.configuration = configuration
        self.tokens = configuration.capacity
        self.lastRefill = now
    }

    /// Whether a request may be handled right now. Locked-out callers are
    /// refused even with a correct token, until the lockout ends.
    public mutating func admit(now: Date = Date()) -> Bool {
        if let lockedUntil {
            if now < lockedUntil { return false }
            self.lockedUntil = nil
            failures.removeAll()
        }
        let elapsed = max(0, now.timeIntervalSince(lastRefill))
        tokens = min(configuration.capacity, tokens + elapsed * configuration.refillPerSecond)
        lastRefill = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }

    public mutating func recordAuthenticationFailure(now: Date = Date()) {
        let window = configuration.failureWindow
        failures.removeAll { now.timeIntervalSince($0) > window }
        failures.append(now)
        if failures.count >= configuration.failureLimit {
            lockedUntil = now.addingTimeInterval(configuration.lockout)
        }
    }
}

/// One client conversation. The id is a random UUID the server issues in
/// `initialize`; it identifies a client to the gate and is not a credential.
public struct MCPSession: Sendable {
    public let id: String
    public let clientID: UUID
    public let clientName: String
    public let protocolVersion: String
    public var lastSeen: Date
}

public struct MCPSessionRegistry: Sendable {
    public static let maxSessions = 8
    public static let idleLimit: TimeInterval = 10 * 60

    public private(set) var sessions: [String: MCPSession] = [:]

    public init() {}

    /// Starts a session, evicting the least recently used one if the table is
    /// full. Returns the new session and any session that was evicted.
    public mutating func start(clientName: String, protocolVersion: String, now: Date) -> (session: MCPSession, evicted: MCPSession?) {
        var evicted: MCPSession?
        if sessions.count >= Self.maxSessions,
           let oldest = sessions.values.min(by: { $0.lastSeen < $1.lastSeen }) {
            sessions[oldest.id] = nil
            evicted = oldest
        }
        let session = MCPSession(
            id: UUID().uuidString,
            clientID: UUID(),
            clientName: clientName,
            protocolVersion: protocolVersion,
            lastSeen: now
        )
        sessions[session.id] = session
        return (session, evicted)
    }

    public mutating func touch(_ id: String, now: Date) -> MCPSession? {
        guard var session = sessions[id] else { return nil }
        session.lastSeen = now
        sessions[id] = session
        return session
    }

    @discardableResult
    public mutating func end(_ id: String) -> MCPSession? {
        sessions.removeValue(forKey: id)
    }

    /// Removes and returns sessions idle past the limit.
    public mutating func expire(now: Date) -> [MCPSession] {
        let stale = sessions.values.filter { now.timeIntervalSince($0.lastSeen) > Self.idleLimit }
        for session in stale { sessions[session.id] = nil }
        return stale
    }
}
