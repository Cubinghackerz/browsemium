import BrowsemiumCore
import Foundation
import Testing
@testable import BrowsemiumUI

@Suite struct SidebarLayoutTests {
    // MARK: Pinned grid

    @Test func pinnedGridSplitsIntoRowsOfThree() {
        #expect(PinnedGrid.rows([Int]()).isEmpty)
        #expect(PinnedGrid.rows([1]) == [[1]])
        #expect(PinnedGrid.rows([1, 2, 3]) == [[1, 2, 3]])
        #expect(PinnedGrid.rows([1, 2, 3, 4]) == [[1, 2, 3], [4]])
        #expect(PinnedGrid.rows(Array(1...7)) == [[1, 2, 3], [4, 5, 6], [7]])
    }

    @Test func pinnedGridKeepsOrderAndIgnoresNonsenseColumnCounts() {
        #expect(PinnedGrid.rows(["a", "b", "c", "d"], columns: 2) == [["a", "b"], ["c", "d"]])
        #expect(PinnedGrid.rows([1, 2], columns: 0).isEmpty)
        #expect(PinnedGrid.rows([1, 2], columns: -3).isEmpty)
    }

    // MARK: Space switcher

    private func space(
        _ name: String, locked: Bool = false, separate: Bool = false, color: String? = nil
    ) -> BrowserSpace {
        BrowserSpace(
            name: name, color: color, isLocked: locked,
            dataStoreID: separate ? UUID() : nil
        )
    }

    @Test func switcherMarksOnlyTheActiveSpaceAndKeepsOrder() {
        let spaces = [space("Home"), space("Work"), space("Play")]
        let items = SpaceSwitcher.items(spaces: spaces, active: spaces[1].id)
        #expect(items.map(\.name) == ["Home", "Work", "Play"])
        #expect(items.map(\.isActive) == [false, true, false])
    }

    @Test func lockBeatsSeparateDataBecauseItChangesWhatAClickDoes() {
        let spaces = [
            space("Plain"), space("Own data", separate: true),
            space("Locked", locked: true), space("Both", locked: true, separate: true),
        ]
        let glyphs = SpaceSwitcher.items(spaces: spaces, active: spaces[0].id).map(\.glyph)
        #expect(glyphs == [nil, .separateData, .lock, .lock])
        #expect(SpaceSwitcherItem.Glyph.lock.symbolName == "lock.fill")
        #expect(SpaceSwitcherItem.Glyph.separateData.symbolName == "person.crop.square")
    }

    @Test func accessibilityLabelNamesEveryStateNotJustColor() {
        let spaces = [space("Work", locked: true, separate: true), space("Home")]
        let items = SpaceSwitcher.items(spaces: spaces, active: spaces[0].id)
        let work = items[0].accessibilityLabel
        #expect(work.contains("Work"))
        #expect(work.contains("locked"))
        #expect(work.contains("own cookies"))
        #expect(work.contains("current"))
        #expect(items[1].accessibilityLabel == "Space Home")
    }

    @Test func switcherIsHiddenWithOneSpaceAndInPrivateWindows() {
        #expect(!SpaceSwitcher.isVisible(spaceCount: 1, isPrivate: false))
        #expect(!SpaceSwitcher.isVisible(spaceCount: 3, isPrivate: true))
        #expect(SpaceSwitcher.isVisible(spaceCount: 2, isPrivate: false))
    }

    // MARK: Motion

    /// Every animation in the sidebar, strip and new-tab page goes through
    /// `BrowserMotion`, which is what honours Reduce Motion. A literal
    /// `.easeInOut` or `.spring` would ignore the setting.
    @Test func sidebarAndStripAnimateOnlyThroughBrowserMotion() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<2 { root.deleteLastPathComponent() }
        root.deleteLastPathComponent()
        let browser = root.appendingPathComponent("Sources/BrowsemiumUI/Browser", isDirectory: true)
        let names = [
            "TabSidebar.swift", "BrowserTabStrip.swift", "SidebarComponents.swift",
            "NewTabView.swift", "TabFaviconView.swift",
        ]
        let pattern = try NSRegularExpression(pattern: #"(withAnimation|\.animation)\(\s*(\.|Animation)"#)
        for name in names {
            let text = try String(contentsOf: browser.appendingPathComponent(name), encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            #expect(pattern.firstMatch(in: text, range: range) == nil, "\(name) has a literal animation")
        }
    }
}
