import Foundation
import GRDB

/// Reads saved logins out of Chrome's `Login Data` database.
///
/// Passwords are only decrypted when a key is supplied, and the key is only
/// obtainable with the user's permission to read Chrome's keychain item. A
/// preview can therefore count logins without touching any secret.
public struct ChromeLogin: Sendable, Hashable {
    public let url: URL
    public let username: String
    public let password: String

    public init(url: URL, username: String, password: String) {
        self.url = url
        self.username = username
        self.password = password
    }
}

public enum ChromeLoginDataReader {
    /// Sites with a saved password, without decrypting anything.
    public static func summarize(database: Database) throws -> [(url: URL, username: String)] {
        var report = BrowserImportReport()
        return try summarize(database: database, report: &report)
    }

    static func summarize(database: Database, report: inout BrowserImportReport) throws -> [(url: URL, username: String)] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT origin_url, username_value
                FROM logins
                WHERE length(password_value) > 0 AND username_value <> ''
                ORDER BY origin_url
                LIMIT 50000
                """
        ).enumerated().compactMap { index, row in
            guard let rawURL = row["origin_url"] as String?,
                  let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http", url.host?.isEmpty == false else {
                report.record(.password, ordinal: index + 1, outcome: .unsupported, reason: .unsupportedURL)
                return nil
            }
            report.record(.password, ordinal: index + 1, outcome: .accepted, reason: .parsed)
            return (url, row["username_value"] as String? ?? "")
        }
    }

    public static func decryptLogins(database: Database, key: Data) throws -> [ChromeLogin] {
        var report = BrowserImportReport()
        return try decryptLogins(database: database, key: key, report: &report)
    }

    static func decryptLogins(database: Database, key: Data, report: inout BrowserImportReport) throws -> [ChromeLogin] {
        var logins: [ChromeLogin] = []
        var seen = Set<String>()
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT origin_url, username_value, password_value
                FROM logins
                WHERE length(password_value) > 0 AND username_value <> ''
                ORDER BY origin_url
                LIMIT 50000
                """
        )
        for (index, row) in rows.enumerated() {
            guard let rawURL = row["origin_url"] as String?,
                  let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http", url.host?.isEmpty == false,
                  let blob = row["password_value"] as Data? else {
                report.record(.password, ordinal: index + 1, stage: .transfer,
                              outcome: .unsupported, reason: .invalidItem)
                continue
            }
            // One unreadable entry must not abort the whole import.
            guard let password = try? ChromeCredentialCrypto.decrypt(blob, key: key),
                  !password.isEmpty else {
                report.record(.password, ordinal: index + 1, stage: .transfer,
                              outcome: .failed, reason: .decryptionFailed)
                continue
            }
            let username = row["username_value"] as String? ?? ""
            guard seen.insert("\(url.absoluteString)\u{0}\(username)").inserted else {
                report.record(.password, ordinal: index + 1, stage: .transfer,
                              outcome: .duplicate, reason: .duplicateInSource)
                continue
            }
            report.record(.password, ordinal: index + 1, stage: .transfer,
                          outcome: .accepted, reason: .preparedForTransfer)
            logins.append(
                ChromeLogin(
                    url: url,
                    username: username,
                    password: password
                )
            )
        }
        return logins
    }
}
