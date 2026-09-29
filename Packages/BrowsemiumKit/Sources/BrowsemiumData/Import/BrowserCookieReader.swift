import Foundation

/// A cookie is an account capability. Values never enter previews or logs.
public struct BrowserImportCookie: Sendable, Hashable {
    public let domain: String
    public let name: String
    public let value: String
    public let path: String
    public let expires: Date?
    public let isSecure: Bool
    public let isHTTPOnly: Bool

    public init?(domain: String, name: String, value: String, path: String, expires: Date?, isSecure: Bool, isHTTPOnly: Bool) {
        let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        guard !host.isEmpty, host.count <= 253,
              host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }),
              !host.hasPrefix("."), !host.hasSuffix("."), !host.contains(".."),
              !name.isEmpty, name.utf8.count <= 256,
              !name.contains("\n"), !name.contains("\r"),
              value.utf8.count <= 4096, !value.contains("\n"), !value.contains("\r"),
              path.hasPrefix("/"), path.utf8.count <= 1024,
              expires.map({ $0 > Date() }) ?? true else { return nil }
        self.domain = domain
        self.name = name
        self.value = value
        self.path = path
        self.expires = expires
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
    }
}

/// Bounds-checked reader for Safari's `Cookies.binarycookies` page format.
/// The format is undocumented; malformed and unknown records are skipped.
public enum SafariBinaryCookieReader {
    public static func parse(_ data: Data) -> [BrowserImportCookie] {
        guard data.count >= 12, data.count <= 64 * 1024 * 1024,
              data.prefix(4) == Data("cook".utf8),
              let pageCount = be32(data, 4), pageCount <= 4096,
              8 + Int(pageCount) * 4 <= data.count else { return [] }
        var pageStart = 8 + Int(pageCount) * 4
        var output: [BrowserImportCookie] = []
        for pageIndex in 0..<Int(pageCount) {
            guard let pageSize = be32(data, 8 + pageIndex * 4),
                  pageSize >= 12, pageSize <= 16 * 1024 * 1024,
                  pageStart <= data.count - Int(pageSize) else { return output }
            let pageEnd = pageStart + Int(pageSize)
            guard let count = le32(data, pageStart + 4), count <= 50_000,
                  pageStart + 8 + Int(count) * 4 <= pageEnd else {
                pageStart = pageEnd
                continue
            }
            for index in 0..<Int(count) {
                guard let offset = le32(data, pageStart + 8 + index * 4),
                      Int(offset) <= Int(pageSize) - 56 else { continue }
                let start = pageStart + Int(offset)
                guard let size = le32(data, start), size >= 56,
                      start <= pageEnd - Int(size),
                      let flags = le32(data, start + 8),
                      let domainOffset = le32(data, start + 16),
                      let nameOffset = le32(data, start + 20),
                      let pathOffset = le32(data, start + 24),
                      let valueOffset = le32(data, start + 28),
                      let expiryBits = le64(data, start + 40),
                      let domain = cString(data, start: start, size: Int(size), offset: domainOffset),
                      let name = cString(data, start: start, size: Int(size), offset: nameOffset),
                      let path = cString(data, start: start, size: Int(size), offset: pathOffset),
                      let value = cString(data, start: start, size: Int(size), offset: valueOffset) else { continue }
                let seconds = Double(bitPattern: expiryBits)
                let expires = seconds.isFinite && seconds > 0
                    ? Date(timeIntervalSinceReferenceDate: seconds) : nil
                if let cookie = BrowserImportCookie(
                    domain: domain, name: name, value: value, path: path,
                    expires: expires, isSecure: flags & 1 != 0,
                    isHTTPOnly: flags & 4 != 0
                ) {
                    output.append(cookie)
                }
            }
            pageStart = pageEnd
        }
        return output
    }

    private static func be32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }

    private static func le32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private static func le64(_ data: Data, _ offset: Int) -> UInt64? {
        guard offset >= 0, offset <= data.count - 8 else { return nil }
        var result: UInt64 = 0
        for index in 0..<8 { result |= UInt64(data[offset + index]) << (index * 8) }
        return result
    }

    private static func cString(_ data: Data, start: Int, size: Int, offset: UInt32) -> String? {
        guard offset >= 56, Int(offset) < size else { return nil }
        let begin = start + Int(offset)
        let limit = min(start + size, begin + 4097)
        guard let end = (begin..<limit).first(where: { data[$0] == 0 }) else { return nil }
        return String(data: data[begin..<end], encoding: .utf8)
    }
}
