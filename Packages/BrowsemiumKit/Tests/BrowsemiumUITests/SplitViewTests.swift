import BrowsemiumCore
import BrowsemiumUI
import Foundation
import Testing
import BrowsemiumEngineKit

@Test @MainActor
func togglingSplitViewTilesTheMostRecentOtherTab() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    model.newTab(url: URL(string: "https://two.example"))
    let active = model.session.activeTabID

    let tiled = model.toggleSplitView()

    #expect(model.isSplitViewActive)
    #expect(model.visiblePanes.count == 2)
    #expect(model.visiblePanes.first?.pane == model.paneID)
    #expect(model.visiblePanes.first?.tab.id == active)
    #expect(tiled != nil)
    #expect(tiled != active)
    #expect(model.visiblePanes.last?.tab.id == tiled)
    // Splitting is a view change, never a session change.
    #expect(model.session.activeTabID == active)
}

@Test @MainActor
func togglingSplitViewAgainClosesItAndKeepsTabsOpen() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    model.newTab(url: URL(string: "https://two.example"))
    let tabIDs = Set(model.session.tabs.map(\.id))

    model.toggleSplitView()
    model.toggleSplitView()

    #expect(!model.isSplitViewActive)
    #expect(model.visiblePanes.count == 1)
    #expect(Set(model.session.tabs.map(\.id)) == tabIDs)
    #expect(model.activePaneID == model.paneID)
}

@Test @MainActor
func splittingWithASingleTabOpensAFreshTabBesideIt() {
    let model = BrowserWindowModel()
    let original = model.session.activeTabID

    let fresh = model.toggleSplitView()

    #expect(model.isSplitViewActive)
    #expect(fresh != original)
    #expect(model.visiblePanes.count == 2)
    #expect(model.visiblePanes.first?.tab.id == fresh)
    #expect(model.visiblePanes.last?.tab.id == original)
}

@Test @MainActor
func tiledTabsAreMarkedInSplitUntilTheSplitCloses() {
    let model = BrowserWindowModel()
    let first = model.newTab(url: URL(string: "https://one.example"))
    let second = model.newTab(url: URL(string: "https://two.example"))
    #expect(!model.isTabInSplit(first))
    #expect(!model.isTabInSplit(second))

    model.toggleSplitView()

    #expect(model.isTabInSplit(second))
    #expect(model.visiblePanes.contains { model.isTabInSplit($0.tab.id) })
    #expect(model.visiblePanes.allSatisfy { model.isTabInSplit($0.tab.id) })

    model.closeSplitView()

    #expect(!model.isTabInSplit(first))
    #expect(!model.isTabInSplit(second))
}

@Test @MainActor
func focusingASplitPaneMakesItsTabActiveWithoutSwappingPanes() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    model.newTab(url: URL(string: "https://two.example"))
    model.toggleSplitView()
    let primaryTab = model.visiblePanes.first!.tab.id
    let secondary = model.visiblePanes.last!
    #expect(model.activePaneID == model.paneID)

    model.focusPane(secondary.pane)

    #expect(model.activePaneID == secondary.pane)
    #expect(model.session.activeTabID == secondary.tab.id)
    // The panes keep their positions; nothing swaps.
    #expect(model.visiblePanes.first?.tab.id == primaryTab)
    #expect(model.visiblePanes.last?.tab.id == secondary.tab.id)
}

@Test @MainActor
func aNewTabInTheFocusedSplitPaneReplacesOnlyThatPane() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    model.newTab(url: URL(string: "https://two.example"))
    model.toggleSplitView()
    let primaryTab = model.visiblePanes.first!.tab.id
    let secondary = model.visiblePanes.last!
    model.focusPane(secondary.pane)

    let fresh = model.newTab(url: URL(string: "https://three.example"))

    #expect(model.visiblePanes.first?.tab.id == primaryTab)
    #expect(model.visiblePanes.last?.tab.id == fresh)
    #expect(model.session.activeTabID == fresh)
}

@Test @MainActor
func selectingATabAlreadyTiledInAPaneFocusesThatPane() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    model.newTab(url: URL(string: "https://two.example"))
    model.toggleSplitView()
    let primaryTab = model.visiblePanes.first!.tab.id
    let secondary = model.visiblePanes.last!
    model.focusPane(secondary.pane)

    // The primary pane's tab is picked from the strip: focus returns to the
    // primary pane instead of the secondary pane stealing the tab.
    model.selectTab(primaryTab)

    #expect(model.activePaneID == model.paneID)
    #expect(model.session.activeTabID == primaryTab)
    #expect(model.visiblePanes.last?.tab.id == secondary.tab.id)
}

