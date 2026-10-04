import Foundation

/// A parsed HTTP/1.1 request. Header names are lowercased; every header
/// appears at most once, because a duplicated `Host`, `Content-Length` or
/// `Authorization` is how request-smuggling and confusion attacks start.
public struct HTTPRequest: Sendable, Equatable {
    public let method: String
    public let target: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, target: String, headers: [String: String], body: Data = Data()) {
        self.method = method
        self.target = target
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public enum HTTPStatus: Int, Sendable {
    case ok = 200
    case accepted = 202
    case badRequest = 400
    case unauthorized = 401
    case forbidden = 403
    case notFound = 404
    case methodNotAllowed = 405
    case lengthRequired = 411
    case payloadTooLarge = 413
    case unsupportedMediaType = 415
    case tooManyRequests = 429
    case headerFieldsTooLarge = 431
    case internalServerError = 500
    case notImplemented = 501
    case versionNotSupported = 505

    var reason: String {
        switch self {
        case .ok: "OK"
        case .accepted: "Accepted"
        case .badRequest: "Bad Request"
        case .unauthorized: "Unauthorized"
        case .forbidden: "Forbidden"
        case .notFound: "Not Found"
        case .methodNotAllowed: "Method Not Allowed"
        case .lengthRequired: "Length Required"
        case .payloadTooLarge: "Payload Too Large"
        case .unsupportedMediaType: "Unsupported Media Type"
        case .tooManyRequests: "Too Many Requests"
        case .headerFieldsTooLarge: "Request Header Fields Too Large"
        case .internalServerError: "Internal Server Error"
        case .notImplemented: "Not Implemented"
        case .versionNotSupported: "HTTP Version Not Supported"
        }
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: HTTPStatus
    public var headers: [String: String]
    public var body: Data

    public init(status: HTTPStatus, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ status: HTTPStatus = .ok, _ body: Data, headers: [String: String] = [:]) -> HTTPResponse {
        var all = headers
        all["Content-Type"] = "application/json"
        return HTTPResponse(status: status, headers: all, body: body)
    }

    /// A plain refusal with no detail an attacker could probe.
    public static func refusal(_ status: HTTPStatus, headers: [String: String] = [:]) -> HTTPResponse {
        var all = headers
        all["Content-Type"] = "text/plain; charset=utf-8"
        return HTTPResponse(status: status, headers: all, body: Data(status.reason.utf8))
    }

    /// Never emits CORS headers: no web page may read this endpoint.
    public func serialized() -> Data {
        var lines = ["HTTP/1.1 \(status.rawValue) \(status.reason)"]
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        all["Cache-Control"] = "no-store"
        all["X-Content-Type-Options"] = "nosniff"
        for key in all.keys.sorted() {
            // Values are built by this module; strip line breaks anyway so a
            // future header can never split the response.
            let value = String(String.UnicodeScalarView(all[key]!.unicodeScalars.filter { $0 != "\r" && $0 != "\n" }))
            lines.append("\(key): \(value)")
        }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        return data
    }
}

public enum HTTPParseResult: Sendable, Equatable {
    case needMore
    case request(HTTPRequest)
    case failure(HTTPStatus)
}

/// A strict, bounded HTTP/1.1 request parser. It accepts only what the MCP
/// endpoint needs — origin-form targets, `Content-Length` bodies — and refuses
/// the rest, rather than interpreting ambiguous input.
public enum HTTPRequestParser {
    public static let maxHeaderBytes = 16 * 1024
    public static let maxHeaderCount = 64
    public static let maxBodyBytes = 256 * 1024
    public static let maxTargetLength = 2_048

    private static let terminator = Data("\r\n\r\n".utf8)

    public static func parse(_ buffer: Data) -> HTTPParseResult {
        guard let end = buffer.range(of: terminator) else {
            return buffer.count > maxHeaderBytes ? .failure(.headerFieldsTooLarge) : .needMore
        }
        let headerLength = end.lowerBound - buffer.startIndex
        guard headerLength <= maxHeaderBytes else { return .failure(.headerFieldsTooLarge) }
        let headerBytes = buffer[buffer.startIndex..<end.lowerBound]
        guard !headerBytes.contains(0), let text = String(data: headerBytes, encoding: .utf8) else {
            return .failure(.badRequest)
        }

        // Bare CR or LF anywhere would let a proxy and this parser disagree
        // about where a line ends.
        let lines = text.components(separatedBy: "\r\n")
        for line in lines where line.contains("\r") || line.contains("\n") { return .failure(.badRequest) }
        guard let requestLine = lines.first else { return .failure(.badRequest) }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return .failure(.badRequest) }
        let method = String(parts[0])
        let target = String(parts[1])
        guard !method.isEmpty, method.utf8.allSatisfy({ $0 >= 0x41 && $0 <= 0x5A }),
              target.hasPrefix("/"), !target.hasPrefix("//"),
              target.utf8.count <= maxTargetLength,
              target.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else {
            return .failure(.badRequest)
        }
        guard parts[2] == "HTTP/1.1" else { return .failure(.versionNotSupported) }

        var headers: [String: String] = [:]
        let fieldLines = lines.dropFirst()
        guard fieldLines.count <= maxHeaderCount else { return .failure(.headerFieldsTooLarge) }
        for line in fieldLines {
            // A leading space or tab is an obsolete line fold: refuse it.
            guard let first = line.first, first != " ", first != "\t",
                  let colon = line.firstIndex(of: ":") else { return .failure(.badRequest) }
            let name = String(line[line.startIndex..<colon])
            guard isToken(name) else { return .failure(.badRequest) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard value.unicodeScalars.allSatisfy({ $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F) }) else {
                return .failure(.badRequest)
            }
            let key = name.lowercased()
            guard headers[key] == nil else { return .failure(.badRequest) }
            headers[key] = value
        }

        guard headers["transfer-encoding"] == nil else { return .failure(.notImplemented) }
        var length = 0
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.utf8.count <= 7, raw.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let parsed = Int(raw) else { return .failure(.badRequest) }
            guard parsed <= maxBodyBytes else { return .failure(.payloadTooLarge) }
            length = parsed
        } else if method == "POST" {
            return .failure(.lengthRequired)
        }
        if length > 0, method != "POST" { return .failure(.badRequest) }

        let bodyStart = end.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .needMore }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        return .request(HTTPRequest(method: method, target: target, headers: headers, body: body))
    }

    private static func isToken(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let allowed = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        return value.utf8.allSatisfy { allowed.contains($0) }
    }
}
