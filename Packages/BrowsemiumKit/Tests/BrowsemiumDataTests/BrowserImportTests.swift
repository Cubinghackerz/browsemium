import BrowsemiumCore
@testable import BrowsemiumData
import Foundation
import GRDB
import Testing

@Test func browserImportHintsUseAccountHomeInsteadOfSandboxProcessHome() throws {
    let account = URL(fileURLWithPath: "/tmp/browsemium-home-fixture/account", isDirectory: true)
    let container = account.appendingPathComponent("Library/Containers/com.browsemium.browser/Data", isDirectory: true)
    let home = BrowserImportHomeDirectory.resolve(accountHome: account, processHome: container)
    #expect(home == account)
    for source in BrowserImportSource.allCases {
        let root = try #require(source.profileRoot(relativeTo: home))
        #expect(root.path.hasPrefix(account.path + "/Library/"))
        #expect(!root.path.contains("/Containers/"))
        let selected = root.appendingPathComponent("Default", isDirectory: true)
        #expect(BrowserImportSourceDetector.detect(in: selected, homeDirectory: home) == source)
    }
    // If account metadata is unavailable, retain the process path rather
    // than guessing another user's directory.
    let fallback = URL(fileURLWithPath: "/tmp/browsemium-home-fixture/container", isDirectory: true)
    #expect(BrowserImportHomeDirectory.resolve(accountHome: nil, processHome: fallback) == fallback)
}

/// Builds a throwaway Chrome profile on disk so the importer is exercised
/// against real files rather than mocks.
private struct FakeChromeProfile {
    let folder: URL

