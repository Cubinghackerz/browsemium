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
