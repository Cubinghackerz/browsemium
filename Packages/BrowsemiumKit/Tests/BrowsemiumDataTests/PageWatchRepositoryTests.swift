import BrowsemiumCore
import BrowsemiumData
import Foundation
import Testing

@Test
func watchesAreAddedOnceStrippedOfFragmentsAndKeepOnlyHashes() throws {
    let repository = PageWatchRepository(database: try AppDatabase.inMemoryProfile())
    let first = try repository.add(url: URL(string: "https://shop.example/tickets#section")!, title: "Tickets", intervalMinutes: 5)
    let again = try repository.add(url: URL(string: "https://shop.example/tickets")!, title: "Other", intervalMinutes: 60)
    #expect(first.id == again.id)
    #expect(first.intervalMinutes == PageWatchLimits.minimumIntervalMinutes)
    #expect(first.url.absoluteString == "https://shop.example/tickets")

    var checked = first
    checked.lastHash = String(repeating: "a", count: 64)
    checked.lastSentences = ["0123456789abcdef", "fedcba9876543210"]
    checked.lastCheckedAt = Date(timeIntervalSince1970: 100)
    checked.lastProblem = nil
    try repository.recordCheck(checked)
    let stored = try #require(try repository.all().first)
    #expect(stored.lastHash == checked.lastHash)
    #expect(stored.lastSentences == checked.lastSentences)
    #expect(stored.lastCheckedAt == checked.lastCheckedAt)
}

@Test
func onlyOrdinaryHTTPSPagesAreAccepted() throws {
    let repository = PageWatchRepository(database: try AppDatabase.inMemoryProfile())
    for bad in ["http://shop.example/", "file:///tmp/x", "https://user:pw@shop.example/", "ftp://shop.example/"] {
        #expect(throws: BrowsemiumError.self) {
            try repository.add(url: URL(string: bad)!, title: "x", intervalMinutes: 60)
        }
    }
    #expect(try repository.all().isEmpty)
}

@Test
func theNumberOfWatchesIsBoundedAndRemovalFreesASlot() throws {
    let repository = PageWatchRepository(database: try AppDatabase.inMemoryProfile())
    var last: PageWatch?
    for index in 0..<PageWatchLimits.maximumWatches {
        last = try repository.add(url: URL(string: "https://site\(index).example/")!, title: "s", intervalMinutes: 60)
    }
    #expect(throws: BrowsemiumError.self) {
        try repository.add(url: URL(string: "https://one-too-many.example/")!, title: "x", intervalMinutes: 60)
    }
    try repository.remove(id: try #require(last).id)
    _ = try repository.add(url: URL(string: "https://one-too-many.example/")!, title: "x", intervalMinutes: 60)
}

@Test
func changingTheIntervalClearsFailures() throws {
    let repository = PageWatchRepository(database: try AppDatabase.inMemoryProfile())
    var watch = try repository.add(url: URL(string: "https://shop.example/")!, title: "s", intervalMinutes: 60)
    watch.consecutiveFailures = 6
    watch.lastProblem = "Couldn't load the page."
    try repository.recordCheck(watch)
    try repository.setInterval(minutes: 360, id: watch.id)
    let stored = try #require(try repository.all().first)
    #expect(stored.intervalMinutes == 360)
    #expect(stored.consecutiveFailures == 0)
    #expect(stored.lastProblem == nil)
}
