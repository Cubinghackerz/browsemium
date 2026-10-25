import BrowsemiumCore
@testable import BrowsemiumData
import Compression
import Foundation
import GRDB
import Testing

// MARK: - Generated fixtures (never a real user profile)

private func mozLz40Wrap(_ json: Data) throws -> Data {
    var compressed = Data(count: json.count + 1024)
    let capacity = compressed.count
    let encodedCount = compressed.withUnsafeMutableBytes { dst -> Int in
        json.withUnsafeBytes { src -> Int in
            compression_encode_buffer(
                dst.baseAddress!.assumingMemoryBound(to: UInt8.self),
                capacity,
                src.baseAddress!.assumingMemoryBound(to: UInt8.self),
                json.count,
                nil,
                COMPRESSION_LZ4
            )
        }
    }
    #expect(encodedCount > 0)
    compressed.count = encodedCount
    var out = Data("mozLz40\0".utf8)
    var size = UInt32(json.count).littleEndian
    out.append(Data(bytes: &size, count: 4))
    out.append(compressed)
    return out
}

private struct FakeFirefoxSessionProfile {
    let folder: URL

    init(session: [String: Any]) throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("browsemium-ff-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The validity gate looks for places.sqlite; an empty schema is
        // enough when the test is about the session file.
        let queue = try DatabaseQueue(path: folder.appendingPathComponent("places.sqlite").path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, last_visit_date INTEGER)")
            try db.execute(sql: "CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, title TEXT, dateAdded INTEGER)")
        }
        let backups = folder.appendingPathComponent("sessionstore-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let json = try JSONSerialization.data(withJSONObject: session)
        try mozLz40Wrap(json).write(to: backups.appendingPathComponent("recovery.jsonlz4"))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }
}

private struct FakeSafariSessionProfile {
    let folder: URL

    init(windows: [[String: Any]]) throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("browsemium-sf-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bookmarks: [String: Any] = ["Children": [], "Title": "Bookmarks"]
        let bookmarkData = try PropertyListSerialization.data(
            fromPropertyList: bookmarks, format: .xml, options: 0)
        try bookmarkData.write(to: folder.appendingPathComponent("Bookmarks.plist"))
        let session: [String: Any] = ["SessionWindows": windows]
        let sessionData = try PropertyListSerialization.data(
            fromPropertyList: session, format: .binary, options: 0)
        try sessionData.write(to: folder.appendingPathComponent("LastSession.plist"))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }
}

private func makeImporter() throws -> BrowserDataImporter {
    let database = try AppDatabase.inMemory()
    return BrowserDataImporter(
        bookmarks: BookmarkRepository(database: database),
        history: HistoryRepository(database: database)
    )
}

private func firefoxSessionJSON() -> [String: Any] {
    [
        "windows": [
            [
                "tabs": [
                    [
                        "entries": [
                            ["url": "https://one.example/a", "title": "One"],
                            ["url": "https://one.example/b", "title": "One B"]
                        ],
                        "index": 2,
                        "pinned": true
                    ],
                    [
                        "entries": [["url": "about:privatebrowsing", "title": "Private"]],
                        "index": 1
                    ],
                    [
                        "entries": [["url": "https://two.example/", "title": ""]],
                        "index": 1
                    ]
                ]
            ],
            [
                "tabs": [
                    ["entries": [["url": "https://one.example/b", "title": "Dupe"]], "index": 1]
                ]
            ]
        ]
    ]
}

// MARK: - Firefox session previews

@Test func firefoxSessionTabsPreviewWithPinnedAndSelectedEntries() throws {
    let profile = try FakeFirefoxSessionProfile(session: firefoxSessionJSON())
    defer { profile.cleanUp() }
    let preview = try makeImporter().preview(at: profile.folder, source: .firefox)

    #expect(preview.sessionTabCount == 2)
    let pinned = try #require(preview.sessionTabs.first { $0.url.absoluteString == "https://one.example/b" })
    #expect(pinned.isPinned)
    #expect(pinned.title == "One B")
    let plain = try #require(preview.sessionTabs.first { $0.url.absoluteString == "https://two.example/" })
    #expect(!plain.isPinned)
    #expect(plain.title == "two.example")
    // about: URLs are never session tabs; the out-of-range index drops its tab.
    #expect(!preview.sessionTabs.contains { $0.url.scheme != "https" })
    #expect(!preview.isEmpty)

    let accepted = preview.report.items.filter { $0.category == .sessionTab && $0.outcome == .accepted }
    #expect(accepted.count == 2)
    #expect(preview.report.items.contains { $0.category == .sessionTab && $0.outcome == .duplicate })
}

@Test func firefoxSessionSiblingBackupIsReadWhenRecoveryIsMissing() throws {
    let profile = try FakeFirefoxSessionProfile(session: ["windows": []])
    defer { profile.cleanUp() }
    let backups = profile.folder.appendingPathComponent("sessionstore-backups")
    try FileManager.default.removeItem(at: backups.appendingPathComponent("recovery.jsonlz4"))
    let json = try JSONSerialization.data(withJSONObject: firefoxSessionJSON())
    try mozLz40Wrap(json).write(to: backups.appendingPathComponent("sessionstore.jsonlz4"))

    let preview = try makeImporter().preview(at: profile.folder, source: .firefox)
    #expect(preview.sessionTabCount == 2)
}

