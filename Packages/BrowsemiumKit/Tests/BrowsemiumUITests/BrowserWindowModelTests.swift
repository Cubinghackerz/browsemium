import BrowsemiumCore
@testable import BrowsemiumUI
import Foundation
import Testing
import BrowsemiumEngineKit

@Test @MainActor
func blockingPauseIsRememberedForOneHostOnly() {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    model.addressText = "https://paused.example/page"
    model.submitAddress()
    let pausedTab = model.session.activeTabID

    model.setBlockingPaused(true)

    #expect(model.isBlockingPaused(for: URL(string: "https://paused.example/other")))
    #expect(model.isBlockingPaused(for: URL(string: "https://open.example")) == false)
    #expect(engine.pausedTabs[pausedTab!] == true)
    #expect(engine.pausedHosts.contains("paused.example"))
    #expect(engine.pausedHosts.contains("open.example") == false)
}

@Test @MainActor
func aPrivateWindowDoesNotRememberABlockingPause() {
    let model = BrowserWindowModel()
    model.enterPrivateMode()
    model.addressText = "https://paused.example"
    model.submitAddress()

    model.setBlockingPaused(true)

    #expect(model.isBlockingPaused(for: URL(string: "https://paused.example")) == false)
    #expect(model.statusMessage == "A private window does not remember site exceptions.")
}

@Test @MainActor
func newTabBecomesActive() {
    let model = BrowserWindowModel()
    let originalCount = model.session.tabs.count
    let newID = model.newTab()

    #expect(model.session.tabs.count == originalCount + 1)
    #expect(model.session.activeTabID == newID)
}

@Test @MainActor
func closingLastTabCreatesBlankReplacement() {
    let model = BrowserWindowModel()
    let originalID = model.session.activeTabID
    model.closeTab()

    #expect(model.session.tabs.count == 1)
    #expect(model.session.activeTabID != originalID)
    #expect(model.activeTab?.title == "New Tab")
    #expect(model.activeTab?.url == nil)
}

@Test @MainActor
func tabsCanBeReorderedAndPinned() {
    let model = BrowserWindowModel()
    let firstID = model.session.activeTabID!
    let secondID = model.newTab()
    let thirdID = model.newTab()

    model.moveTab(thirdID, before: firstID)
    model.togglePin(thirdID)

    #expect(model.session.tabs.map(\.id) == [thirdID, firstID, secondID])
    #expect(model.session.tabs.first?.isPinned == true)
}

@Test @MainActor
func downloadProgressReportsFractionAndPercent() {
    let partial = BrowserWindowModel.DownloadProgress(
        id: UUID(),
        filename: "report.pdf",
        bytesReceived: 250,
        totalBytes: 1000,
        isFinished: false,
        failureMessage: nil
    )
    #expect(partial.fraction == 0.25)
    #expect(partial.percentText == "25%")

    let unknownSize = BrowserWindowModel.DownloadProgress(
        id: UUID(),
        filename: "stream.bin",
        bytesReceived: 512,
        totalBytes: 0,
        isFinished: false,
        failureMessage: nil
    )
    #expect(unknownSize.fraction == nil)
    #expect(unknownSize.percentText == "Starting…")

    let overrun = BrowserWindowModel.DownloadProgress(
        id: UUID(),
        filename: "big.zip",
        bytesReceived: 2000,
        totalBytes: 1000,
        isFinished: true,
        failureMessage: nil
    )
    #expect(overrun.fraction == 1)
}

@Test @MainActor
func reloadIsDisabledUntilAPageExists() {
    let model = BrowserWindowModel()
    #expect(model.canReload == false)
    #expect(model.activeTab?.lastCommittedURL == nil)
}

