import BrowsemiumCore
import BrowsemiumData
import Foundation
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Test
func suggestionsCollapseRepeatVisitsIntoOneRow() throws {
    let repository = HistoryRepository(database: try AppDatabase.inMemoryProfile())
    let url = URL(string: "https://docs.example/swift")!
    for day in 0..<5 { try repository.record(url: url, title: "Swift docs", visitedAt: now.addingTimeInterval(-Double(day) * 86_400)) }
    let results = try repository.suggest("swift", now: now)
    #expect(results.map(\.url) == [url])
    #expect(results.first?.visitedAt == now)
}

@Test
func aFrequentRecentPageOutranksAnOldOneOffWithTheSameWords() throws {
    let repository = HistoryRepository(database: try AppDatabase.inMemoryProfile())
    let oneOff = URL(string: "https://old.example/swift-guide")!
    let daily = URL(string: "https://daily.example/swift-guide")!
    try repository.record(url: oneOff, title: "Swift guide", visitedAt: now.addingTimeInterval(-400 * 86_400))
    for day in 0..<8 { try repository.record(url: daily, title: "Swift guide", visitedAt: now.addingTimeInterval(-Double(day) * 86_400)) }
    #expect(try repository.suggest("swift guide", now: now).map(\.url) == [daily, oneOff])
}

@Test
func aTitleMatchBeatsAnIncidentalURLMatchAndPrefixesWork() throws {
    let repository = HistoryRepository(database: try AppDatabase.inMemoryProfile())
    let incidental = URL(string: "https://shop.example/redirect?to=concurrency")!
    let titled = URL(string: "https://blog.example/post")!
    try repository.record(url: incidental, title: "Checkout", visitedAt: now)
    try repository.record(url: titled, title: "Swift concurrency explained", visitedAt: now)
    let results = try repository.suggest("concurr", now: now).map(\.url)
    #expect(results.first == titled)
    #expect(results.contains(incidental))
}

@Test
func anEmptyQueryFallsBackToRecentAndNoMatchIsEmpty() throws {
    let repository = HistoryRepository(database: try AppDatabase.inMemoryProfile())
    try repository.record(url: URL(string: "https://a.example/")!, title: "A", visitedAt: now)
    #expect(try repository.suggest("   ", now: now).count == 1)
    #expect(try repository.suggest("zzzz", now: now).isEmpty)
}
