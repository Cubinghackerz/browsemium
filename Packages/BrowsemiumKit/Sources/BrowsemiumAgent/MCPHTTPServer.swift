import Foundation
import Network
import os

/// The loopback HTTP listener for the MCP endpoint. It binds 127.0.0.1 only —
/// never a network interface — handles one request per connection, and
/// bounds connections, bytes, time and request rate. All logic after the
/// bytes arrive lives in `HTTPRequestParser`, `MCPEndpointPolicy` and
/// `MCPService`, which are testable without a socket.
@MainActor
public final class MCPHTTPServer {
    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    public static let maxConnections = 16
    private static let log = Logger(subsystem: "com.browsemium.agent", category: "endpoint")
    /// A client has this long to deliver a complete request. Settable so tests
    /// can shorten it; the shipped value is the default.
    public var requestDeadline: Duration = .seconds(10)

    public private(set) var state: State = .stopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public var onStateChange: (@MainActor (State) -> Void)?

    private let service: MCPService
    private let token: String
    private let requestedPort: UInt16
    private var listener: NWListener?
    private var policy: MCPEndpointPolicy?
    private var limiter = MCPRateLimiter()
    private var connections: [ObjectIdentifier: MCPConnection] = [:]
    private var sweeper: Task<Void, Never>?
    private var generation = 0

    /// `port` 0 asks the system for a free one (tests); the app uses a fixed
    /// port so client configuration stays valid.
    public init(service: MCPService, token: String, port: UInt16) {
        self.service = service
        self.token = token
        self.requestedPort = port
    }

    public func start() {
        guard listener == nil else { return }
        state = .starting
        generation += 1
        let current = generation
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            parameters.allowLocalEndpointReuse = true
            let port = NWEndpoint.Port(rawValue: requestedPort) ?? .any
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
            let listener = try NWListener(using: parameters)

            listener.stateUpdateHandler = { [weak self] newState in
                MainActor.assumeIsolated { self?.listenerChanged(newState, generation: current) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection, generation: current) }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            Self.log.error("Listener could not be created: \(String(describing: error), privacy: .public)")
            state = .failed("The local endpoint could not start.")
        }
    }

    public func stop() {
        generation += 1
        listener?.cancel()
        listener = nil
        sweeper?.cancel()
        sweeper = nil
        for connection in connections.values { connection.close() }
        connections.removeAll()
        service.endAllSessions()
        policy = nil
        state = .stopped
    }

    // MARK: - Listener

    private func listenerChanged(_ newState: NWListener.State, generation: Int) {
        guard generation == self.generation else { return }
        switch newState {
        case .ready:
            guard let port = listener?.port?.rawValue else {
                state = .failed("The local endpoint has no port.")
                return
            }
            policy = MCPEndpointPolicy(port: port, token: token)
            service.endpointPort = port
            state = .listening(port: port)
            startSweeping(generation: generation)
        case .failed(let error):
            // Most often "address in use". Shut down fully so a later start is clean.
            Self.log.error("Listener failed: \(String(describing: error), privacy: .public)")
            listener?.cancel()
            listener = nil
            state = .failed("The local endpoint port is unavailable.")
        case .cancelled:
            break
        default:
            break
        }
    }

    private func startSweeping(generation: Int) {
        sweeper?.cancel()
        sweeper = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.generation == generation else { return }
                self.service.sweep()
            }
        }
    }

    private func accept(_ raw: NWConnection, generation: Int) {
        guard generation == self.generation, policy != nil,
              connections.count < Self.maxConnections else {
            raw.cancel()
            return
        }
        let connection = MCPConnection(raw, deadline: requestDeadline) { [weak self] request in
            await self?.respond(to: request) ?? .refusal(.internalServerError)
        } onClose: { [weak self] id in
            self?.connections[id] = nil
        }
        connections[connection.id] = connection
        connection.start()
    }

    private func respond(to request: HTTPRequest) async -> HTTPResponse {
        guard let policy else { return .refusal(.internalServerError) }
        guard limiter.admit() else { return .refusal(.tooManyRequests, headers: ["Retry-After": "5"]) }
        if let refusal = policy.refusal(for: request) {
            if refusal.status == .unauthorized { limiter.recordAuthenticationFailure() }
            return refusal
        }
        return await service.handle(request)
    }
}

/// One accepted socket: read a bounded request, answer once, close.
@MainActor
final class MCPConnection {
    let id: ObjectIdentifier
    private let connection: NWConnection
    private let requestDeadline: Duration
    private let handler: @MainActor (HTTPRequest) async -> HTTPResponse
    private let onClose: @MainActor (ObjectIdentifier) -> Void
    private var buffer = Data()
    private var finished = false
    private var deadline: Task<Void, Never>?

    init(
        _ connection: NWConnection,
        deadline: Duration,
        handler: @escaping @MainActor (HTTPRequest) async -> HTTPResponse,
        onClose: @escaping @MainActor (ObjectIdentifier) -> Void
    ) {
        self.id = ObjectIdentifier(connection)
        self.connection = connection
        self.requestDeadline = deadline
        self.handler = handler
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.requestDeadline ?? .seconds(10))
            guard !Task.isCancelled, let self, !self.finished, !self.hasRequest else { return }
            self.send(.refusal(.badRequest))
        }
        receive()
    }

    private var hasRequest = false

    func close() {
        deadline?.cancel()
        finished = true
        connection.cancel()
        onClose(id)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.finished, !self.hasRequest else { return }
                if let data { self.buffer.append(data) }
                if error != nil || (isComplete && data == nil) { self.close(); return }

                switch HTTPRequestParser.parse(self.buffer) {
                case .needMore:
                    if isComplete { self.close() } else { self.receive() }
                case .failure(let status):
                    self.send(.refusal(status))
                case .request(let request):
                    self.hasRequest = true
                    self.deadline?.cancel()
                    Task { @MainActor in
                        let response = await self.handler(request)
                        self.send(response)
                    }
                }
            }
        }
    }

    private func send(_ response: HTTPResponse) {
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        connection.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }
}
