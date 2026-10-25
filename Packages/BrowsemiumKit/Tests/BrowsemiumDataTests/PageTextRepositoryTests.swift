import BrowsemiumCore
import BrowsemiumData
import Foundation
import Testing

@Test
func pageTextIndexRoundTripsAndSearches() throws {
    let database = try AppDatabase.inMemoryProfile()
    let repository = PageTextRepository(database: database)

    #expect(try repository.size() == (0, 0))
    try repository.index(url: URL(string: "https://example.com/swift")!,
                         title: "Swift concurrency",
                         snippet: "actors and tasks explained")
    try repository.index(url: URL(string: "https://example.com/bread")!,
                         title: "Sourdough",
                         snippet: "starter and flour")
    // Reindexing replaces the row instead of duplicating it.
    try repository.index(url: URL(string: "https://example.com/swift")!,
                         title: "Swift concurrency",
                         snippet: "actors and tasks revised")
    #expect(try repository.size().pages == 2)

    let hits = try repository.search("actors tasks")
    #expect(hits.count == 1)
    #expect(hits.first?.url.absoluteString == "https://example.com/swift")
    #expect(hits.first?.snippet == "actors and tasks revised")
    #expect(try repository.search("sourdough").count == 1)
    #expect(try repository.search("missingword").isEmpty)
    #expect(try repository.search("").isEmpty)
}

@Test
func pageTextSnippetsOver4KBAreRefused() throws {
    let database = try AppDatabase.inMemoryProfile()
    let repository = PageTextRepository(database: database)
    let oversized = String(repeating: "x", count: PageTextIndexPolicy.maxSnippetBytes + 1)

    #expect(throws: BrowsemiumError.self) {
        try repository.index(url: URL(string: "https://example.com/big")!,
                             title: "Big", snippet: oversized)
    }
    #expect(try repository.size().pages == 0)
}

@Test
func pageTextSearchHonorsExcludesAndClear() throws {
    let database = try AppDatabase.inMemoryProfile()
    let repository = PageTextRepository(database: database)
    try repository.index(url: URL(string: "https://kept.example/a")!, title: "Kept", snippet: "shared words here")
    try repository.index(url: URL(string: "https://gone.example/b")!, title: "Gone", snippet: "shared words here")

    #expect(try repository.search("shared", excluding: ["gone.example"]).map(\.url.host) == ["kept.example"])
    try repository.remove(urls: [URL(string: "https://kept.example/a")!])
    #expect(try repository.size().pages == 1)
    try repository.clear()
    #expect(try repository.size() == (0, 0))
}

@Test
func pageTextSizeReportsStoredBytes() throws {
    let database = try AppDatabase.inMemoryProfile()
    let repository = PageTextRepository(database: database)
    try repository.index(url: URL(string: "https://example.com/a")!, title: "A", snippet: "12345")
    let size = try repository.size()
    #expect(size.pages == 1)
    #expect(size.bytes == 5)
    #expect(try repository.recent(limit: 10).count == 1)
}

@Test
func pageTextIndexIsScopedToTheProfileDatabase() throws {
    let databaseA = try AppDatabase.inMemoryProfile()
    let databaseB = try AppDatabase.inMemoryProfile()
    try PageTextRepository(database: databaseA).index(
        url: URL(string: "https://example.com/a")!, title: "A", snippet: "text")
    #expect(try PageTextRepository(database: databaseB).size().pages == 0)
}

@Test
func pageTextTableExistsAfterMigration() throws {
    let database = try AppDatabase.inMemoryProfile()
    let tables = try database.databaseQueue.read { db in
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    #expect(tables.contains("page_texts"))
    #expect(tables.contains("page_texts_fts"))
}

@Test
func pageTextSettingsFlagDefaultsOffAndSurvivesOldJSON() throws {
    #expect(BrowserSettings().indexPageTextOnMac == false)
    let data = try JSONEncoder().encode(BrowserSettings())
    #expect(try JSONDecoder().decode(BrowserSettings.self, from: data).indexPageTextOnMac == false)
    // JSON written before the flag existed still decodes, defaulting off.
    let legacy = """
        {"searchEngineTemplate":"https://example.com/?q=","appearance":"system","clearOnQuit":false,\
        "protectionLevel":"standard","persistAIConversations":false,"isAIDockEnabled":true,\
        "includePageMetadataInWebAI":true,"includePageContextInAPIAI":false,"memorySaverEnabled":true,\
        "tabSleepMinutes":5,"maximumLiveTabs":4,"warmTabPreloading":true,"tabLayout":"top",\
        "linkPreviewOnHover":false,"offerWebStoreInstalls":true,"developerToolsEnabled":false,\
        "chromeStyle":"standard"}
        """.data(using: .utf8)!
    #expect(try JSONDecoder().decode(BrowserSettings.self, from: legacy).indexPageTextOnMac == false)
}

@Test
func pageTextsFollowHistoryRetentionAndClearing() throws {
    let database = try AppDatabase.inMemoryProfile()
    let repository = PageTextRepository(database: database)
    let old = Date().addingTimeInterval(-90 * 86_400)
    try repository.index(url: URL(string: "https://old.example/")!, title: "Old",
                         snippet: "old words", now: old)
    try repository.index(url: URL(string: "https://new.example/")!, title: "New",
                         snippet: "new words")

    var settings = BrowserSettings()
    settings.historyRetentionDays = 30
    let report = try DatabaseMaintenance(database: database).run(settings: settings)
    #expect(report.prunedPageTexts == 1)
    #expect(try repository.size().pages == 1)

    try PrivacyDataManager(database: database).clear([.downloads])
    #expect(try repository.size().pages == 1)
    try PrivacyDataManager(database: database).clear([.history])
    #expect(try repository.size().pages == 0)
}
