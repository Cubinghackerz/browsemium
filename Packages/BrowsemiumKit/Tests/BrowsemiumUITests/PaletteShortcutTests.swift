import AppKit
import BrowsemiumCore
import Foundation
import Testing
@testable import BrowsemiumUI

@MainActor
private func makeModel() -> BrowserWindowModel {
    BrowserWindowModel(environment: .inMemory(engine: StubEngine()))
}

@Suite @MainActor struct PaletteShortcutTests {
    // MARK: Quick answer first

    @Test func aSumIsTheFirstRowAndReturnCopiesItWithoutNavigating() throws {
        let model = makeModel()
        let tabs = model.session.tabs.count

        let results = model.filteredCommands(query: "3.5*2")
        let first = try #require(results.first)
        #expect(first.kind == .answer)
        #expect(first.title == "= 7")
        // The search row is still there, just not first.
        #expect(results.dropFirst().contains { $0.kind == .action })

        let action = try #require(PaletteDispatch.action(
            for: first, modifier: .plain, context: model.paletteDispatchContext))
        model.perform(action)
        #expect(NSPasteboard.general.string(forType: .string) == "7")
        #expect(model.statusMessage == "Copied 7")
        #expect(model.session.tabs.count == tabs, "An answer must not open a tab")
    }

    @Test func ordinaryQueriesGetNoAnswerRow() {
        let model = makeModel()
        for text in ["swift concurrency", "github.com", "192.168.1.1", "2024-10-04", "42"] {
            #expect(!model.filteredCommands(query: text).contains { $0.kind == .answer }, "\(text)")
        }
    }

    @Test func aUnitConversionAnswersToo() {
        let model = makeModel()
        #expect(model.filteredCommands(query: "5 km to mi").first?.title == "= 3.106855961 mi")
    }

    // MARK: ⌘↩ opens in a new tab

    @Test func commandReturnOnAnOpenTabOpensItsPageAgainInANewTab() throws {
        let model = makeModel()
        let url = URL(string: "https://one.example/page")!
        let other = model.newTab(url: url)
        model.newTab(url: URL(string: "https://two.example/")!)
        let tabs = model.session.tabs.count

        let row = try #require(model.filteredCommands(query: "one.example").first { $0.command == .selectTab(other) })
        // Return switches to the tab; ⌘↩ is a different thing.
        #expect(PaletteDispatch.action(for: row, modifier: .plain, context: model.paletteDispatchContext)
                == .run(.selectTab(other)))
        let action = try #require(PaletteDispatch.action(
            for: row, modifier: .newTab, context: model.paletteDispatchContext))
        #expect(action == .run(.openURLInNewTab(url)))

        model.perform(action)
        #expect(model.session.tabs.count == tabs + 1)
        #expect(model.activeTab?.lastCommittedURL == url)
    }

    @Test func commandReturnKeepsPageAndSearchRowsAndIgnoresCommands() throws {
        let model = makeModel()
        let context = model.paletteDispatchContext

        let open = try #require(model.filteredCommands(query: "https://example.com/page").first)
        #expect(PaletteDispatch.action(for: open, modifier: .newTab, context: context) == .run(open.command))

        let search = try #require(model.filteredCommands(query: "swift concurrency").first)
        #expect(PaletteDispatch.action(for: search, modifier: .newTab, context: context) == .run(search.command))

        let command = try #require(model.filteredCommands(query: "").first { $0.kind == .command })
        #expect(PaletteDispatch.action(for: command, modifier: .newTab, context: context) == nil)
        #expect(PaletteDispatch.action(for: command, modifier: .split, context: context) == nil)
    }

    @Test func commandReturnOnATabWithNoPageDoesNothing() {
        let model = makeModel()
        let blank = BrowserPaletteCommand(
            id: "t", title: "Blank", shortcut: "", kind: .tab, command: .selectTab(TabID()))
        #expect(PaletteDispatch.action(for: blank, modifier: .newTab, context: model.paletteDispatchContext) == nil)
    }

    // MARK: ⇧↩ opens in split

    @Test func shiftReturnTilesAnOpenTabBesideTheCurrentOne() throws {
        let model = makeModel()
        model.newTab(url: URL(string: "https://one.example/")!)
        let other = model.visibleTabs.first { $0.id != model.session.activeTabID }!.id

        let row = try #require(model.filteredCommands(query: "").first { $0.command == .selectTab(other) })
        let action = try #require(PaletteDispatch.action(
            for: row, modifier: .split, context: model.paletteDispatchContext))
        #expect(action == .run(.openTabInSplit(other)))

        model.perform(action)
        #expect(model.isSplitViewActive)
        #expect(model.visiblePanes.contains { $0.tab.id == other })
    }

    @Test func shiftReturnOnAPageOpensItInANewTabWithTheOldOneBesideIt() throws {
        let model = makeModel()
        let before = model.session.activeTabID
        let url = URL(string: "https://split.example/article")!
        let row = BrowserPaletteCommand(
            id: "h", title: "Article", shortcut: "", kind: .history, command: .openURLInNewTab(url))

        let action = try #require(PaletteDispatch.action(
            for: row, modifier: .split, context: model.paletteDispatchContext))
        #expect(action == .openURLInSplit(url))

        model.perform(action)
        #expect(model.isSplitViewActive)
        #expect(model.activeTab?.lastCommittedURL == url)
        #expect(model.visiblePanes.contains { $0.tab.id == before }, "The tab you were on stays visible")
    }

    @Test func shiftReturnOnATabFromAnotherSpaceDoesNothing() throws {
        let model = makeModel()
        let home = model.session.activeSpaceID
        let elsewhere = model.newTab(url: URL(string: "https://home.example/")!)
        model.createGroup(named: "Work")
        #expect(model.session.activeSpaceID != home)

        let row = BrowserPaletteCommand(
            id: "t", title: "Home", shortcut: "", kind: .tab, command: .selectTab(elsewhere))
        #expect(PaletteDispatch.action(for: row, modifier: .split, context: model.paletteDispatchContext) == nil)
    }

    // MARK: The preview never calls a loaded tab asleep

    @Test func onlyHibernatedAndSuspendedTabsAreDescribedAsAsleep() {
        let all: [TabLifecycle] = [.metadataOnly, .loading, .active, .suspended, .hibernated, .crashed]
        for state in all {
            let note = PreviewNote.text(for: state, hasPage: true)
            let isAsleep = note.contains("asleep")
            #expect(isAsleep == (state == .suspended || state == .hibernated), "\(state): \(note)")
        }
        #expect(PreviewNote.text(for: .metadataOnly, hasPage: false) == "This tab is blank.")
        #expect(PreviewNote.text(for: .metadataOnly, hasPage: true) == "This tab has not loaded yet.")
        #expect(PreviewNote.symbol(for: .hibernated) == "moon.zzz")
        #expect(PreviewNote.symbol(for: .active) != "moon.zzz")
    }

    // MARK: Preview pane fits only when there is room

    @Test func theWidePaletteNeedsATabRowAndRoomForThePane() {
        let needed = PalettePreviewLayout.listWidth + PalettePreviewLayout.paneWidth + PalettePreviewLayout.margin * 2
        #expect(PalettePreviewLayout.showsPane(hasTabRow: true, availableWidth: needed))
        #expect(!PalettePreviewLayout.showsPane(hasTabRow: true, availableWidth: needed - 1))
        #expect(!PalettePreviewLayout.showsPane(hasTabRow: false, availableWidth: 4_000))
        #expect(PalettePreviewLayout.width(hasTabRow: false, availableWidth: 4_000) == 480)
        #expect(PalettePreviewLayout.width(hasTabRow: true, availableWidth: 4_000)
                == PalettePreviewLayout.listWidth + PalettePreviewLayout.paneWidth)
        // The minimum window the app allows still has room.
        #expect(PalettePreviewLayout.showsPane(hasTabRow: true, availableWidth: 860))
    }
}
