import Foundation
import Network

/// A tiny loopback HTTP server for WebKit fixture tests. It records every
/// request it receives, so a test can prove a URL was never fetched, not merely
/// that a page did not end up there.
///
/// `127.0.0.1` and `localhost` reach the same listener but are different
/// origins, which gives real cross-origin redirects with no network and no
/// third-party host.
final class FixtureServer: @unchecked Sendable {
    struct Route: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = ""
        var delay: TimeInterval = 0
    }

    struct Seen: Sendable, Equatable {
        let path: String
        let host: String
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "browsemium.fixture-server")
    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private var seenRequests: [Seen] = []
    private var boundPort: UInt16 = 0

    private init(listener: NWListener) {
        self.listener = listener
    }

    var port: UInt16 { lock.withLock { boundPort } }
    var base: String { "http://127.0.0.1:\(port)" }
    var other: String { "http://localhost:\(port)" }
    var seen: [Seen] { lock.withLock { seenRequests } }
    var seenPaths: [String] { seen.map(\.path) }

    func route(_ path: String, _ route: Route) {
        lock.withLock { routes[path] = route }
    }

    func page(_ path: String, _ body: String) {
        route(path, Route(body: body))
    }

    static func start() async throws -> FixtureServer {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let server = FixtureServer(listener: try NWListener(using: parameters))
        server.listener.newConnectionHandler = { [server] connection in server.handle(connection) }
        let once = Once()
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            server.listener.stateUpdateHandler = { [server] state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: server.listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            server.listener.start(queue: server.queue)
        }
        server.lock.withLock { server.boundPort = port }
        return server
    }

    func stop() {
        listener.cancel()
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.withLock {
                if done { return false }
                done = true
                return true
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] data, _, isComplete, error in
            var collected = buffer
            if let data { collected.append(data) }
            if let end = collected.range(of: Data("\r\n\r\n".utf8)) {
                respond(connection, header: String(decoding: collected[..<end.lowerBound], as: UTF8.self))
            } else if error != nil || isComplete || collected.count > 65_536 {
                connection.cancel()
            } else {
                receive(connection, buffer: collected)
            }
        }
    }

    private func respond(_ connection: NWConnection, header: String) {
        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        let rawPath = requestLine.count > 1 ? String(requestLine[1]) : "/"
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        let host = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }
            .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) } ?? ""

        let (route, port) = lock.withLock { () -> (Route?, UInt16) in
            seenRequests.append(Seen(path: path, host: host))
            return (routes[path], boundPort)
        }
        let resolved = route ?? Route(status: 404, body: "not found")
        let body = resolved.body.replacingOccurrences(of: "{{PORT}}", with: String(port))
        var head = "HTTP/1.1 \(resolved.status) \(resolved.status == 200 ? "OK" : "Status")\r\n"
        head += "Content-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n"
        for (name, value) in resolved.headers {
            head += "\(name): \(value.replacingOccurrences(of: "{{PORT}}", with: String(port)))\r\n"
        }
        head += "\r\n"
        let payload = Data((head + body).utf8)
        queue.asyncAfter(deadline: .now() + resolved.delay) {
            connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
