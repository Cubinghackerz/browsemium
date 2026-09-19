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
