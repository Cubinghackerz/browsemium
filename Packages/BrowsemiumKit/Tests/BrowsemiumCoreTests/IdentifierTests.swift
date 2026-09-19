import BrowsemiumCore
import Foundation
import Testing

@Test
func identifierCodableRoundTrips() throws {
    try assertRoundTrip(TabID())
    try assertRoundTrip(SpaceID())
    try assertRoundTrip(PaneID())
    try assertRoundTrip(ConversationID())
}

@Test
func settingsPreserveExplicitUnlimitedHistory() throws {
    let settings = BrowserSettings(historyRetentionDays: nil)
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(BrowserSettings.self, from: data)
    #expect(decoded.historyRetentionDays == nil)
    #expect(decoded == settings)
}

@Test
func settingsRoundTripMemoryAndBlockingOptions() throws {
    var settings = BrowserSettings()
    settings.memorySaverEnabled = false
    settings.tabSleepMinutes = 15
    settings.maximumLiveTabs = 6
    settings.warmTabPreloading = false
    settings.contentBlockingEnabled = false

    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(BrowserSettings.self, from: data)
    #expect(decoded == settings)
}

@Test
func olderSettingsFilesKeepWorkingDefaults() throws {
    // A settings file written before the performance fields existed.
    let legacy = """
        {"searchEngineTemplate":"https://duckduckgo.com/?q=","appearance":"dark",
         "historyRetentionDays":30,"clearOnQuit":true,"remoteSearchSuggestions":false,
         "protectionLevel":"strict","persistAIConversations":true,"isAIDockEnabled":true}
        """
    let decoded = try JSONDecoder().decode(BrowserSettings.self, from: Data(legacy.utf8))
    #expect(decoded.appearance == .dark)
    #expect(decoded.historyRetentionDays == 30)
    #expect(decoded.protectionLevel == .strict)
    #expect(decoded.memorySaverEnabled == true)
    #expect(decoded.tabSleepMinutes == 5)
    #expect(decoded.maximumLiveTabs == 4)
    #expect(decoded.contentBlockingEnabled == true)
}

@Test
func sleepIntervalReflectsChosenMinutes() {
    var settings = BrowserSettings()
    settings.tabSleepMinutes = 15
    #expect(settings.tabSleepInterval == 900)
}

@Test
func bangPrefixSelectsOneSearchEngine() {
    let duck = SearchBangParser.parse("!d swift concurrency")
    #expect(duck.preset?.name == "DuckDuckGo")
    #expect(duck.query == "swift concurrency")

    let brave = SearchBangParser.parse("!br rust async")
    #expect(brave.preset?.name == "Brave")
    #expect(brave.query == "rust async")

    // Unknown bangs and plain text fall through untouched.
    #expect(SearchBangParser.parse("!zz hello").preset == nil)
    #expect(SearchBangParser.parse("!d").preset == nil)
    #expect(SearchBangParser.parse("swift").query == "swift")
    #expect(SearchBangParser.parse("!g").preset == nil)
}

@Test
func everyPresetHasAUniqueBang() {
    let bangs = SearchEnginePreset.all.map(\.bang)
    #expect(bangs.allSatisfy { !$0.isEmpty })
    #expect(Set(bangs).count == bangs.count)
}

private func assertRoundTrip<Value: Codable & Equatable>(_ value: Value) throws {
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(Value.self, from: data)
    #expect(decoded == value)
}
