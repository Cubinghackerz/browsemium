import BrowsemiumCore
import BrowsemiumEngineKit
import BrowsemiumUI
import Foundation
import Testing

@MainActor
private func windowWithStaleTabs() -> (BrowserWindowModel, StubEngine, [TabID]) {
    let engine = StubEngine()
    let environment = BrowserEnvironment.inMemory(engine: engine)
    var settings = environment.loadSettings()
    settings.archiveStaleTabsAfterHours = 24
    environment.saveSettings(settings)
    let model = BrowserWindowModel(environment: environment)
    var ids = [model.session.activeTabID!]
    for _ in 0..<3 { ids.append(model.newTab(url: nil)) }
    for (offset, id) in ids.enumerated() {
        let url = URL(string: "https://site\(offset).example/")!
        engine.emit(.committed(url), for: id)
        engine.emit(.finished(title: "Site \(offset)", url: url), for: id)
    }
    // Look at the first tab so it is the active, visible one.
    model.selectTab(ids[0])
    return (model, engine, ids)
}

@Test @MainActor
func staleTabsMoveToTheArchiveAndNotToRecentlyClosed() throws {
    let (model, _, ids) = windowWithStaleTabs()
    let later = Date().addingTimeInterval(48 * 3_600)

    let count = model.archiveStaleTabs(now: later)

    #expect(count == 3)
    #expect(model.session.tabs.map(\.id) == [ids[0]], "The tab on screen stays")
    #expect(model.archivedTabs().map(\.title).sorted() == ["Site 1", "Site 2", "Site 3"])
    #expect(model.recentlyClosedTabs().isEmpty, "Archiving is not closing")
    #expect(model.statusMessage == "Put away 3 unused tabs in the Archive")
}

@Test @MainActor
func nothingIsArchivedUnlessThePersonChoseAPeriod() {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    _ = model.newTab(url: URL(string: "https://example.com/"))
    #expect(model.archiveStaleTabs(now: Date().addingTimeInterval(1_000 * 3_600)) == 0)
}

@Test @MainActor
func recentlyUsedTabsAreKept() {
    let (model, _, ids) = windowWithStaleTabs()
    #expect(model.archiveStaleTabs(now: Date()) == 0)
    #expect(model.session.tabs.count == ids.count)
}

@Test @MainActor
func privateWindowsNeverArchive() {
    let (model, _, _) = windowWithStaleTabs()
    model.enterPrivateMode()
    #expect(model.archiveStaleTabs(now: Date().addingTimeInterval(1_000 * 3_600)) == 0)
}

@Test @MainActor
func reopeningFromTheArchiveOpensTheAddressAndRemovesTheEntry() throws {
    let (model, _, _) = windowWithStaleTabs()
    model.archiveStaleTabs(now: Date().addingTimeInterval(48 * 3_600))
    let entry = try #require(model.archivedTabs().first { $0.title == "Site 2" })
    let before = model.session.tabs.count

    model.reopenArchivedTab(entry)

    #expect(model.session.tabs.count == before + 1)
    #expect(model.tabURLs[model.session.activeTabID!]?.absoluteString == "https://site2.example/")
    #expect(!model.archivedTabs().contains { $0.id == entry.id })
}

@Test @MainActor
func clearingTheArchiveEmptiesIt() {
    let (model, _, _) = windowWithStaleTabs()
    model.archiveStaleTabs(now: Date().addingTimeInterval(48 * 3_600))
    #expect(!model.archivedTabs().isEmpty)
    model.clearArchivedTabs()
    #expect(model.archivedTabs().isEmpty)
}

@Test
func theSettingRoundTripsAndOlderSettingsDecodeWithItOff() throws {
    var settings = BrowserSettings()
    #expect(settings.archiveStaleTabsAfterHours == nil)
    settings.archiveStaleTabsAfterHours = 168
    let round = try JSONDecoder().decode(BrowserSettings.self, from: JSONEncoder().encode(settings))
    #expect(round.archiveStaleTabsAfterHours == 168)
    let old = try JSONDecoder().decode(BrowserSettings.self, from: #"{"appearance":"system"}"#.data(using: .utf8)!)
    #expect(old.archiveStaleTabsAfterHours == nil)
}