@Test @MainActor
func closingATabRemovesItsSplitPane() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    model.newTab(url: URL(string: "https://two.example"))
    model.toggleSplitView()
    let secondary = model.visiblePanes.last!

    model.closeTab(secondary.tab.id)

    #expect(!model.isSplitViewActive)
    #expect(model.visiblePanes.count == 1)
    #expect(model.visiblePanes.first?.tab.id == model.session.activeTabID)
}

@Test @MainActor
func closingASplitPaneKeepsItsTabOpen() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    model.newTab(url: URL(string: "https://two.example"))
    model.toggleSplitView()
    let secondary = model.visiblePanes.last!

    model.closeSplitPane(secondary.pane)

    #expect(!model.isSplitViewActive)
    #expect(model.session.tabs.contains { $0.id == secondary.tab.id })
}

@Test @MainActor
func closingThePrimaryTabWhileASplitIsFocusedCollapsesTheDuplicate() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    model.newTab(url: URL(string: "https://two.example"))
    model.toggleSplitView()
    let primaryTab = model.visiblePanes.first!.tab.id
    let secondary = model.visiblePanes.last!
    model.focusPane(secondary.pane)

    // The focused pane's tab survives as the only pane content.
    model.closeTab(primaryTab)

    #expect(model.session.activeTabID == secondary.tab.id)
    #expect(model.visiblePanes.count == 1)
    #expect(model.visiblePanes.first?.tab.id == secondary.tab.id)
    #expect(!model.isSplitViewActive)
}

@Test @MainActor
func switchingGroupsClosesSplitView() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    model.newTab(url: URL(string: "https://two.example"))
    model.toggleSplitView()
    let personal = model.session.activeSpaceID
    #expect(model.isSplitViewActive)

    let work = model.createGroup(named: "Work")
    #expect(!model.isSplitViewActive)

    model.switchGroup(personal)
    #expect(!model.isSplitViewActive)
    #expect(model.visiblePanes.count == 1)
    #expect(model.session.activeSpaceID == personal)
    // The tabs are untouched.
    #expect(model.session.tabs.contains { $0.spaceID == work } || work == model.session.activeSpaceID)
}

@Test @MainActor
func movingASplitTabToAnotherGroupRemovesItsPane() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    model.newTab(url: URL(string: "https://two.example"))
    model.toggleSplitView()
    let secondary = model.visiblePanes.last!
    let work = model.createGroup(named: "Work")
    model.switchGroup(work)
    model.switchGroup(secondary.tab.spaceID)

    model.moveTab(secondary.tab.id, toGroup: work)

    #expect(!model.isSplitViewActive)
    #expect(model.visiblePanes.count == 1)
}

@Test @MainActor
func promotingAPeekIntoSplitViewShowsBothPages() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://origin.example"))
    let origin = model.session.activeTabID

    model.openPeek(url: URL(string: "https://preview.example/side-by-side")!)
    let promoted = model.promotePeekToSplitView()

    #expect(model.peek == nil)
    #expect(promoted != nil)
    #expect(model.isSplitViewActive)
    #expect(model.visiblePanes.count == 2)
    // The previewed page becomes the focused pane; the page it was opened
    // from is tiled beside it.
    #expect(model.visiblePanes.first?.tab.id == promoted)
    #expect(model.visiblePanes.last?.tab.id == origin)
}

@Test @MainActor
func splitPanesAreCappedAtFour() {
    let model = BrowserWindowModel()
    for index in 0..<6 {
        model.newTab(url: URL(string: "https://tab\(index).example"))
    }
    let tabs = model.visibleTabs.filter { $0.id != model.session.activeTabID }

    for tab in tabs.prefix(4) {
        model.openInSplitView(tab.id)
    }

    #expect(model.visiblePanes.count <= 4)
    #expect(model.paneOrder.count <= 4)
}

@Test @MainActor
func openingInSplitViewTwiceFocusesInsteadOfDuplicating() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    model.newTab(url: URL(string: "https://two.example"))
    let tiled = model.visibleTabs.first { $0.id != model.session.activeTabID }!.id

    model.openInSplitView(tiled)
    let paneCount = model.paneOrder.count
    #expect(model.isSplitViewActive)
    // Tiling a tab does not steal focus from the pane being read.
    #expect(model.activePaneID == model.paneID)

    model.openInSplitView(tiled)

    #expect(model.paneOrder.count == paneCount)
    #expect(model.activePaneID != model.paneID)
    #expect(model.session.activeTabID == tiled)
}

// MARK: - Pane deduplication regressions