@Test @MainActor
func commandFilteringIsCaseInsensitive() {
    let model = BrowserWindowModel()
    // The palette mixes tabs, intents, history, and commands; these assert the
    // command is found, not that it is the only row.
    #expect(model.filteredCommands(query: "bookmarks").contains { $0.title == "Open Bookmarks" })
    #expect(model.filteredCommands(query: "NEW").contains { $0.title == "New Tab" })
    #expect(model.filteredCommands(query: "   ").count == model.paletteCommands.count)
}

@Test @MainActor
func deferredStartupPopulatesBookmarksAfterInit() throws {
    let environment = BrowserEnvironment.inMemory()
    _ = try environment.bookmarkRepository.add(url: URL(string: "https://seeded.example")!, title: "Seeded")

    let model = BrowserWindowModel(environment: environment)
    // The launch path stays cheap: init must not synchronously read the
    // bookmark store; the deferred pass fills the UI after the first frame.
    #expect(model.bookmarks.isEmpty)

    model.performDeferredStartup()
    #expect(model.bookmarks.contains { $0.url.absoluteString == "https://seeded.example" })

    // A second call must not re-run the work — the guard makes it idempotent.
    model.performDeferredStartup()
    #expect(model.bookmarks.count == 1)
}

@Test @MainActor
func submittingAnAlreadyOpenURLSwitchesToTheExistingTab() {
    let model = BrowserWindowModel()
    let openID = model.newTab(url: URL(string: "https://work.example")!)
    _ = model.newTab()  // blank tab becomes active
    let tabCount = model.session.tabs.count

    model.addressText = "https://work.example"
    model.submitAddress()

    #expect(model.session.activeTabID == openID)
    #expect(model.session.tabs.count == tabCount)
    #expect(model.statusMessage != nil)
}

@Test @MainActor
func duplicateCheckIgnoresTrailingSlashAndCase() {
    let model = BrowserWindowModel()
    let openID = model.newTab(url: URL(string: "https://work.example/path")!)
    _ = model.newTab()

    model.addressText = "https://WORK.example/path/"
    model.submitAddress()

    #expect(model.session.activeTabID == openID)
}

@Test @MainActor
func selectingSearchEnginePersistsAndAppliesToTheNextAddressSearch() {
    let environment = BrowserEnvironment.inMemory(engine: StubEngine())
    let model = BrowserWindowModel(environment: environment)

    model.selectSearchEngine(.bing)

    #expect(model.activeSearchEngineName == "Bing")
    #expect(model.searchEngineTemplate == SearchEnginePreset.bing.template)
    #expect(environment.loadSettings().searchEngineTemplate == SearchEnginePreset.bing.template)

    model.addressText = "browsemium browser"
    model.submitAddress()

    #expect(model.activeTab?.lastCommittedURL?.host == "www.bing.com")
    #expect(model.activeTab?.lastCommittedURL?.query?.contains("browsemium") == true)
}

@Test @MainActor
func searchEngineTemplateTracksSettingsChangesAndProfileSwitches() {
    let environment = BrowserEnvironment.inMemory(engine: StubEngine())
    let model = BrowserWindowModel(environment: environment)

    model.updateSettings { $0.searchEngineTemplate = SearchEnginePreset.brave.template }
    #expect(model.searchEngineTemplate == SearchEnginePreset.brave.template)
    #expect(model.activeSearchEngineName == "Brave")

    let profile = model.createProfile(named: "Alternate", switchToIt: false)!
    model.switchProfile(to: profile)
    #expect(model.searchEngineTemplate == SearchEnginePreset.google.template)

    model.updateSettings { $0.searchEngineTemplate = SearchEnginePreset.duckDuckGo.template }
    #expect(model.searchEngineTemplate == SearchEnginePreset.duckDuckGo.template)

    model.switchProfile(to: environment.profiles.first { $0.name == "Personal" }!)
    #expect(model.searchEngineTemplate == SearchEnginePreset.brave.template)
}

