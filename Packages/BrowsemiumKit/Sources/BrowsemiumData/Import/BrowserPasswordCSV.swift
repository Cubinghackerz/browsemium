import Foundation

/// Password-manager CSV is plaintext. Keep this value in memory only and
/// discard it when the import sheet closes.
public struct BrowserPasswordCSV: Sendable {
    public struct ColumnMap: Sendable, Equatable {
        public var site: Int
        public var username: Int
        public var password: Int

        public init(site: Int, username: Int, password: Int) {
            self.site = site
            self.username = username
            self.password = password
        }
    }

    public enum CSVError: Error, LocalizedError {
        case tooLarge
        case invalidEncoding
        case malformed
        case noHeader
        case invalidMapping

        public var errorDescription: String? {
            switch self {
            case .tooLarge: "The CSV is too large to import (16 MB maximum)."
            case .invalidEncoding: "The CSV must use UTF-8 text."
            case .malformed: "The CSV has an unmatched quote or too many rows."
            case .noHeader: "The CSV needs a header row with column names."
            case .invalidMapping: "Choose different site, username, and password columns."
            }
        }
    }

    public let headers: [String]
    private let rows: [[String]]
    public let suggestedMap: ColumnMap?
    public var rowCount: Int { rows.count }

    public init(data: Data) throws {
        guard data.count <= 16 * 1024 * 1024 else { throw CSVError.tooLarge }
        guard var text = String(data: data, encoding: .utf8) else { throw CSVError.invalidEncoding }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let parsed = try Self.parse(text)
        guard let first = parsed.first, first.count >= 3 else { throw CSVError.noHeader }
        headers = first
        rows = Array(parsed.dropFirst()).filter { $0.contains(where: { !$0.isEmpty }) }
        suggestedMap = Self.suggest(headers)
    }

    public func credentials(using map: ColumnMap) throws -> [ChromeLogin] {
        guard map.site != map.username, map.site != map.password, map.username != map.password,
              [map.site, map.username, map.password].allSatisfy({ headers.indices.contains($0) }) else {
            throw CSVError.invalidMapping
        }
        return rows.compactMap { row in
            guard row.count > max(map.site, map.username, map.password),
                  let url = Self.webURL(row[map.site]),
                  !row[map.username].isEmpty, !row[map.password].isEmpty else { return nil }
            return ChromeLogin(url: url, username: row[map.username], password: row[map.password])
        }
    }

    public static func export(_ credentials: [ChromeLogin]) -> Data {
        let lines = [["url", "username", "password"]] + credentials.map {
            [$0.url.absoluteString, $0.username, $0.password]
        }
        let text = lines.map { row in row.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        return Data(text.utf8)
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func webURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    private static func suggest(_ headers: [String]) -> ColumnMap? {
        let normalized = headers.map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        func find(_ names: [String]) -> Int? { normalized.firstIndex { names.contains($0) } }
        // Covers Apple Passwords, 1Password, Bitwarden, LastPass and Dashlane.
        guard let site = find(["url", "website", "websiteurl", "loginuri", "uri", "loginurl", "site"]),
              let username = find(["username", "loginusername", "login", "email", "userid"]),
              let password = find(["password", "loginpassword", "pass"]) else { return nil }
        return ColumnMap(site: site, username: username, password: password)
    }

    private static func parse(_ text: String) throws -> [[String]] {
        var output: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var afterQuote = false
        var atFieldStart = true
        // Swift Character treats CRLF as one grapheme. Scalars keep the two
        // line-ending bytes separate so both quoted and ordinary rows parse.
        let chars = Array(text.unicodeScalars)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if quoted {
                if char == "\"" {
                    if index + 1 < chars.count, chars[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        quoted = false
                        afterQuote = true
                    }
                } else {
                    field.unicodeScalars.append(char)
                }
            } else if char == "\"" {
                guard atFieldStart else { throw CSVError.malformed }
                quoted = true
                atFieldStart = false
            } else if char == "," {
                row.append(field)
                field = ""
                atFieldStart = true
                afterQuote = false
            } else if char == "\n" || char == "\r" {
                row.append(field)
                output.append(row)
                guard output.count <= 50_001 else { throw CSVError.malformed }
                row = []
                field = ""
                atFieldStart = true
                afterQuote = false
                if char == "\r", index + 1 < chars.count, chars[index + 1] == "\n" { index += 1 }
            } else {
                guard !afterQuote else { throw CSVError.malformed }
                field.unicodeScalars.append(char)
                atFieldStart = false
            }
            index += 1
        }
        guard !quoted else { throw CSVError.malformed }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            output.append(row)
        }
        return output
    }
}
