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
        try Row.fetchAll(
            database,
            sql: """
                SELECT origin_url, username_value
                FROM logins
                WHERE length(password_value) > 0 AND username_value <> ''
                ORDER BY origin_url
                """
        ).compactMap { row in
            guard let rawURL = row["origin_url"] as String?,
                  let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else {
                return nil
            }
            return (url, row["username_value"] as String? ?? "")
        }
    }

    public static func decryptLogins(database: Database, key: Data) throws -> [ChromeLogin] {
        var logins: [ChromeLogin] = []
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT origin_url, username_value, password_value
                FROM logins
                WHERE length(password_value) > 0 AND username_value <> ''
                ORDER BY origin_url
                """
        )
        for row in rows {
            guard let rawURL = row["origin_url"] as String?,
                  let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  let blob = row["password_value"] as Data? else {
                continue
            }
            // One unreadable entry must not abort the whole import.
            guard let password = try? ChromeCredentialCrypto.decrypt(blob, key: key),
                  !password.isEmpty else {
                continue
            }
            logins.append(
                ChromeLogin(
                    url: url,
                    username: row["username_value"] as String? ?? "",
                    password: password
                )
            )
        }
        return logins
    }
}