@Test @MainActor
func bangSearchOverridesDefaultWithoutChangingIt() {
    let environment = BrowserEnvironment.inMemory(engine: StubEngine())
    let model = BrowserWindowModel(environment: environment)
    model.selectSearchEngine(.bing)

    model.addressText = "!d private browsing"
    model.submitAddress()

    #expect(model.activeTab?.lastCommittedURL?.host == "duckduckgo.com")
    #expect(model.activeSearchEngineName == "Bing")
}

@Test @MainActor
func zoomPreferenceRoundTripsPerHost() throws {
    let environment = BrowserEnvironment.inMemory()
    let model = BrowserWindowModel(environment: environment)
    _ = model.newTab(url: URL(string: "https://zoom.example/page")!)

    // No live webview in tests, so the engine reports 100%; the assertion is
    // that the preference is written for the host and removed on reset.
    model.zoomIn()
    #expect(try environment.sitePreferenceRepository.value(origin: "zoom.example", preference: "zoom") != nil)

    model.resetZoom()
    #expect(try environment.sitePreferenceRepository.value(origin: "zoom.example", preference: "zoom") == nil)
}

@Test @MainActor
func zoomDisplayPublishesChangesImmediately() {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    _ = model.newTab(url: URL(string: "https://zoom.example/page")!)
    let initialRevision = model.zoomDisplayRevision

    model.zoomIn()
    #expect(model.activeZoomPercent == 110)
    #expect(model.zoomDisplayRevision == initialRevision + 1)

    model.zoomOut()
    #expect(model.activeZoomPercent == 100)
    #expect(model.zoomDisplayRevision == initialRevision + 2)

    model.zoomIn()
    model.resetZoom()
    #expect(model.activeZoomPercent == 100)
    #expect(model.zoomDisplayRevision == initialRevision + 4)
}

@Test @MainActor
func zoomPreferenceKeysOnTheLowercasedHost() throws {
    let environment = BrowserEnvironment.inMemory()
    let model = BrowserWindowModel(environment: environment)
    _ = model.newTab(url: URL(string: "HTTPS://Zoom.Example/Path")!)

    model.zoomIn()
    #expect(try environment.sitePreferenceRepository.value(origin: "zoom.example", preference: "zoom") != nil)
}

@Test @MainActor
func recentlyClosedListReopensASpecificEntry() throws {
    let model = BrowserWindowModel()
    let tabID = model.newTab(url: URL(string: "https://closed.example")!)
    model.closeTab(tabID)

    let entries = model.recentlyClosedTabs()
    let entry = try #require(entries.first { $0.url?.absoluteString == "https://closed.example" })

    model.reopenClosedTab(entry)
    #expect(model.session.tabs.contains { $0.lastCommittedURL?.absoluteString == "https://closed.example" })
    #expect(model.recentlyClosedTabs().contains { $0.id == entry.id } == false)
}

@Test @MainActor
func closingABlankTabDoesNotLitterRecentlyClosed() {
    let model = BrowserWindowModel()
    let blank = model.newTab()
    model.closeTab(blank)
    #expect(model.recentlyClosedTabs().isEmpty)
}

@Test @MainActor
func downloadHistoryRecordsTheSourceNotTheDestination() throws {
    let environment = BrowserEnvironment.inMemory()
    let model = BrowserWindowModel(environment: environment)
    model.handleDownload(DownloadInfo(
        id: UUID(),
        tabID: nil,
        sourceURL: URL(string: "https://files.example/report.pdf")!,
        suggestedFilename: "report.pdf",
        destinationURL: URL(fileURLWithPath: "/tmp/report.pdf"),
        bytesReceived: 100,
        totalBytes: 100,
        isFinished: true,
        failureMessage: nil
    ))

    let records = try environment.downloadRepository.recent()
    let record = try #require(records.first)
    #expect(record.sourceURL.absoluteString == "https://files.example/report.pdf")
    #expect(record.destinationURL?.path == "/tmp/report.pdf")
    #expect(record.state == .finished)
}