@Test @MainActor
func closingTheFocusedPaneTabFocusesThePaneAlreadyShowingTheFallback() {
    let model = BrowserWindowModel()
    let tabA = model.session.activeTabID!
    model.newTab(url: URL(string: "https://two.example"))
    model.newTab(url: URL(string: "https://three.example"))
    let tabC = model.session.activeTabID!
    let tabB = model.visibleTabs.first { $0.lastCommittedURL?.host == "two.example" }!.id
    // Tile A beside the primary, then B beside that: [primary=C, pane2=A,
    // pane3=B]. Focus lands on the middle pane.
    model.openInSplitView(tabA)
    model.openInSplitView(tabB)
    let pane2 = model.visiblePanes[1].pane
    let pane3 = model.visiblePanes[2].pane
    model.focusPane(pane2)
    #expect(model.session.activeTabID == tabA)

    // Closing the focused tab falls back to its strip neighbour B — which is
    // already tiled in pane3. The pane showing B must take the focus, not
    // have B cloned into the primary pane alongside C.
    model.closeTab(tabA)

    let shown = model.visiblePanes.map(\.tab.id)
    #expect(Set(shown).count == shown.count)
    #expect(model.paneTabIDs[model.paneID] == tabC)
    #expect(model.paneTabIDs[pane3] == tabB)
    #expect(model.activePaneID == pane3)
    #expect(model.session.activeTabID == tabB)
}

@Test @MainActor
func movingThePrimaryPanesTabToAnotherSpaceFoldsTheFocusedPaneIn() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    model.newTab(url: URL(string: "https://two.example"))
    model.toggleSplitView()
    let primaryTab = model.visiblePanes.first!.tab.id
    let secondary = model.visiblePanes.last!
    model.focusPane(secondary.pane)
    let work = model.createGroup(named: "Work")
    model.switchGroup(secondary.tab.spaceID)

    // The primary pane's tab moves away while a secondary pane is focused:
    // the focused pane folds into the primary rather than the primary pane
    // rendering a tab that now belongs to another space.
    model.moveTab(primaryTab, toGroup: work)

    #expect(model.visiblePanes.count == 1)
    #expect(model.visiblePanes.first?.tab.id == secondary.tab.id)
    #expect(model.activePaneID == model.paneID)
    #expect(model.session.activeTabID == secondary.tab.id)
    #expect(model.session.tabs.first { $0.id == primaryTab }?.spaceID == work)
}

// MARK: - Peek during split view (⌘-click regressions)

@Test @MainActor
func aCommandClickPeekOpensWhileSplitViewIsActive() {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    model.newTab(url: URL(string: "https://one.example"))
    model.newTab(url: URL(string: "https://two.example"))
    model.toggleSplitView()
    #expect(model.isSplitViewActive)

    // ⌘-click inside the focused (primary) pane.
    let primaryTab = model.visiblePanes.first!.tab.id
    let url = URL(string: "https://preview.example/article")!
    engine.emit(.requestedPeek(url), for: primaryTab)

    #expect(model.peek != nil)
    #expect(model.peek?.url == url)
}

@Test @MainActor
func aCommandClickPeekOpensFromASecondarySplitPane() {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    model.newTab(url: URL(string: "https://one.example"))
    model.newTab(url: URL(string: "https://two.example"))
    model.toggleSplitView()
    let secondaryTab = model.visiblePanes.last!.tab.id

    // ⌘-click inside the pane that is not focused.
    let url = URL(string: "https://preview.example/other")!
    engine.emit(.requestedPeek(url), for: secondaryTab)

    #expect(model.peek != nil)
    #expect(model.peek?.url == url)
}

// MARK: - Drag-to-edge splitting

@Test @MainActor
func droppingATabOnAnEdgeTilesItBesideTheFocusedPane() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    model.newTab(url: URL(string: "https://two.example"))
    let other = model.visibleTabs.first { $0.id != model.session.activeTabID }!.id

    model.beginTabDrag()
    #expect(model.isTabDragActive)
    model.dropTabOnSplitEdge(other)

    #expect(model.isSplitViewActive)
    #expect(model.visiblePanes.last?.tab.id == other)
    #expect(!model.isTabDragActive)
}

@Test @MainActor
func droppingTheFocusedPanesOwnTabOnAnEdgeSplitsWithAnotherTab() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    model.newTab(url: URL(string: "https://two.example"))
    let active = model.session.activeTabID!

    model.dropTabOnSplitEdge(active)

    #expect(model.isSplitViewActive)
    // The active tab stays in the focused pane; something else is tiled.
    #expect(model.paneTabIDs[model.paneID] == active)
    #expect(model.visiblePanes.count == 2)
}

@Test @MainActor
func aTabDragThatEndsOutsideAnyTargetClearsTheFlag() async throws {
    let model = BrowserWindowModel()
    model.beginTabDrag()
    #expect(model.isTabDragActive)

    model.endTabDrag()
    #expect(!model.isTabDragActive)
}
