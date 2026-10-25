import BrowsemiumCore
import BrowsemiumEngineKit
import BrowsemiumUI
import Foundation
import Testing

@Test
func compactChromeSavesVerticalSpaceInEveryLayout() {
    for bookmarks in [false, true] {
        let standardTop = BrowserMetrics.verticalChrome(style: .standard, layout: .top, bookmarksBarVisible: bookmarks)
        let compactTop = BrowserMetrics.verticalChrome(style: .compact, layout: .top, bookmarksBarVisible: bookmarks)
        #expect(standardTop - compactTop >= 15, "top strip: \(standardTop) vs \(compactTop)")
        let standardSide = BrowserMetrics.verticalChrome(style: .standard, layout: .sidebar, bookmarksBarVisible: bookmarks)
        let compactSide = BrowserMetrics.verticalChrome(style: .compact, layout: .sidebar, bookmarksBarVisible: bookmarks)
        #expect(standardSide - compactSide >= 6, "sidebar: \(standardSide) vs \(compactSide)")
    }
    // With the bookmarks bar hidden on pages (compact), the saving is larger still.
    let withBar = BrowserMetrics.verticalChrome(style: .standard, layout: .top, bookmarksBarVisible: true)
    let compactNoBar = BrowserMetrics.verticalChrome(style: .compact, layout: .top, bookmarksBarVisible: false)
    #expect(withBar - compactNoBar >= 45)
}

@Test
func compactRowsAreStillBigEnoughToClick() {
    #expect(BrowserMetrics.compactToolbarHeight >= 32)
    #expect(BrowserMetrics.compactTabStripHeight >= 28)
    #expect(BrowserMetrics.toolbarHeight(for: .standard) == BrowserMetrics.toolbarHeight)
}

@Test
func theChromeStyleSettingRoundTripsAndOlderSettingsStayStandard() throws {
    var settings = BrowserSettings()
    #expect(settings.chromeStyle == .standard)
    settings.chromeStyle = .compact
    let round = try JSONDecoder().decode(BrowserSettings.self, from: JSONEncoder().encode(settings))
    #expect(round.chromeStyle == .compact)
    let old = try JSONDecoder().decode(BrowserSettings.self, from: #"{"appearance":"dark"}"#.data(using: .utf8)!)
    #expect(old.chromeStyle == .standard)
}

@Test @MainActor
func theModelFollowsTheSettingAndKnowsWhenItShowsTheStartPage() {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    #expect(model.chromeStyle == .standard)
    #expect(model.isShowingStartPage)

    model.updateSettings { $0.chromeStyle = .compact }
    #expect(model.chromeStyle == .compact)

    let tab = model.session.activeTabID!
    engine.emit(.committed(URL(string: "https://example.com/")!), for: tab)
    #expect(!model.isShowingStartPage)

    // A relaunch restores the choice.
    let again = BrowserWindowModel(environment: model.environment)
    #expect(again.chromeStyle == .compact)
}