@Test @MainActor
func downloadProgressUpdatesLiveAndFinishesInTheDownloadsList() throws {
    let environment = BrowserEnvironment.inMemory()
    let model = BrowserWindowModel(environment: environment)
    let id = UUID()
    let source = URL(string: "https://files.example/archive.zip")!
    let destination = URL(fileURLWithPath: "/tmp/archive.zip")

    model.handleDownload(DownloadInfo(
        id: id,
        tabID: nil,
        sourceURL: source,
        suggestedFilename: "archive.zip",
        destinationURL: destination,
        bytesReceived: 2_500,
        totalBytes: 10_000,
        isFinished: false,
        failureMessage: nil
    ))

    #expect(model.activeDownloads.count == 1)
    #expect(model.activeDownloads.first?.fraction == 0.25)
    #expect(model.downloads.first?.destinationURL == destination)
    #expect(try environment.downloadRepository.recent().first?.state == .inProgress)

    model.handleDownload(DownloadInfo(
        id: id,
        tabID: nil,
        sourceURL: source,
        suggestedFilename: "archive.zip",
        destinationURL: destination,
        bytesReceived: 10_000,
        totalBytes: 10_000,
        isFinished: true,
        failureMessage: nil
    ))

    #expect(model.activeDownloads.isEmpty)
    #expect(model.downloads.count == 1)
    #expect(model.downloads.first?.isFinished == true)
    #expect(try environment.downloadRepository.recent().first?.state == .finished)
}

@Test @MainActor
func downloadWithoutASourceURLIsNotPersisted() throws {
    let environment = BrowserEnvironment.inMemory()
    let model = BrowserWindowModel(environment: environment)
    model.handleDownload(DownloadInfo(
        id: UUID(),
        tabID: nil,
        sourceURL: nil,
        suggestedFilename: "mystery.bin",
        destinationURL: URL(fileURLWithPath: "/tmp/mystery.bin"),
        bytesReceived: 10,
        totalBytes: 10,
        isFinished: true,
        failureMessage: nil
    ))

    // Better no row than a file:/// path masquerading as the source.
    #expect(try environment.downloadRepository.recent().isEmpty)
}

@Test @MainActor
func openTabsSurfaceAsAddressSuggestions() {
    let model = BrowserWindowModel()
    let openID = model.newTab(url: URL(string: "https://docs.example/guide")!)
    _ = model.newTab()

    // A query containing a dot is treated as a typed URL and short-circuits
    // suggestions, so match on the path instead.
    model.addressText = "guide"
    model.updateAddressSuggestions()

    let openTab = model.addressSuggestions.first { $0.kind == .openTab }
    #expect(openTab != nil)
    model.acceptSuggestion(openTab!)
    #expect(model.session.activeTabID == openID)
}

@Test @MainActor
func togglingTabLayoutUpdatesModelAndPersists() {
    let environment = BrowserEnvironment.inMemory()
    let model = BrowserWindowModel(environment: environment)
    #expect(model.tabLayout == .top)

    model.toggleTabLayout()
    #expect(model.tabLayout == .sidebar)
    #expect(environment.loadSettings().tabLayout == .sidebar)

    model.toggleTabLayout()
    #expect(model.tabLayout == .top)
    #expect(environment.loadSettings().tabLayout == .top)
}

@Test @MainActor
func storedSidebarLayoutIsPickedUpAtLaunch() {
    let environment = BrowserEnvironment.inMemory()
    var settings = environment.loadSettings()
    settings.tabLayout = .sidebar
    environment.saveSettings(settings)

    let model = BrowserWindowModel(environment: environment)
    #expect(model.tabLayout == .sidebar)
}

@Test @MainActor
func tabLayoutSettingDecodesFromOlderSettingsJSON() throws {
    let json = #"{"searchEngineTemplate":"https://www.google.com/search?q="}"#
    let settings = try JSONDecoder().decode(BrowserSettings.self, from: Data(json.utf8))
    #expect(settings.tabLayout == .top)
}

