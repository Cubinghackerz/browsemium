import BrowsemiumCore
@testable import BrowsemiumData
import Foundation
import GRDB
import Testing

private struct KeyProvider: BrowserCredentialKeyProviding {
    let key: Data?
    func safeStorageKey(for source: BrowserImportSource) throws -> Data? { key }
}

private func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-skip-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A folder the importer accepts as a Chromium profile.
private func makeChromeFolder() throws -> URL {
    let folder = try makeFolder()
    try Data("{}".utf8).write(to: folder.appendingPathComponent("Bookmarks"))
    return folder
}

private func addFirefoxPlaces(to folder: URL) throws {
    let queue = try DatabaseQueue(path: folder.appendingPathComponent("places.sqlite").path)
    try queue.write { db in
        try db.execute(sql: "CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, last_visit_date INTEGER)")
        try db.execute(sql: "CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, title TEXT, dateAdded INTEGER)")
    }
}

private func makeImporter() throws -> BrowserDataImporter {
    let database = try AppDatabase.inMemory()
    return BrowserDataImporter(bookmarks: BookmarkRepository(database: database), history: HistoryRepository(database: database))
}

private func chromeMicros(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
}

private func reasons(_ report: BrowserImportReport, _ category: BrowserImportReport.Category) -> [BrowserImportReport.Reason] {
    report.items.filter { $0.category == category }.map(\.reason)
}

@Suite
struct ImportSkipReportingTests {
    @Test
    func loginsWithoutAUsernameAreReportedNotSilentlyDropped() throws {
        let folder = try makeChromeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try ChromeCredentialCrypto.derivedKey(safeStoragePassword: "fixture-only")
        let blob = try ChromeCredentialCrypto.encryptForTesting("fixture-password", key: key)
        let queue = try DatabaseQueue(path: folder.appendingPathComponent("Login Data").path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE logins (origin_url TEXT, username_value TEXT, password_value BLOB)")
            for (url, user) in [("https://a.example", "person"), ("https://b.example", ""), ("https://c.example", "")] {
                try db.execute(sql: "INSERT INTO logins VALUES (?, ?, ?)", arguments: [url, user, blob])
            }
        }
        let importer = try makeImporter()
        let preview = try importer.preview(at: folder, source: .chrome)

        #expect(preview.credentialCount == 1)
        #expect(reasons(preview.report, .password).filter { $0 == .missingUsername }.count == 2)

        let result = try importer.apply(preview, options: BrowserImportOptions(includesPasswords: true),
                                        keyProvider: KeyProvider(key: key), profile: folder)
        #expect(result.credentials.count == 1)
        #expect(reasons(result.report, .password).filter { $0 == .missingUsername }.count >= 2)
        let encoded = String(decoding: try JSONEncoder().encode(result.report), as: UTF8.self)
        #expect(!encoded.contains("example"), "Reports never carry hosts")
    }

