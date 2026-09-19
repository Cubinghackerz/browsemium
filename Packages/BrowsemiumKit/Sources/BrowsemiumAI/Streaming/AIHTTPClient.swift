import BrowsemiumCore
import Foundation

public struct AIHTTPClient: Sendable {
    public enum HTTPError: Error, LocalizedError, Equatable {
        case invalidResponse
        case hostNotAllowed(String)
        case status(Int, String)
        case transport(String)

        public var errorDescription: String? {
            switch self {
            case .invalidResponse:
                "The provider returned an unreadable response."
            case .hostNotAllowed(let host):
                "Requests to \(host) are not allowed."
            case .status(let code, let message):
                message.isEmpty ? "The provider returned status \(code)." : message
            case .transport(let message):
                message
            }
        }
    }

    private let session: URLSession

    public init(timeout: TimeInterval = 120) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    public func sendJSON(_ request: URLRequest, allowedHost: String) async throws -> Data {
        try validate(request, allowedHost: allowedHost)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HTTPError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw Self.error(from: http.statusCode, body: data)
            }
            return data
        } catch let error as HTTPError {
            throw error
        } catch let error as BrowsemiumError {
            throw error
        } catch {
            throw HTTPError.transport(error.localizedDescription)
        }
    }

    public func streamSSE(_ request: URLRequest, allowedHost: String) -> AsyncThrowingStream<SSEParser.Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try validate(request, allowedHost: allowedHost)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw HTTPError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 4096 { break }
                        }
                        throw Self.error(from: http.statusCode, body: Data(body.utf8))
                    }

                    var parser = SSEParser()
                    for try await line in bytes.lines {
                        for event in parser.consume(line + "\n") {
                            continuation.yield(event)
                        }
                    }
                    for event in parser.finish() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as HTTPError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: HTTPError.transport(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func validate(_ request: URLRequest, allowedHost: String) throws {
        guard let url = request.url, let host = url.host?.lowercased() else {
            throw HTTPError.invalidResponse
        }
        guard url.scheme?.lowercased() == "https" else {
            throw HTTPError.hostNotAllowed(url.absoluteString)
        }
        guard host == allowedHost.lowercased() else {
            throw HTTPError.hostNotAllowed(host)
        }
    }

    static func error(from statusCode: Int, body: Data) -> HTTPError {
        let text = String(decoding: body, as: UTF8.self)
        let message: String
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let detail = error["message"] as? String {
                message = detail
            } else if let detail = json["message"] as? String {
                message = detail
            } else {
                message = ""
            }
        } else {
            message = ""
        }

        switch statusCode {
        case 401, 403:
            return .status(statusCode, "The provider rejected this credential. Check the key in AI settings.")
        case 404:
            return .status(statusCode, message.isEmpty ? "The selected model is not available for this credential." : message)
        case 429:
            return .status(statusCode, message.isEmpty ? "The provider rate limit was reached. Try again shortly." : message)
        default:
            return .status(statusCode, message.isEmpty ? "The provider returned status \(statusCode)." : message)
        }
    }
}