@Test @MainActor
func submittingSearchKeepsQueryInAddressBar() {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    model.selectSearchEngine(.duckDuckGo)

    model.addressText = "what is ai"
    model.submitAddress()

    #expect(model.addressText == "what is ai")
}

@Test @MainActor
func committedSearchNavigationWithExtraParamsKeepsQuery() {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    model.selectSearchEngine(.duckDuckGo)

    model.addressText = "what is ai"
    model.submitAddress()
    let tab = model.session.activeTabID!

    // The results page's own JavaScript appends ia=web after load; the bar
    // must keep showing the query, not the rewritten URL.
    let rewritten = URL(string: "https://duckduckgo.com/?q=what+is+ai&ia=web")!
    engine.emit(.committed(rewritten), for: tab)
    #expect(model.addressText == "what is ai")
    engine.emit(.finished(title: "what is ai at DuckDuckGo", url: rewritten), for: tab)
    #expect(model.addressText == "what is ai")
}

@Test @MainActor
func navigatingAwayFromSearchShowsURL() {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    model.selectSearchEngine(.duckDuckGo)

    model.addressText = "what is ai"
    model.submitAddress()
    let tab = model.session.activeTabID!
    engine.emit(.committed(URL(string: "https://duckduckgo.com/?q=what+is+ai&ia=web")!), for: tab)
    #expect(model.addressText == "what is ai")

    // Following a result leaves the search page, so the real URL returns.
    engine.emit(.committed(URL(string: "https://example.com/article")!), for: tab)
    #expect(model.addressText == "https://example.com/article")
}

@Test @MainActor
func switchingTabsPreservesSearchDisplay() {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    model.selectSearchEngine(.duckDuckGo)

    model.addressText = "what is ai"
    model.submitAddress()
    let first = model.session.activeTabID!
    engine.emit(.committed(URL(string: "https://duckduckgo.com/?q=what+is+ai&ia=web")!), for: first)

    _ = model.newTab()
    #expect(model.addressText == "")

    model.selectTab(first)
    #expect(model.addressText == "what is ai")
}

@Test @MainActor
func bangSearchShowsParsedQueryInAddressBar() {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    model.selectSearchEngine(.bing)

    model.addressText = "!d private browsing"
    model.submitAddress()

    #expect(model.addressText == "private browsing")
    let tab = model.session.activeTabID!
    engine.emit(.committed(URL(string: "https://duckduckgo.com/?q=private+browsing")!), for: tab)
    #expect(model.addressText == "private browsing")
}

@Test @MainActor
func navigatingToAURLShowsTheURL() {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))

    model.addressText = "https://example.com/path"
    model.submitAddress()
    #expect(model.addressText == "https://example.com/path")

    let tab = model.session.activeTabID!
    engine.emit(.committed(URL(string: "https://example.com/path")!), for: tab)
    #expect(model.addressText == "https://example.com/path")
}

@Test @MainActor
func togglingSidebarCollapsedPersists() {
    let key = "browsemium.sidebarCollapsed"
    let previous = UserDefaults.standard.object(forKey: key)
    defer {
        if let previous {
            UserDefaults.standard.set(previous, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    UserDefaults.standard.removeObject(forKey: key)

    let environment = BrowserEnvironment.inMemory()
    let model = BrowserWindowModel(environment: environment)
    #expect(model.isSidebarCollapsed == false)

    model.toggleSidebarCollapsed()
    #expect(model.isSidebarCollapsed == true)

    // A fresh window picks up the stored choice, like the bookmarks bar does.
    let relaunched = BrowserWindowModel(environment: environment)
    #expect(relaunched.isSidebarCollapsed == true)

    relaunched.toggleSidebarCollapsed()
    #expect(relaunched.isSidebarCollapsed == false)
}
