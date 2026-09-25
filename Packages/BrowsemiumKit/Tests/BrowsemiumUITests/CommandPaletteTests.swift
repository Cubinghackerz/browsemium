import BrowsemiumCore
import BrowsemiumData
import BrowsemiumUI
import Foundation
import Testing
import BrowsemiumEngineKit

@Test @MainActor
func paletteFindsTabsWithFuzzyMatching() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://github.com/pulls")!)
    let tab = model.visibleTabs.last!
    // The palette never lists the active tab, so the candidate has to be a
    // background tab.
    model.newTab(url: URL(string: "https://elsewhere.example")!)

    // Fuzzy, not substring: g…h…b matches github.com.
    let results = model.filteredCommands(query: "ghb")
    #expect(results.contains { $0.command == .selectTab(tab.id) })
}

@Test @MainActor
func paletteListsHistoryAndBookmarks() throws {
    let environment = BrowserEnvironment.inMemory()
    let model = BrowserWindowModel(environment: environment)
    _ = try environment.historyRepository.record(
        url: URL(string: "https://history.example/article")!,
        title: "Quantum Computing Notes"
    )
    _ = try environment.bookmarkRepository.add(
        url: URL(string: "https://bookmarks.example/saved")!,
        title: "Saved Reference"
    )
    model.refreshBookmarks()

    let historyResults = model.filteredCommands(query: "quantum")
    #expect(historyResults.contains { $0.kind == .history })

    let bookmarkResults = model.filteredCommands(query: "reference")
    #expect(bookmarkResults.contains { $0.kind == .bookmark })
}

@Test @MainActor
func paletteTopRowOpensURLsAndSearches() {
    let model = BrowserWindowModel()

    let urlResults = model.filteredCommands(query: "https://example.com/page")
    if case .openURLInNewTab(let url) = urlResults.first?.command {
        #expect(url.absoluteString == "https://example.com/page")
    } else {
        Issue.record("Expected a URL intent first, got \(String(describing: urlResults.first))")
    }

    let searchResults = model.filteredCommands(query: "swift concurrency")
    if case .searchFor(let query) = searchResults.first?.command {
        #expect(query == "swift concurrency")
    } else {
        Issue.record("Expected a search intent first, got \(String(describing: searchResults.first))")
    }
}

@Test @MainActor
func paletteSearchIntentOpensASearchTab() {
    let model = BrowserWindowModel()
    let before = model.session.tabs.count

    model.perform(.searchFor("swift concurrency"))

    #expect(model.session.tabs.count == before + 1)
    let url = model.activeTab?.lastCommittedURL?.absoluteString ?? ""
    #expect(url.contains("q=swift") || url.contains("swift"))
}

@Test @MainActor
func paletteOpenURLIntentOpensATab() {
    let model = BrowserWindowModel()
    let before = model.session.tabs.count
    let url = URL(string: "https://palette.example/open")!

    model.perform(.openURLInNewTab(url))

    #expect(model.session.tabs.count == before + 1)
    #expect(model.activeTab?.lastCommittedURL == url)
}

@Test @MainActor
func paletteOffersSpaceSwitching() {
    let model = BrowserWindowModel()
    let work = model.createGroup(named: "Work")
    let personal = model.session.spaces.first { $0.id != work }!.id
    model.switchGroup(personal)

    let results = model.filteredCommands(query: "switch work")
    let intent = results.first { $0.command == .switchSpace(work) }
    #expect(intent != nil)

    model.perform(.switchSpace(work))
    #expect(model.session.activeSpaceID == work)
}

@Test @MainActor
func paletteOffersMovingTheActiveTabToAFolder() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://notes.example")!)
    let activeTab = model.session.activeTabID!
    let folder = model.createFolder(named: "Research")

    let results = model.filteredCommands(query: "research")
    let intent = results.first { $0.command == .assignTabToFolder(activeTab, folder) }
    #expect(intent != nil)

    model.perform(.assignTabToFolder(activeTab, folder))
    #expect(model.session.tabs.first { $0.id == activeTab }?.folderID == folder)
}

@Test @MainActor
func paletteOffersSplittingWithAnotherTab() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example")!)
    model.newTab(url: URL(string: "https://two.example")!)
    let other = model.visibleTabs.first { $0.id != model.session.activeTabID }!.id

    let results = model.filteredCommands(query: "split")
    let intent = results.first { $0.command == .openTabInSplit(other) }
    #expect(intent != nil)

    model.perform(.openTabInSplit(other))
    #expect(model.isSplitViewActive)
    #expect(model.visiblePanes.contains { $0.tab.id == other })
}

@Test @MainActor
func paletteEmptyQueryShowsRecentTabsAndCommands() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://recent.example")!)

    let results = model.filteredCommands(query: "")

    #expect(results.contains { $0.kind == .tab })
    #expect(results.contains { $0.kind == .command })
    #expect(results.contains { $0.command == .newTab })
}

@Test @MainActor
func paletteResultsCarryKindAndSubtitle() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://github.com/pulls")!)
    model.newTab(url: URL(string: "https://elsewhere.example")!)

    let results = model.filteredCommands(query: "github")

    let tabResult = results.first { $0.kind == .tab }
    #expect(tabResult?.subtitle == "github.com")
}
