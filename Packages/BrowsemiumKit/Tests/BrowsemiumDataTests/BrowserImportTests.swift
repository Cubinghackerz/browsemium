import BrowsemiumCore
import BrowsemiumData
import Foundation
import GRDB
import Testing

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
    #expect(BrowserImportSourceDetector.detect(in: profile.folder) == .chrome)

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
