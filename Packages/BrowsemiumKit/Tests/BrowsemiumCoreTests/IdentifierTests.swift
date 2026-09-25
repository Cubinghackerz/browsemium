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
    settings.protectionLevel = .off

    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(BrowserSettings.self, from: data)
    #expect(decoded == settings)
    #expect(decoded.contentBlockingEnabled == false)
}

@Test
func legacyBlockingToggleBecomesTheProtectionLevel() throws {
    let legacy = """
        {"appearance":"light","contentBlockingEnabled":false}
        """
    let decoded = try JSONDecoder().decode(BrowserSettings.self, from: Data(legacy.utf8))
    #expect(decoded.protectionLevel == .off)
    #expect(decoded.contentBlockingEnabled == false)
}

@Test
func theOldBlockingToggleWinsOverTheUnusedProtectionPicker() throws {
    let turnedOff = """
        {"protectionLevel":"strict","contentBlockingEnabled":false}
        """
    let off = try JSONDecoder().decode(BrowserSettings.self, from: Data(turnedOff.utf8))
    #expect(off.protectionLevel == .off)

    let leftOn = """
        {"protectionLevel":"strict","contentBlockingEnabled":true}
        """
    let strict = try JSONDecoder().decode(BrowserSettings.self, from: Data(leftOn.utf8))
    #expect(strict.protectionLevel == .strict)
}

@Test
func protectionLevelDrivesBlockingAndSignals() {
    #expect(ProtectionLevel.off.blocksContentRules == false)
    #expect(ProtectionLevel.standard.blocksContentRules)
    #expect(ProtectionLevel.strict.blocksContentRules)

    #expect(ProtectionLevel.standard.sendsGlobalPrivacyControl == false)
    #expect(ProtectionLevel.strict.sendsGlobalPrivacyControl)
    #expect(ProtectionLevel.standard.requiresHTTPS == false)
    #expect(ProtectionLevel.strict.requiresHTTPS)
    #expect(ProtectionLevel.standard.hardensWebContent == false)
    #expect(ProtectionLevel.strict.hardensWebContent)

    #expect(BrowserSettings().protectionLevel == .standard)
    #expect(BrowserSettings().contentBlockingEnabled)
    #expect(BrowserSettings(protectionLevel: .off).contentBlockingEnabled == false)
}

@Test
func strictProtectionUpgradesPlaintextPages() throws {
    let strict = ProtectionLevel.strict
    let upgraded = strict.httpsUpgrade(of: try #require(URL(string: "http://example.com/path?q=1")))
    #expect(upgraded?.absoluteString == "https://example.com/path?q=1")

    let root = strict.httpsUpgrade(of: try #require(URL(string: "http://example.com")))
    #expect(root?.absoluteString == "https://example.com")

    #expect(strict.httpsUpgrade(of: try #require(URL(string: "https://example.com"))) == nil)
    #expect(strict.httpsUpgrade(of: try #require(URL(string: "about:blank"))) == nil)
    #expect(strict.httpsUpgrade(of: try #require(URL(string: "http://localhost:3000/app"))) == nil)
    #expect(strict.httpsUpgrade(of: try #require(URL(string: "http://127.0.0.1:8080/"))) == nil)
    #expect(strict.httpsUpgrade(of: try #require(URL(string: "http://example.com:8080/"))) == nil)
    #expect(strict.httpsUpgrade(of: try #require(URL(string: "http://example.com:80/x")))?.absoluteString == "https://example.com/x")

    #expect(ProtectionLevel.standard.httpsUpgrade(of: try #require(URL(string: "http://example.com"))) == nil)
    #expect(ProtectionLevel.off.httpsUpgrade(of: try #require(URL(string: "http://example.com"))) == nil)
}

@Test
func pausingOneSiteDoesNotUnblockAnother() {
    let paused: Set<String> = ["paused.example"]
    #expect(ProtectionLevel.rulesEnabled(protectionBlocksContent: true, pausedHosts: paused, host: "paused.example") == false)
    #expect(ProtectionLevel.rulesEnabled(protectionBlocksContent: true, pausedHosts: paused, host: "PAUSED.EXAMPLE") == false)
    #expect(ProtectionLevel.rulesEnabled(protectionBlocksContent: true, pausedHosts: paused, host: "open.example"))
    #expect(ProtectionLevel.rulesEnabled(protectionBlocksContent: true, pausedHosts: paused, host: nil))
    #expect(ProtectionLevel.rulesEnabled(protectionBlocksContent: false, pausedHosts: [], host: "open.example") == false)
}

@Test
func protectionLevelsHaveTitles() {
    #expect(ProtectionLevel.off.title == "Off")
    #expect(ProtectionLevel.standard.title == "Balanced")
    #expect(ProtectionLevel.strict.title == "Strict")
}

@Test
func protectionSummariesNameOnlyWhatThisSystemDoes() {
    #expect(ProtectionLevel.off.summary.contains("No bundled blocking rules"))
    #expect(ProtectionLevel.standard.summary.contains("bundled rules"))
    #expect(ProtectionLevel.strict.summary.contains("https"))
    #expect(ProtectionLevel.strict.summary.contains("local addresses"))
    if #available(macOS 27.0, *) {
        #expect(ProtectionLevel.strict.summary.contains("Global Privacy Control signal"))
    } else {
        #expect(ProtectionLevel.strict.summary.contains("needs macOS 27"))
    }
    if #available(macOS 26.4, *) {
        #expect(ProtectionLevel.strict.summary.contains("JIT"))
    } else {
        #expect(ProtectionLevel.strict.summary.contains("needs macOS 26.4"))
    }
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
    // The Chrome Web Store offer opt-out did not exist yet; it defaults on.
    #expect(decoded.offerWebStoreInstalls == true)
}

@Test
func settingsRoundTripTheWebStoreOfferChoice() throws {
    var settings = BrowserSettings()
    settings.offerWebStoreInstalls = false
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(BrowserSettings.self, from: data)
    #expect(decoded.offerWebStoreInstalls == false)
    #expect(decoded == settings)
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
