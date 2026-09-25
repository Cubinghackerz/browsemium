import AppKit
import BrowsemiumCore
import BrowsemiumUI
import Foundation
import Testing
import BrowsemiumEngineKit

// MARK: - Duplicate

@Test @MainActor
func duplicatingATabPlacesTheCopyRightAfterIt() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://a.example"))
    model.newTab(url: URL(string: "https://c.example"))
    let visibleIDs = model.visibleTabs.map(\.id)

    let copyID = model.duplicateTab(visibleIDs[1])

    let newIDs = model.visibleTabs.map(\.id)
    #expect(copyID != nil)
    #expect(newIDs == [visibleIDs[0], visibleIDs[1], copyID!, visibleIDs[2]])
    #expect(model.session.activeTabID == copyID)
    #expect(model.session.tabs.first { $0.id == copyID! }?.lastCommittedURL == URL(string: "https://a.example"))
}

@Test @MainActor
func duplicatingAFolderMemberKeepsTheCopyInTheFolder() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://a.example"))
    let source = model.session.activeTabID!
    let folderID = model.createFolder(named: "Reading")
    model.assignTab(source, toFolder: folderID)

    let copyID = model.duplicateTab(source)!

    #expect(model.session.tabs.first { $0.id == copyID }?.folderID == folderID)
    #expect(model.tabs(inFolder: folderID).count == 2)
}

@Test @MainActor
func duplicatingABlankTabJustOpensAnotherBlank() {
    let model = BrowserWindowModel()
    let source = model.session.activeTabID!

    let copyID = model.duplicateTab(source)

    #expect(copyID != nil)
    #expect(model.session.tabs.first { $0.id == copyID! }?.lastCommittedURL == nil)
    #expect(model.visibleTabs.count == 2)
}

// MARK: - Copy URL

@Test @MainActor
func copyingATabURLWritesThePasteboard() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://copy.example/page"))
    let tabID = model.session.activeTabID!

    model.copyURL(of: tabID)

    #expect(NSPasteboard.general.string(forType: .string) == "https://copy.example/page")
    #expect(model.statusMessage == "Link copied")
}

@Test @MainActor
func copyingABlankTabExplainsInsteadOfWriting() {
    let model = BrowserWindowModel()
    let blank = model.session.activeTabID!
    NSPasteboard.general.clearContents()

    model.copyURL(of: blank)

    #expect(NSPasteboard.general.string(forType: .string) == nil)
    #expect(model.statusMessage == "This tab has no address to copy")
}

// MARK: - Close others / close after

@Test @MainActor
func closingOtherTabsKeepsTheAnchorAndPinnedTabs() {
    let model = BrowserWindowModel()
    let anchor = model.session.activeTabID!
    model.newTab(url: URL(string: "https://b.example"))
    model.newTab(url: URL(string: "https://c.example"))
    let pinned = model.newTab(url: URL(string: "https://pinned.example"))
    model.togglePin(pinned)

    model.closeOtherTabs(around: anchor)

    let remaining = model.visibleTabs.map(\.id)
    #expect(remaining.contains(anchor))
    #expect(remaining.contains(pinned))
    #expect(remaining.count == 2)
    #expect(model.session.activeTabID == anchor)
}

@Test @MainActor
func closingTabsAfterLeavesEarlierOnesAlone() {
    let model = BrowserWindowModel()
    let first = model.session.activeTabID!
    model.newTab(url: URL(string: "https://b.example"))
    let middle = model.session.activeTabID!
    model.newTab(url: URL(string: "https://c.example"))
    let last = model.newTab(url: URL(string: "https://d.example"))
    model.togglePin(last)

    model.closeTabs(after: middle)

    let remaining = model.visibleTabs.map(\.id)
    // The tab after `middle` was closed; the pinned last tab survived.
    #expect(remaining == [first, middle, last])
    #expect(model.session.activeTabID == middle)
}

// MARK: - Strip navigation

