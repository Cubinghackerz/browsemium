import BrowsemiumCore
@testable import BrowsemiumData
import Foundation
import GRDB
import Testing

private struct Key: BrowserCredentialKeyProviding {
    let key: Data?
    func safeStorageKey(for source: BrowserImportSource) throws -> Data? { key }
}

private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("browsemium-cookie-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func importer() throws -> BrowserDataImporter {
    let database = try AppDatabase.inMemory()
    return BrowserDataImporter(bookmarks: BookmarkRepository(database: database), history: HistoryRepository(database: database))
}

private func chromeMicros(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000) }

@Suite
struct ImportedCookieTests {
    private func chromeProfile(withSameSite: Bool) throws -> URL {
        let url = try folder()
        try Data("{}".utf8).write(to: url.appendingPathComponent("Bookmarks"))
        let queue = try DatabaseQueue(path: url.appendingPathComponent("Cookies").path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT,
                    expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER\(withSameSite ? ", samesite INTEGER" : ""))
                """)
            let future = chromeMicros(Date().addingTimeInterval(3600))
            for (name, samesite) in [("unspec", -1), ("none", 0), ("lax", 1), ("strict", 2)] {
                if withSameSite {
                    try db.execute(sql: "INSERT INTO cookies VALUES ('.a.example', ?, 'v', x'', '/', ?, 1, 0, ?)", arguments: [name, future, samesite])
                } else {
                    try db.execute(sql: "INSERT INTO cookies VALUES ('.a.example', ?, 'v', x'', '/', ?, 1, 0)", arguments: [name, future])
                }
            }
        }
        return url
    }

    private func cookies(in profile: URL, source: BrowserImportSource) throws -> [BrowserImportCookie] {
        let importer = try importer()
        let preview = try importer.preview(at: profile, source: source)
        var options = BrowserImportOptions()
        options.includesCookies = true
        let key = try ChromeCredentialCrypto.derivedKey(safeStoragePassword: "fixture-only")
        return try importer.apply(preview, options: options, keyProvider: Key(key: key), profile: profile).cookies
    }

    @Test
    func chromiumSameSiteIsCarriedAcross() throws {
        let profile = try chromeProfile(withSameSite: true)
        defer { try? FileManager.default.removeItem(at: profile) }
        let byName = Dictionary(uniqueKeysWithValues: try cookies(in: profile, source: .chrome).map { ($0.name, $0.sameSite) })
        #expect(byName["lax"] == .lax)
        #expect(byName["strict"] == .strict)
        #expect(byName["none"] == SameSite.none)
        #expect(byName["unspec"] == .some(nil), "Unspecified stays unspecified")
    }

    @Test
    func olderChromiumDatabasesWithoutTheColumnStillImport() throws {
        let profile = try chromeProfile(withSameSite: false)
        defer { try? FileManager.default.removeItem(at: profile) }
        let imported = try cookies(in: profile, source: .chrome)
        #expect(imported.count == 4)
        #expect(imported.allSatisfy { $0.sameSite == nil })
    }

    @Test
    func firefoxSameSiteIsCarriedAcross() throws {
        let url = try folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let places = try DatabaseQueue(path: url.appendingPathComponent("places.sqlite").path)
        try places.write { db in
            try db.execute(sql: "CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, last_visit_date INTEGER)")
            try db.execute(sql: "CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, title TEXT, dateAdded INTEGER)")
        }
        let queue = try DatabaseQueue(path: url.appendingPathComponent("cookies.sqlite").path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, name TEXT, value TEXT, host TEXT, path TEXT, expiry INTEGER,
                    isSecure INTEGER, isHttpOnly INTEGER, sameSite INTEGER, originAttributes TEXT NOT NULL DEFAULT '')
                """)
            let future = Int64(Date().addingTimeInterval(3600).timeIntervalSince1970)
            for (name, value) in [("none", 0), ("lax", 1), ("strict", 2)] {
                try db.execute(sql: "INSERT INTO moz_cookies (name, value, host, path, expiry, isSecure, isHttpOnly, sameSite) VALUES (?, 'v', '.a.example', '/', ?, 1, 0, ?)",
                               arguments: [name, future, value])
            }
        }
        let byName = Dictionary(uniqueKeysWithValues: try cookies(in: url, source: .firefox).map { ($0.name, $0.sameSite) })
        #expect(byName["lax"] == .lax)
        #expect(byName["strict"] == .strict)
        #expect(byName["none"] == SameSite.none)
    }

    // MARK: HTTPCookie conversion

    private func make(domain: String = ".a.example", sameSite: SameSite? = nil) throws -> BrowserImportCookie {
        try #require(BrowserImportCookie(
            domain: domain, name: "n", value: "v", path: "/p",
            expires: Date().addingTimeInterval(3600), isSecure: true, isHTTPOnly: true, sameSite: sameSite
        ))
    }

    @Test
    func theNativeCookieKeepsEveryAttribute() throws {
        let cookie = try #require(try make(sameSite: .lax).httpCookie)
        #expect(cookie.domain == ".a.example")
        #expect(cookie.path == "/p")
        #expect(cookie.isSecure && cookie.isHTTPOnly)
        #expect(cookie.sameSitePolicy == HTTPCookieStringPolicy.sameSiteLax)
        #expect(cookie.expiresDate != nil)
    }

    @Test
    func aHostOnlyCookieStaysHostOnly() throws {
        let cookie = try #require(try make(domain: "a.example").httpCookie)
        #expect(cookie.domain == "a.example", "No leading dot means host-only")
    }

    @Test
    func strictAndUnspecifiedMapToTheNativePolicy() throws {
        #expect(try make(sameSite: .strict).httpCookie?.sameSitePolicy == HTTPCookieStringPolicy.sameSiteStrict)
        #expect(try make(sameSite: nil).httpCookie?.sameSitePolicy == nil)
        #expect(try make(sameSite: SameSite.none).httpCookie?.sameSitePolicy == nil, "Foundation has no explicit None")
    }
}