    init(bookmarks: [[String: Any]], visits: [(url: String, title: String, chromeMicros: Int64)]) throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("browsemium-test-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let payload: [String: Any] = [
            "roots": [
                "bookmark_bar": [
                    "children": bookmarks,
                    "name": "Bookmarks bar",
                    "type": "folder"
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: folder.appendingPathComponent("Bookmarks"))

        // Written through a live connection so the file has a WAL, matching a
        // browser that is currently running.
        let queue = try DatabaseQueue(path: folder.appendingPathComponent("History").path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE urls (
                    id INTEGER PRIMARY KEY,
                    url TEXT NOT NULL,
                    title TEXT,
                    last_visit_time INTEGER NOT NULL
                )
                """)
            for visit in visits {
                try db.execute(
                    sql: "INSERT INTO urls (url, title, last_visit_time) VALUES (?, ?, ?)",
                    arguments: [visit.url, visit.title, visit.chromeMicros]
                )
            }
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }
}

private func makeImporter() throws -> (BrowserDataImporter, BookmarkRepository, HistoryRepository, AppDatabase) {
    let database = try AppDatabase.inMemory()
    let bookmarks = BookmarkRepository(database: database)
    let history = HistoryRepository(database: database)
    return (
        BrowserDataImporter(bookmarks: bookmarks, history: history),
        bookmarks,
        history,
        database
    )
}

@Test
func importPreviewRejectsAnEscapingBookmarkSymlink() throws {
    let selected = try FakeChromeProfile(bookmarks: [], visits: [])
    let outside = try FakeChromeProfile(bookmarks: [["type": "url", "name": "Outside", "url": "https://outside.example"]], visits: [])
    defer { selected.cleanUp(); outside.cleanUp() }
    let bookmarks = selected.folder.appendingPathComponent("Bookmarks")
    try FileManager.default.removeItem(at: bookmarks)
    try FileManager.default.createSymbolicLink(at: bookmarks, withDestinationURL: outside.folder.appendingPathComponent("Bookmarks"))
    let (importer, _, _, _) = try makeImporter()
    #expect(throws: BrowserDataImporter.ImportError.self) {
        try importer.preview(at: selected.folder, source: .chrome)
    }
}

@Test
func browserRootDiscoveryExcludesEscapingProfileSymlinks() throws {
    let selected = try FakeChromeProfile(bookmarks: [], visits: [])
    let outside = try FakeChromeProfile(bookmarks: [], visits: [])
    defer { selected.cleanUp(); outside.cleanUp() }
    try FileManager.default.createSymbolicLink(at: selected.folder.appendingPathComponent("Default"), withDestinationURL: outside.folder)
    #expect(BrowserProfileLocator.profiles(insideBrowserRoot: selected.folder, source: .chrome).isEmpty)
}

@Test func missingOptionalArtifactsUnderEnumeratedProfilesAreSafe() throws {
    let profile = try FakeChromeProfile(bookmarks: [], visits: [])
    defer { profile.cleanUp() }
    let nested = profile.folder.appendingPathComponent("Default", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
    let entries = try FileManager.default.contentsOfDirectory(at: profile.folder, includingPropertiesForKeys: [.isDirectoryKey])
    let enumerated = try #require(entries.first { $0.lastPathComponent == "Default" })
    #expect(BrowserImportPathPolicy.permitsArtifact(enumerated.appendingPathComponent("Preferences"), within: enumerated))
    #expect(BrowserImportPathPolicy.permitsArtifact(enumerated.appendingPathComponent("Network/Cookies"), within: enumerated))
}

@Test func keychainDenialMessageDoesNotClaimAnImportSucceeded() {
    let message = BrowserDataImporter.ImportError.credentialsLocked("Fixture Browser").localizedDescription
    #expect(message.contains("Nothing was imported"))
    #expect(!message.contains("Everything else was imported"))
}

@Test
func importApplyRejectsAnEscapingHistoryWALSymlinkBeforeWriting() throws {
    let selected = try FakeChromeProfile(bookmarks: [["type": "url", "name": "Fixture", "url": "https://fixture.example"]], visits: [])
    let outside = try FakeChromeProfile(bookmarks: [], visits: [])
    defer { selected.cleanUp(); outside.cleanUp() }
    let (importer, bookmarks, _, _) = try makeImporter()
    let preview = try importer.preview(at: selected.folder, source: .chrome)
    let sidecar = selected.folder.appendingPathComponent("History-wal")
    if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
    try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: outside.folder.appendingPathComponent("Bookmarks"))
    #expect(throws: BrowserDataImporter.ImportError.self) {
        try importer.apply(preview, profile: selected.folder)
    }
    #expect(try bookmarks.all().isEmpty)
}

/// Chrome stores microseconds since 1601-01-01.
private func chromeMicros(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
}

@Test
func importingAChromeProfileReadsBookmarksAndHistory() throws {
    let now = Date()
    let profile = try FakeChromeProfile(
        bookmarks: [
            ["type": "url", "name": "Swift", "url": "https://swift.org"],
            ["type": "url", "name": "Swift", "url": "https://swift.org"],
            [
                "type": "folder",
                "name": "Work",
                "children": [["type": "url", "name": "Docs", "url": "https://example.com/docs"]]
            ]
        ],
        visits: [
            ("https://swift.org", "Swift", chromeMicros(now)),
            ("https://example.com", "Example", chromeMicros(now.addingTimeInterval(-3600)))
        ]
    )
    defer { profile.cleanUp() }

    let (importer, bookmarks, history, _) = try makeImporter()
    let preview = try importer.preview(at: profile.folder, source: .chrome)

    #expect(preview.bookmarkCount == 2, "The duplicate URL should be collapsed")
    #expect(preview.historyCount == 2)
    #expect(preview.folders.contains("Work"), "Nested folders should be recorded")
    #expect(preview.latestVisit != nil)

    let result = try importer.apply(preview)
    #expect(result.bookmarks == 2)
    #expect(result.historyVisits == 2)
    #expect(try bookmarks.all().count == 2)
    #expect(try history.count() == 2)
}

@Test
func importingTwiceDoesNotDuplicateAnything() throws {
    let profile = try FakeChromeProfile(
        bookmarks: [["type": "url", "name": "Swift", "url": "https://swift.org"]],
        visits: [("https://swift.org", "Swift", chromeMicros(Date()))]
    )
    defer { profile.cleanUp() }

    let (importer, bookmarks, history, _) = try makeImporter()
    let preview = try importer.preview(at: profile.folder, source: .chrome)

    let first = try importer.apply(preview)
    let second = try importer.apply(preview)

    #expect(first.bookmarks == 1)
    #expect(second.bookmarks == 0, "Re-importing must not duplicate bookmarks")
    #expect(second.historyVisits == 0, "Re-importing must not duplicate history")
    #expect(try bookmarks.all().count == 1)
    #expect(try history.count() == 1)
}

@Test
func importReportExplainsParsedDuplicatesUnsupportedItemsAndReimports() throws {
    let profile = try FakeChromeProfile(bookmarks: [
        ["type": "url", "name": "Secret title", "url": "https://example.com/?secret=private"],
        ["type": "url", "name": "Duplicate", "url": "https://example.com/?secret=private"],
        ["type": "url", "name": "Unsupported", "url": "javascript:privateSecret()"]
    ], visits: [("https://example.com", "Private history title", chromeMicros(Date()))])
    defer { profile.cleanUp() }
    let (importer, _, _, _) = try makeImporter()
    let preview = try importer.preview(at: profile.folder, source: .chrome)
    #expect(preview.report.count(.accepted, stage: .preview) == 2)
    #expect(preview.report.count(.duplicate, stage: .preview) == 1)
    #expect(preview.report.count(.unsupported, stage: .preview) == 1)
    let first = try importer.apply(preview)
    #expect(first.report.count(.accepted, stage: .persistence) == 2)
    let second = try importer.apply(preview)
    #expect(second.report.count(.accepted, stage: .persistence) == 0)
    #expect(second.report.count(.duplicate, stage: .persistence) == 2)
    let encoded = String(decoding: try JSONEncoder().encode(second.report), as: UTF8.self)
    #expect(!encoded.contains("private"))
    #expect(!encoded.contains("example.com"))
    #expect(!encoded.contains("Secret title"))
}

@Test
func importReportRecordsPartialWritesWithoutLeakingDatabaseErrors() throws {
    let profile = try FakeChromeProfile(bookmarks: [
        ["type": "url", "name": "Good", "url": "https://good.example"],
        ["type": "url", "name": "Bad", "url": "https://bad.example"]
    ], visits: [])
    defer { profile.cleanUp() }
    let (importer, bookmarks, _, database) = try makeImporter()
    try database.databaseQueue.write { db in
        try db.execute(sql: """
            CREATE TRIGGER reject_fixture BEFORE INSERT ON bookmarks
            WHEN NEW.url = 'https://bad.example'
            BEGIN SELECT RAISE(ABORT, 'private SQL error password=never-report'); END
            """)
    }
    let result = try importer.apply(importer.preview(at: profile.folder, source: .chrome))
    #expect(result.bookmarks == 1)
    #expect(try bookmarks.all().count == 1)
    #expect(result.report.count(.failed, stage: .persistence) == 1)
    #expect(result.report.items.contains { $0.reason == .destinationWriteFailed })
    let encoded = String(decoding: try JSONEncoder().encode(result.report), as: UTF8.self)
    #expect(!encoded.contains("never-report"))
    #expect(!encoded.contains("SQL"))
}

@Test
func importReportDistinguishesMalformedSourcesFromEmptySources() throws {
    let profile = try FakeChromeProfile(bookmarks: [], visits: [])
    defer { profile.cleanUp() }
    try Data("not-json-private-token".utf8).write(to: profile.folder.appendingPathComponent("Bookmarks"))
    let (importer, _, _, _) = try makeImporter()
    let preview = try importer.preview(at: profile.folder, source: .chrome)
    #expect(preview.report.items.contains {
        $0.category == .bookmark && $0.ordinal == 0 && $0.outcome == .failed && $0.reason == .sourceUnreadable
    })
    #expect(preview.report.count(.failed, stage: .preview) == 0, "An unreadable file cannot invent item counts")
}

@Test
func importReportKeepsCredentialTransferSeparateFromPersistence() throws {
    let profile = try FakeChromeProfile(bookmarks: [], visits: [])
    defer { profile.cleanUp() }
    let key = try ChromeCredentialCrypto.derivedKey(safeStoragePassword: "fixture-only")
    let encrypted = try ChromeCredentialCrypto.encryptForTesting("never-report-password", key: key)
    let queue = try DatabaseQueue(path: profile.folder.appendingPathComponent("Login Data").path)
    try queue.write { db in
        try db.execute(sql: "CREATE TABLE logins (origin_url TEXT, username_value TEXT, password_value BLOB)")
        for blob in [encrypted, Data("broken-encrypted-password".utf8)] {
            try db.execute(sql: "INSERT INTO logins VALUES (?, ?, ?)",
                           arguments: ["https://private.example/login?token=private", "never-report-username", blob])
        }
    }
    let (importer, _, _, _) = try makeImporter()
    let preview = try importer.preview(at: profile.folder, source: .chrome)
    let result = try importer.apply(preview, options: BrowserImportOptions(includesPasswords: true),
                                    keyProvider: StubKeyProvider(key: key), profile: profile.folder)
    #expect(result.credentials.count == 1)
    #expect(result.report.items.contains { $0.category == .password && $0.stage == .transfer && $0.reason == .decryptionFailed })
    #expect(result.report.count(.accepted, stage: .transfer) == 1)
    #expect(!result.report.items.contains { $0.category == .password && $0.stage == .persistence })
    let encoded = String(decoding: try JSONEncoder().encode(result.report), as: UTF8.self)
    #expect(!encoded.contains("never-report"))
    #expect(!encoded.contains("private.example"))
    var completed = result.report
    let didComplete = completed.completeTransfer(.password, outcomes: [.failed])
    #expect(didComplete)
    #expect(completed.count(.failed, stage: .persistence) == 1)
    let didCompleteAgain = completed.completeTransfer(.password, outcomes: [.accepted])
    #expect(!didCompleteAgain, "A transfer cannot be counted twice")
    var mismatched = result.report
    let didCompleteMismatch = mismatched.completeTransfer(.password, outcomes: [])
    #expect(!didCompleteMismatch)
    #expect(mismatched.count(.accepted, stage: .persistence) == 0)
}

@Test
func importReportNeverCountsRolledBackWritesAsAccepted() throws {
    let profile = try FakeChromeProfile(bookmarks: [
        ["type": "url", "name": "First", "url": "https://first.example"],
        ["type": "url", "name": "Rollback", "url": "https://rollback.example"]
    ], visits: [])
    defer { profile.cleanUp() }
    let (importer, bookmarks, _, database) = try makeImporter()
    try database.databaseQueue.write { db in
        try db.execute(sql: """
            CREATE TRIGGER rollback_fixture BEFORE INSERT ON bookmarks
            WHEN NEW.url = 'https://rollback.example'
            BEGIN SELECT RAISE(ROLLBACK, 'fixture rollback'); END
            """)
    }
    let result = try importer.apply(importer.preview(at: profile.folder, source: .chrome))
    #expect(result.bookmarks == 0)
    #expect(try bookmarks.all().isEmpty)
    #expect(result.report.count(.accepted, stage: .persistence) == 0)
    #expect(result.report.count(.failed, stage: .persistence) == 2)
}

@Test
func importReportUsesFirefoxAndSafariParsingInsteadOfInventedCounts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("browsemium-report-formats-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let queue = try DatabaseQueue(path: root.appendingPathComponent("places.sqlite").path)
    try queue.write { db in
        try db.execute(sql: "CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, last_visit_date INTEGER)")
        try db.execute(sql: "CREATE TABLE moz_bookmarks (fk INTEGER, title TEXT, type INTEGER, dateAdded INTEGER)")
        try db.execute(sql: "INSERT INTO moz_places VALUES (1, 'https://fixture.example', 'Title', 1000000), (2, 'javascript:secret()', 'Title', 1000000)")
        try db.execute(sql: "INSERT INTO moz_bookmarks VALUES (1, 'Title', 1, 1), (2, 'Title', 1, 1)")
    }
    let (importer, _, _, _) = try makeImporter()
    let firefox = try importer.preview(at: root, source: .firefox)
    #expect(firefox.report.count(.accepted, stage: .preview) == 2)
    #expect(firefox.report.count(.unsupported, stage: .preview) == 2)
    let safari: [String: Any] = ["Children": [
        ["URLString": "https://fixture.example", "WebBookmarkType": "WebBookmarkTypeLeaf"],
        ["URLString": "javascript:secret()", "WebBookmarkType": "WebBookmarkTypeLeaf"]
    ]]
    try PropertyListSerialization.data(fromPropertyList: safari, format: .binary, options: 0)
        .write(to: root.appendingPathComponent("Bookmarks.plist"))
    let safariPreview = try importer.preview(at: root, source: .safari)
    #expect(safariPreview.report.count(.accepted, stage: .preview) == 1)
    #expect(safariPreview.report.count(.unsupported, stage: .preview) == 1)
}

@Test
func previewIncludesUncheckpointedHistoryWALFromARunningBrowser() throws {
    let profile = try FakeChromeProfile(bookmarks: [], visits: [])
    defer { profile.cleanUp() }
    let historyURL = profile.folder.appendingPathComponent("History")
    var configuration = Configuration()
    configuration.journalMode = .wal
    let live = try DatabaseQueue(path: historyURL.path, configuration: configuration)
    try live.write { db in
        try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
        try db.execute(sql: "INSERT INTO urls (url, title, last_visit_time) VALUES (?, ?, ?)",
                       arguments: ["https://wal.example", "Uncheckpointed", chromeMicros(Date())])
    }
    #expect(FileManager.default.fileExists(atPath: historyURL.path + "-wal"))

    let (importer, _, _, _) = try makeImporter()
    let preview = try importer.preview(at: profile.folder, source: .chrome)
    #expect(preview.visits.contains { $0.url.host == "wal.example" })
    withExtendedLifetime(live) {}
}

@Test
func historyOptionsRespectScopeAndRange() throws {
    let now = Date()
    let profile = try FakeChromeProfile(
        bookmarks: [["type": "url", "name": "Swift", "url": "https://swift.org"]],
        visits: [
            ("https://recent.example", "Recent", chromeMicros(now.addingTimeInterval(-86_400))),
            ("https://old.example", "Old", chromeMicros(now.addingTimeInterval(-86_400 * 200)))
        ]
    )
    defer { profile.cleanUp() }

    let (importer, bookmarks, history, _) = try makeImporter()
    let preview = try importer.preview(at: profile.folder, source: .chrome)

    var options = BrowserImportOptions()
    options.includesBookmarks = false
    options.historySince = now.addingTimeInterval(-86_400 * 30)
    let result = try importer.apply(preview, options: options)

    #expect(result.bookmarks == 0, "Bookmarks were switched off")
    #expect(result.historyVisits == 1, "Only history inside the range should import")
    #expect(try bookmarks.all().isEmpty)
    #expect(try history.count() == 1)
}

@Test
func chromiumFamilyIncludesTheNewerBrowsersWithTheirOwnKeys() {
    #expect(BrowserImportSource.dia.family == .chromium)
    #expect(BrowserImportSource.helium.family == .chromium)
    #expect(BrowserImportSource.opera.family == .chromium)

    #expect(BrowserImportSource.dia.safeStorageService == "Dia Safe Storage")
    #expect(BrowserImportSource.helium.safeStorageService == "Helium Safe Storage")
    #expect(BrowserImportSource.opera.safeStorageService == "Opera Safe Storage")

    // Every Chromium-family browser that stores a profile can have its
    // passwords read, and every one names its own keychain item.
    for source in BrowserImportSource.allCases where source.family == .chromium {
        #expect(source.supportsPasswordImport)
        #expect(source.profileRoot != nil)
    }

    // Helium's macOS profile lives under its bundle identifier.
    #expect(BrowserImportSource.helium.profileRoot?.lastPathComponent == "net.imput.helium")
    #expect(BrowserImportSource.dia.profileRoot?.lastPathComponent == "User Data")
}

@Test
func installedBrowserDiscoveryOnlyReturnsSupportedInstalledApps() {
    let allIdentifiers = BrowserImportSource.allCases.map(\.applicationBundleIdentifier)
    let installed = Set([
        BrowserImportSource.chrome.applicationBundleIdentifier,
        BrowserImportSource.dia.applicationBundleIdentifier,
        BrowserImportSource.firefox.applicationBundleIdentifier,
        "com.example.UnrelatedApp"
    ])

    #expect(BrowserApplicationDiscovery.installedSources(in: installed) == [.chrome, .dia, .firefox])
    #expect(BrowserImportSource.allCases.allSatisfy { !$0.applicationBundleIdentifier.isEmpty })
    #expect(Set(allIdentifiers).count == allIdentifiers.count)
    #expect(BrowserApplicationDiscovery.installedSources(in: Set(allIdentifiers)) == BrowserImportSource.allCases)
}

@Test
func importingAFolderThatIsNotAProfileFailsClearly() throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-not-a-profile-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let (importer, _, _, _) = try makeImporter()
    #expect(throws: BrowserDataImporter.ImportError.self) {
        _ = try importer.preview(at: folder, source: .chrome)
    }
}

@Test
func chromePasswordDecryptionRoundTrips() throws {
    let key = try ChromeCredentialCrypto.derivedKey(safeStoragePassword: "a-safe-storage-secret")
    #expect(key.count == 16)

    let blob = try ChromeCredentialCrypto.encryptForTesting("correct horse battery staple", key: key)
    #expect(blob.prefix(3) == Data("v10".utf8))
    #expect(try ChromeCredentialCrypto.decrypt(blob, key: key) == "correct horse battery staple")

    // A different key must not produce the original plaintext.
    let wrongKey = try ChromeCredentialCrypto.derivedKey(safeStoragePassword: "something-else")
    let decryptedWithWrongKey = try? ChromeCredentialCrypto.decrypt(blob, key: wrongKey)
    #expect(decryptedWithWrongKey != "correct horse battery staple")

    #expect(throws: ChromeCredentialCrypto.CryptoError.self) {
        _ = try ChromeCredentialCrypto.decrypt(Data("v11nonsense".utf8), key: key)
    }
}

@Test
func passwordImportNeedsTheKeyAndStoresNothingWithoutIt() throws {
    // A Chrome profile with one saved login.
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-logins-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let key = try ChromeCredentialCrypto.derivedKey(safeStoragePassword: "secret")
    let blob = try ChromeCredentialCrypto.encryptForTesting("s3cret!", key: key)

    let queue = try DatabaseQueue(path: folder.appendingPathComponent("Login Data").path)
    try queue.write { db in
        try db.execute(sql: """
            CREATE TABLE logins (
                origin_url TEXT NOT NULL,
                username_value TEXT NOT NULL,
                password_value BLOB
            )
            """)
        try db.execute(
            sql: "INSERT INTO logins (origin_url, username_value, password_value) VALUES (?, ?, ?)",
            arguments: ["https://example.com/login", "person@example.com", blob]
        )
        try db.execute(
            sql: "INSERT INTO logins (origin_url, username_value, password_value) VALUES (?, ?, ?)",
            arguments: ["https://never-saved.example", "other@example.com", Data()]
        )
    }
    try Data("{}".utf8).write(to: folder.appendingPathComponent("Bookmarks"))

    let (importer, _, _, _) = try makeImporter()
    let preview = try importer.preview(at: folder, source: .chrome)

    // The preview counts logins without decrypting anything.
    #expect(preview.credentialCount == 1, "Empty password blobs are not logins")
    #expect(preview.credentials.first?.username == "person@example.com")

    // Without a key, passwords are refused rather than silently skipped.
    var options = BrowserImportOptions()
    options.includesBookmarks = false
    options.includesHistory = false
    options.includesPasswords = true
    #expect(throws: BrowserDataImporter.ImportError.self) {
        _ = try importer.apply(preview, options: options, keyProvider: nil, profile: folder)
    }

    // With the key, the password is decrypted.
    let result = try importer.apply(
        preview,
        options: options,
        keyProvider: StubKeyProvider(key: key),
        profile: folder
    )
    #expect(result.credentials.count == 1)
    #expect(result.credentials.first?.password == "s3cret!")
    #expect(result.credentials.first?.username == "person@example.com")
}

private struct StubKeyProvider: BrowserCredentialKeyProviding {
    let key: Data?
    func safeStorageKey(for source: BrowserImportSource) throws -> Data? { key }
}

@Test
func encryptedCookiesRequireConsentAndTheSourceKeyBeforeAnyWrite() throws {
    let profile = try FakeChromeProfile(
        bookmarks: [["type": "url", "name": "Example", "url": "https://example.com"]],
        visits: []
    )
    defer { profile.cleanUp() }
    let network = profile.folder.appendingPathComponent("Network", isDirectory: true)
    try FileManager.default.createDirectory(at: network, withIntermediateDirectories: true)
    let key = try ChromeCredentialCrypto.derivedKey(safeStoragePassword: "fixture-only")
    let encrypted = try ChromeCredentialCrypto.encryptForTesting("session-token", key: key)
    let queue = try DatabaseQueue(path: network.appendingPathComponent("Cookies").path)
    try queue.write { db in
        try db.execute(sql: """
            CREATE TABLE cookies (
                host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB,
                path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER
            )
            """)
        try db.execute(
            sql: "INSERT INTO cookies VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            arguments: [".example.com", "session", "", encrypted, "/", chromeMicros(Date().addingTimeInterval(3600)), 1, 1]
        )
    }

    let (importer, bookmarks, _, _) = try makeImporter()
    let preview = try importer.preview(at: profile.folder, source: .chrome)
    #expect(preview.cookieCount == 1)
    #expect(BrowserImportOptions().includesCookies == false)
    var options = BrowserImportOptions()
    options.includesCookies = true
    #expect(throws: BrowserDataImporter.ImportError.self) {
        _ = try importer.apply(preview, options: options, profile: profile.folder)
    }
    #expect(try bookmarks.all().isEmpty, "No source key must mean no partial import")

    let result = try importer.apply(preview, options: options,
                                    keyProvider: StubKeyProvider(key: key), profile: profile.folder)
    #expect(result.cookies.count == 1)
    #expect(result.cookies.first?.value == "session-token")
    #expect(result.cookies.first?.isSecure == true)
    #expect(result.cookies.first?.isHTTPOnly == true)
}

@Test
func safariBinaryCookiesParserReadsAValidRecordAndRejectsTruncation() {
    func le32(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8((value >> ($0 * 8)) & 0xff) })
    }
    func be32(_ value: UInt32) -> Data {
        Data((0..<4).reversed().map { UInt8((value >> ($0 * 8)) & 0xff) })
    }
    var cookie = Data(repeating: 0, count: 56)
    let values = [".example.com", "session", "/", "fixture-value"]
    for (index, value) in values.enumerated() {
        let offset = UInt32(cookie.count)
        cookie.replaceSubrange((16 + index * 4)..<(20 + index * 4), with: le32(offset))
        cookie.append(contentsOf: value.utf8)
        cookie.append(0)
    }
    cookie.replaceSubrange(0..<4, with: le32(UInt32(cookie.count)))
    cookie.replaceSubrange(8..<12, with: le32(5))
    let expiry = Date().addingTimeInterval(3600).timeIntervalSinceReferenceDate.bitPattern
    cookie.replaceSubrange(40..<48, with: Data((0..<8).map { UInt8((expiry >> ($0 * 8)) & 0xff) }))
    var page = Data([0, 0, 1, 0])
    page.append(le32(1))
    page.append(le32(16))
    page.append(le32(0))
    page.append(cookie)
    var file = Data("cook".utf8)
    file.append(be32(1))
    file.append(be32(UInt32(page.count)))
    file.append(page)

    let parsed = SafariBinaryCookieReader.parse(file)
    #expect(parsed.count == 1)
    #expect(parsed.first?.domain == ".example.com")
    #expect(parsed.first?.value == "fixture-value")
    #expect(parsed.first?.isHTTPOnly == true)
    #expect(SafariBinaryCookieReader.parse(file.dropLast(4)).isEmpty)
}

@Test
func firefoxProfileNamesComeFromProfilesIniBesideProfilesDirectory() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-firefox-\(UUID().uuidString)", isDirectory: true)
    let profile = root.appendingPathComponent("Profiles/abc.default-release", isDirectory: true)
    let custom = root.appendingPathComponent("Profiles/xyz.work", isDirectory: true)
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("[Profile0]\nName=Research\nPath=Profiles/abc.default-release\n[Profile1]\nName=Work\nPath=Profiles/xyz.work\n".utf8)
        .write(to: root.appendingPathComponent("profiles.ini"))
    try Data().write(to: profile.appendingPathComponent("places.sqlite"))
    try Data().write(to: custom.appendingPathComponent("places.sqlite"))
    let candidates = BrowserProfileLocator.profiles(insideBrowserRoot: root, source: .firefox)
    #expect(candidates.count == 2)
    #expect(candidates.contains { $0.profileName == "Research" && $0.label == "Firefox — Research" })
    #expect(candidates.contains { $0.profileName == "Work" && $0.label == "Firefox — Work" })
}

@Test
func firefoxProfileNamesAreNotReadFromOutsideTheSelectedProfilesFolder() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-firefox-scope-\(UUID().uuidString)", isDirectory: true)
    let profiles = root.appendingPathComponent("Profiles", isDirectory: true)
    let profile = profiles.appendingPathComponent("abc.default-release", isDirectory: true)
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("[Profile0]\nName=Outside Grant\nPath=Profiles/abc.default-release\n".utf8)
        .write(to: root.appendingPathComponent("profiles.ini"))
    try Data().write(to: profile.appendingPathComponent("places.sqlite"))

    let candidates = BrowserProfileLocator.profiles(insideBrowserRoot: profiles, source: .firefox)
    #expect(candidates.count == 1)
    #expect(candidates[0].profileName == "abc.default-release")
    #expect(candidates[0].label == "Firefox — abc.default-release")
}

@Test
func passwordCSVMapsCommonManagersWithoutPersistingPlaintext() throws {
    let fixtures: [(headers: String, row: String)] = [
        ("Title,URL,Username,Password,Notes", "Example,https://example.com,alice,fixture-secret,note"),
        ("title,website,username,password,notes", "Example,https://example.com,alice,fixture-secret,note"),
        ("folder,type,name,login_uri,login_username,login_password", "Work,login,Example,https://example.com,alice,fixture-secret"),
        ("url,username,password,extra,name", "https://example.com,alice,fixture-secret,,Example"),
        ("title,url,login,password,category", "Example,https://example.com,alice,fixture-secret,Work")
    ]
    for fixture in fixtures {
        let csv = try BrowserPasswordCSV(data: Data("\(fixture.headers)\r\n\(fixture.row)\r\n".utf8))
        let map = try #require(csv.suggestedMap)
        let credentials = try csv.credentials(using: map)
        #expect(credentials.count == 1)
        #expect(credentials.first?.url.host == "example.com")
        #expect(credentials.first?.username == "alice")
        #expect(credentials.first?.password == "fixture-secret")
    }
}

@Test
func passwordCSVQuotedFieldsRoundTripAndRejectsBadMapping() throws {
    let original = ChromeLogin(url: URL(string: "https://example.com")!,
                               username: "alice, work", password: "quoted \"secret\"\nline")
    let csv = try BrowserPasswordCSV(data: BrowserPasswordCSV.export([original]))
    let map = try #require(csv.suggestedMap)
    #expect(try csv.credentials(using: map) == [original])
    #expect(throws: BrowserPasswordCSV.CSVError.self) {
        _ = try csv.credentials(using: .init(site: 0, username: 0, password: 2))
    }
    #expect(throws: BrowserPasswordCSV.CSVError.self) {
        _ = try BrowserPasswordCSV(data: Data("url,username,password\nhttps://example.com,\"alice\"tail,secret\n".utf8))
    }
}

@Test
func choosingTheParentFolderFindsTheProfileInside() throws {
    let profile = try FakeChromeProfile(
        bookmarks: [["type": "url", "name": "Swift", "url": "https://swift.org"]],
        visits: [("https://swift.org", "Swift", chromeMicros(Date()))]
    )
    defer { profile.cleanUp() }

    // Move the profile into a parent folder that looks like a real install:
    // Chrome/Default, where the user might select "Chrome" instead of "Default".
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-chrome-\(UUID().uuidString)", isDirectory: true)
    let nested = parent.appendingPathComponent("Default", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: profile.folder, to: nested)
    defer { try? FileManager.default.removeItem(at: parent) }

    let (importer, _, _, _) = try makeImporter()
    let preview = try importer.preview(at: parent, source: .chrome)
    #expect(preview.bookmarkCount == 1, "A parent folder should resolve to the profile inside it")
    #expect(preview.historyCount == 1)
}

@Test
func aFolderWithNoBrowserDataExplainsWhatToPick() throws {
    let empty = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-nothing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: empty) }

    let (importer, _, _, _) = try makeImporter()
    do {
        _ = try importer.preview(at: empty, source: .chrome)
        Issue.record("Expected an unsupported-folder error")
    } catch let error as BrowserDataImporter.ImportError {
        let message = error.errorDescription ?? ""
        #expect(message.contains("Default"), "The message should name the folder to pick: \(message)")
    }
}

@Test
func sourceDetectionIdentifiesEachBrowserFromItsFiles() throws {
    let profile = try FakeChromeProfile(bookmarks: [], visits: [])
    defer { profile.cleanUp() }
    #expect(BrowserImportSourceDetector.detect(in: profile.folder) == nil,
            "A moved Chromium profile cannot safely be assumed to use Chrome's encryption key")
    #expect(BrowserImportSourceDetector.detect(
        in: BrowserImportSource.firefox.profileRoot!.deletingLastPathComponent()
    ) == .firefox, "The Firefox folder is the grant root that contains profiles.ini and Profiles")

    let firefox = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-ff-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: firefox, withIntermediateDirectories: true)
    try Data().write(to: firefox.appendingPathComponent("places.sqlite"))
    defer { try? FileManager.default.removeItem(at: firefox) }
    #expect(BrowserImportSourceDetector.detect(in: firefox) == .firefox)

    let empty = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-empty-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: empty) }
    #expect(BrowserImportSourceDetector.detect(in: empty) == nil)
}
