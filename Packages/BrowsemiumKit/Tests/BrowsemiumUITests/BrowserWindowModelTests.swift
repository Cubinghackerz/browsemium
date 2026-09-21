import BrowsemiumCore
import BrowsemiumUI
import Foundation
import Testing
import BrowsemiumEngineKit

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
    #expect(model.filteredCommands(query: "bookmarks").map(\.title) == ["Open Bookmarks"])
    #expect(model.filteredCommands(query: "NEW").map(\.title) == ["New Tab"])
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
