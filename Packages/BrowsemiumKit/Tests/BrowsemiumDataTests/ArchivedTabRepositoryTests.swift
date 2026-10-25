import BrowsemiumCore
import BrowsemiumData
import Foundation
import Testing

@Test
func archivedTabsRoundTripNewestFirstAndAreCapped() throws {
    let repository = ArchivedTabRepository(database: try AppDatabase.inMemoryProfile(), maximumEntries: 3)
    let space = SpaceID()
    for index in 0..<5 {
        let tab = BrowserTab(spaceID: space, title: "Tab \(index)", position: index)
        try repository.record(tab, url: URL(string: "https://example.com/\(index)")!, archivedAt: Date(timeIntervalSince1970: Double(index)))
    }
    let entries = try repository.recent()
    #expect(entries.map(\.title) == ["Tab 4", "Tab 3", "Tab 2"])
    #expect(entries.first?.url?.absoluteString == "https://example.com/4")
    #expect(entries.first?.spaceID == space)
    #expect(try repository.count() == 3)
}

@Test
func removingOneAndClearingAllWork() throws {
    let repository = ArchivedTabRepository(database: try AppDatabase.inMemoryProfile())
    let space = SpaceID()
    try repository.record(BrowserTab(spaceID: space, title: "A", position: 0), url: URL(string: "https://a.example")!)
    try repository.record(BrowserTab(spaceID: space, title: "B", position: 1), url: URL(string: "https://b.example")!)
    let first = try #require(try repository.recent().first)
    #expect(try repository.remove(id: first.id))
    #expect(try repository.remove(id: first.id) == false)
    #expect(try repository.count() == 1)
    try repository.removeAll()
    #expect(try repository.recent().isEmpty)
}

@Test
func archiveAndRecentlyClosedAreSeparateStores() throws {
    let database = try AppDatabase.inMemoryProfile()
    let archive = ArchivedTabRepository(database: database)
    let closed = ClosedTabRepository(database: database)
    let tab = BrowserTab(spaceID: SpaceID(), title: "T", lastCommittedURL: URL(string: "https://t.example"), position: 0)
    try archive.record(tab, url: URL(string: "https://t.example")!)
    #expect(try closed.recent().isEmpty)
    try closed.record(tab)
    try archive.removeAll()
    #expect(try closed.recent().count == 1)
}