@Test func corruptFirefoxSessionFailsCleanlyWithoutLosingTheProfile() throws {
    let profile = try FakeFirefoxSessionProfile(session: ["windows": []])
    defer { profile.cleanUp() }
    let backups = profile.folder.appendingPathComponent("sessionstore-backups")
    try "not a mozLz40 file".data(using: .utf8)!.write(
        to: backups.appendingPathComponent("recovery.jsonlz4"))

    let preview = try makeImporter().preview(at: profile.folder, source: .firefox)
    #expect(preview.sessionTabs.isEmpty)
    #expect(preview.report.items.contains {
        $0.category == .sessionTab && $0.ordinal == 0 && $0.outcome == .failed
    })
}

@Test func oversizedFirefoxSessionHeaderFailsBeforeAllocating() throws {
    let profile = try FakeFirefoxSessionProfile(session: ["windows": []])
    defer { profile.cleanUp() }
    var data = Data("mozLz40\0".utf8)
    var size = UInt32.max.littleEndian
    data.append(Data(bytes: &size, count: 4))
    try data.write(to: profile.folder
        .appendingPathComponent("sessionstore-backups/recovery.jsonlz4"))

    let preview = try makeImporter().preview(at: profile.folder, source: .firefox)
    #expect(preview.sessionTabs.isEmpty)
    #expect(preview.report.items.contains {
        $0.category == .sessionTab && $0.outcome == .unsupported && $0.reason == .limitExceeded
    })
}

@Test func firefoxSessionWithoutAnyBackupYieldsNoTabsAndNoFailure() throws {
    let profile = try FakeFirefoxSessionProfile(session: ["windows": []])
    defer { profile.cleanUp() }
    try FileManager.default.removeItem(at: profile.folder.appendingPathComponent("sessionstore-backups"))

    let preview = try makeImporter().preview(at: profile.folder, source: .firefox)
    #expect(preview.sessionTabs.isEmpty)
    #expect(!preview.report.items.contains { $0.category == .sessionTab })
}

// MARK: - Safari session previews

@Test func safariSessionTabsPreviewAcrossWindows() throws {
    let profile = try FakeSafariSessionProfile(windows: [
        ["Tabs": [
            ["URLString": "https://safari.example/a", "Title": "Safari A", "Pinned": true],
            ["URLString": "file:///etc/passwd", "Title": "Local"],
            ["Title": "No URL"]
        ], "ActiveTab": 0],
        ["Tabs": [["URLString": "https://safari.example/b", "Title": "", "UnknownKey": 1]]]
    ])
    defer { profile.cleanUp() }
    let preview = try makeImporter().preview(at: profile.folder, source: .safari)

    #expect(preview.sessionTabCount == 2)
    #expect(preview.sessionTabs.allSatisfy { $0.url.scheme == "https" })
    #expect(preview.sessionTabs.first?.title == "Safari A")
    // Unknown plist keys are ignored; Safari tabs never arrive pinned.
    #expect(preview.sessionTabs.allSatisfy { !$0.isPinned })
}

@Test func corruptSafariSessionFailsCleanlyWithoutLosingTheProfile() throws {
    let profile = try FakeSafariSessionProfile(windows: [])
    defer { profile.cleanUp() }
    try "definitely not a plist".data(using: .utf8)!.write(
        to: profile.folder.appendingPathComponent("LastSession.plist"))

    let preview = try makeImporter().preview(at: profile.folder, source: .safari)
    #expect(preview.sessionTabs.isEmpty)
    #expect(preview.report.items.contains {
        $0.category == .sessionTab && $0.ordinal == 0 && $0.outcome == .failed
    })
}

// MARK: - Apply

@Test func sessionTabsTransferOnlyWhenSelected() throws {
    let profile = try FakeFirefoxSessionProfile(session: firefoxSessionJSON())
    defer { profile.cleanUp() }
    let importer = try makeImporter()
    let preview = try importer.preview(at: profile.folder, source: .firefox)

    var included = BrowserImportOptions()
    included.includesBookmarks = false
    included.includesHistory = false
    let result = try importer.apply(preview, options: included, profile: profile.folder)
    #expect(result.sessionTabs.count == 2)
    #expect(result.report.items.filter {
        $0.category == .sessionTab && $0.stage == .transfer && $0.outcome == .accepted
    }.count == 2)

    var excluded = BrowserImportOptions()
    excluded.includesBookmarks = false
    excluded.includesHistory = false
    excluded.includesSessionTabs = false
    let skipped = try importer.apply(preview, options: excluded, profile: profile.folder)
    #expect(skipped.sessionTabs.isEmpty)
    #expect(skipped.report.items.contains {
        $0.category == .sessionTab && $0.stage == .transfer && $0.outcome == .skipped && $0.reason == .notSelected
    })
}

@Test func sessionReportContainsNoSecrets() throws {
    let profile = try FakeFirefoxSessionProfile(session: [
        "windows": [["tabs": [
            ["entries": [["url": "https://secret-vault.example/hunter2", "title": "hunter2 user"]], "index": 1]
        ]]]
    ])
    defer { profile.cleanUp() }
    let importer = try makeImporter()
    let preview = try importer.preview(at: profile.folder, source: .firefox)
    let result = try importer.apply(preview, profile: profile.folder)
    let payload = try JSONEncoder().encode(result.report)
    let text = String(data: payload, encoding: .utf8) ?? ""
    #expect(!text.contains("secret-vault"))
    #expect(!text.contains("hunter2"))
}
