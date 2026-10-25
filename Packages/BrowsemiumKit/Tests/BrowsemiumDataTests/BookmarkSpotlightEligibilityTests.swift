import BrowsemiumCore
import BrowsemiumData
import Foundation
import GRDB
import Testing

@Test
func bookmarkSpotlightEligibilityIsDecidedOnceAndRoundTrips() throws {
    let database = try AppDatabase.inMemoryProfile()
    let repository = BookmarkRepository(database: database)
    try repository.add(url: URL(string: "https://ordinary.example/")!, title: "Ordinary")
    try repository.add(url: URL(string: "https://hidden.example/")!, title: "Hidden", spotlightEligible: false)

    let saved = try repository.all()
    #expect(saved.first { $0.url.host == "ordinary.example" }?.isSpotlightEligible == true)
    #expect(saved.first { $0.url.host == "hidden.example" }?.isSpotlightEligible == false)
    #expect(try repository.search("hidden").first?.isSpotlightEligible == false)
}

@Test
func bookmarksWrittenWithoutTheColumnDefaultToEligible() throws {
    let database = try AppDatabase.inMemoryProfile()
    // A row written the way an older build wrote it: no eligibility column.
    try database.databaseQueue.write { db in
        try db.execute(sql: """
            INSERT INTO bookmarks (id, url, title, folder, sort_order, created_at)
            VALUES (?, 'https://old.example/', 'Old', NULL, 1, ?)
            """, arguments: [UUID().uuidString, Date()])
    }
    #expect(try BookmarkRepository(database: database).all().first?.isSpotlightEligible == true)
}