    @Test
    func expiredChromiumCookiesAreSkippedAndCounted() throws {
        let folder = try makeChromeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try ChromeCredentialCrypto.derivedKey(safeStoragePassword: "fixture-only")
        let queue = try DatabaseQueue(path: folder.appendingPathComponent("Cookies").path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB,
                    path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER)
                """)
            let live = chromeMicros(Date().addingTimeInterval(3600)), dead = chromeMicros(Date().addingTimeInterval(-3600))
            try db.execute(sql: "INSERT INTO cookies VALUES ('.a.example','live','x',x'','/',?,0,0)", arguments: [live])
            try db.execute(sql: "INSERT INTO cookies VALUES ('.a.example','dead','y',x'','/',?,0,0)", arguments: [dead])
            try db.execute(sql: "INSERT INTO cookies VALUES ('.a.example','session','z',x'','/',0,0,0)")
        }
        let importer = try makeImporter()
        let preview = try importer.preview(at: folder, source: .chrome)
        var options = BrowserImportOptions()
        options.includesCookies = true
        let result = try importer.apply(preview, options: options, keyProvider: KeyProvider(key: key), profile: folder)

        #expect(result.cookies.map(\.name).sorted() == ["live", "session"])
        #expect(reasons(result.report, .cookie).contains(.expired))
    }

    private func firefoxCookies(_ rows: [(name: String, origin: String, expiry: Int64)], withOriginAttributes: Bool = true) throws -> URL {
        let folder = try makeFolder()
        try addFirefoxPlaces(to: folder)
        let queue = try DatabaseQueue(path: folder.appendingPathComponent("cookies.sqlite").path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, name TEXT, value TEXT, host TEXT, path TEXT,
                    expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER\(withOriginAttributes ? ", originAttributes TEXT NOT NULL DEFAULT ''" : ""))
                """)
            for row in rows {
                if withOriginAttributes {
                    try db.execute(sql: "INSERT INTO moz_cookies (name, value, host, path, expiry, isSecure, isHttpOnly, originAttributes) VALUES (?, 'v', '.a.example', '/', ?, 0, 0, ?)",
                                   arguments: [row.name, row.expiry, row.origin])
                } else {
                    try db.execute(sql: "INSERT INTO moz_cookies (name, value, host, path, expiry, isSecure, isHttpOnly) VALUES (?, 'v', '.a.example', '/', ?, 0, 0)",
                                   arguments: [row.name, row.expiry])
                }
            }
        }
        return folder
    }

    @Test
    func firefoxContainerCookiesDoNotLandInTheDefaultJar() throws {
        let future = Int64(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let folder = try firefoxCookies([
            ("default", "", future),
            ("work-container", "^userContextId=2", future),
            ("partitioned", "^partitionKey=%28https%2Cexample.com%29", future)
        ])
        defer { try? FileManager.default.removeItem(at: folder) }
        let importer = try makeImporter()
        let preview = try importer.preview(at: folder, source: .firefox)
        var options = BrowserImportOptions()
        options.includesCookies = true
        let result = try importer.apply(preview, options: options, keyProvider: KeyProvider(key: nil), profile: folder)

        #expect(result.cookies.map(\.name) == ["default"])
        #expect(reasons(result.report, .cookie).filter { $0 == .containerScoped }.count == 2)
    }

    @Test
    func olderFirefoxProfilesWithoutOriginAttributesStillImport() throws {
        let future = Int64(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let folder = try firefoxCookies([("old", "", future)], withOriginAttributes: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let importer = try makeImporter()
        let preview = try importer.preview(at: folder, source: .firefox)
        var options = BrowserImportOptions()
        options.includesCookies = true
        let result = try importer.apply(preview, options: options, keyProvider: KeyProvider(key: nil), profile: folder)
        #expect(result.cookies.map(\.name) == ["old"])
    }

    @Test
    func expiredFirefoxCookiesAreSkippedAndCounted() throws {
        let folder = try firefoxCookies([
            ("live", "", Int64(Date().addingTimeInterval(3600).timeIntervalSince1970)),
            ("dead", "", Int64(Date().addingTimeInterval(-3600).timeIntervalSince1970))
        ])
        defer { try? FileManager.default.removeItem(at: folder) }
        let importer = try makeImporter()
        let preview = try importer.preview(at: folder, source: .firefox)
        var options = BrowserImportOptions()
        options.includesCookies = true
        let result = try importer.apply(preview, options: options, keyProvider: KeyProvider(key: nil), profile: folder)
        #expect(result.cookies.map(\.name) == ["live"])
        #expect(reasons(result.report, .cookie).contains(.expired))
    }

    // MARK: Search engine

    private func chromeSearch(_ templateData: [String: Any]) throws -> URL {
        let folder = try makeChromeFolder()
        let preferences: [String: Any] = ["default_search_provider_data": ["template_url_data": templateData]]
        try JSONSerialization.data(withJSONObject: preferences).write(to: folder.appendingPathComponent("Preferences"))
        return folder
    }

    @Test
    func chromePreferencesKeepThePlainURLUnderTheUrlKey() throws {
        let folder = try chromeSearch(["short_name": "Example", "url": "https://search.example/?q={searchTerms}"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let preview = try makeImporter().preview(at: folder, source: .chrome)
        #expect(preview.searchEngine?.template == "https://search.example/?q=")
    }

    @Test
    func aSearchURLWithTheQueryInTheMiddleIsReportedAsUnsupported() throws {
        let folder = try chromeSearch(["short_name": "Example", "url": "https://search.example/?q={searchTerms}&t=chromium"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let preview = try makeImporter().preview(at: folder, source: .chrome)
        #expect(preview.searchEngine == nil)
        #expect(preview.report.items.contains { $0.category == .searchEngine && $0.outcome == .unsupported && $0.reason == .unsupportedFormat })
    }

    @Test
    func aChromeProfileWithNoStoredEngineReportsNothingToImport() throws {
        let folder = try makeChromeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("Preferences"))
        let preview = try makeImporter().preview(at: folder, source: .chrome)
        #expect(preview.searchEngine == nil)
        #expect(!preview.report.items.contains { $0.category == .searchEngine })
    }

    @Test
    func theNotImportableListNamesFirefoxAndSafariSearch() {
        #expect(BrowserDataImporter.notImportable(for: .firefox).contains { $0.contains("search") })
        #expect(BrowserDataImporter.notImportable(for: .safari).contains { $0.contains("search") })
    }
}

@Suite
struct RunningSourceBrowserTests {
    @Test
    func everySourceHasADistinctBundleIdentifier() {
        let identifiers = BrowserImportSource.allCases.map(\.bundleIdentifier)
        #expect(identifiers.allSatisfy { !$0.isEmpty })
        #expect(Set(identifiers).count == identifiers.count)
        #expect(BrowserImportSource.chrome.bundleIdentifier == "com.google.Chrome")
        #expect(BrowserImportSource.firefox.bundleIdentifier == "org.mozilla.firefox")
        #expect(BrowserImportSource.safari.bundleIdentifier == "com.apple.Safari")
    }

    @Test
    func theWarningNamesTheBrowserAndSaysWhatToDo() {
        let text = BrowserImportSource.chrome.runningWarning
        #expect(text.contains("Chrome"))
        #expect(text.contains("Quit"))
    }
}