@Test @MainActor
func numberSelectionPicksTheStripPositionAndNinePicksTheLast() {
    let model = BrowserWindowModel()
    let first = model.session.activeTabID!
    model.newTab(url: URL(string: "https://b.example"))
    model.newTab(url: URL(string: "https://c.example"))
    let third = model.session.activeTabID!

    model.selectTab(atStripIndex: 1)
    #expect(model.session.activeTabID == first)

    model.selectTab(atStripIndex: 9)
    #expect(model.session.activeTabID == third)

    // Out of range is a no-op, not a crash or a surprise switch.
    model.selectTab(atStripIndex: 0)
    model.selectTab(atStripIndex: 7)
    #expect(model.session.activeTabID == third)
}

@Test @MainActor
func cyclingWrapsAroundBothEnds() {
    let model = BrowserWindowModel()
    let first = model.session.activeTabID!
    model.newTab(url: URL(string: "https://b.example"))
    let second = model.session.activeTabID!

    model.selectAdjacentTab(forward: false)
    #expect(model.session.activeTabID == first)

    model.selectAdjacentTab(forward: false)
    #expect(model.session.activeTabID == second)
}

// MARK: - Hover peek

/// The debounce fires on the main actor, which parallel tests can keep busy —
/// a fixed sleep races it, and a freshly created task may wait several seconds
/// for its first slot. Allow scheduler contention without relaxing the 700 ms
/// product debounce; the deadline is wall-clock.
@MainActor
private func waitForPeek(in model: BrowserWindowModel, matching url: URL? = nil, timeout: Duration = .seconds(20)) async throws -> BrowserWindowModel.PeekState? {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let peek = model.peek, url == nil || peek.url == url { return peek }
        try await Task.sleep(for: .milliseconds(50))
    }
    return model.peek
}

@Test @MainActor
func aHoverPeekNeedsTheSettingAndARestedPointer() async throws {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    let tab = model.session.activeTabID!
    let link = URL(string: "https://linked.example/page")!

    // Off by default: hovering alone must never load a page.
    engine.emit(.linkHovered(link), for: tab)
    try await Task.sleep(for: .milliseconds(800))
    #expect(model.peek == nil)

    model.updateSettings { $0.linkPreviewOnHover = true }
    engine.emit(.linkHovered(link), for: tab)
    let peek = try #require(await waitForPeek(in: model, matching: link))
    #expect(peek.url == link)
}

@Test @MainActor
func movingOffTheLinkBeforeTheDelayOpensNothing() async throws {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    model.updateSettings { $0.linkPreviewOnHover = true }
    let tab = model.session.activeTabID!
    let link = URL(string: "https://linked.example/page")!

    engine.emit(.linkHovered(link), for: tab)
    try await Task.sleep(for: .milliseconds(200))
    engine.emit(.linkHovered(nil), for: tab)
    // Past the debounce window: the cancelled task must not have opened it.
    try await Task.sleep(for: .milliseconds(800))

    #expect(model.peek == nil)
}

@Test @MainActor
func hoverPeekRefusesNonPageSchemes() async throws {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    model.updateSettings { $0.linkPreviewOnHover = true }
    let tab = model.session.activeTabID!

    for scheme in ["javascript:alert(1)", "mailto:a@b.example", "file:///etc/passwd"] {
        engine.emit(.linkHovered(URL(string: scheme)!), for: tab)
        try await Task.sleep(for: .milliseconds(800))
        #expect(model.peek == nil)
    }
}

@Test @MainActor
func anOpenPeekIsNeverReplacedByHovering() async throws {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    model.updateSettings { $0.linkPreviewOnHover = true }
    let tab = model.session.activeTabID!
    let first = URL(string: "https://first.example")!
    let second = URL(string: "https://second.example")!

    engine.emit(.linkHovered(first), for: tab)
    let openPeek = try #require(await waitForPeek(in: model, matching: first))

    engine.emit(.linkHovered(second), for: tab)
    try await Task.sleep(for: .milliseconds(800))
    #expect(model.peek?.tabID == openPeek.tabID)
    #expect(model.peek?.url == first)
}

// MARK: - Settings compatibility

@Test
func settingsWrittenBeforeHoverPeekDecodeWithItOff() throws {
    let json = #"{"searchEngineTemplate":"https://google.com/search?q=%@"}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(BrowserSettings.self, from: json)
    #expect(decoded.linkPreviewOnHover == false)
}
