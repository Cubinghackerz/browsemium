import BrowsemiumCore
import BrowsemiumEngineKit
import BrowsemiumUI
import Foundation
import Testing

@MainActor
private struct FakeGrouper: TabGroupProposing {
    let build: @Sendable ([TabGroupCandidate]) -> [TabGroupProposal]
    func propose(_ candidates: [TabGroupCandidate]) async throws -> [TabGroupProposal] { build(candidates) }
}

/// A window with `count` loose tabs on the given hosts.
@MainActor
private func windowWithTabs(_ hosts: [String]) -> (BrowserWindowModel, StubEngine, [TabID]) {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    var ids = [model.session.activeTabID!]
    for _ in 1..<hosts.count { ids.append(model.newTab(url: nil)) }
    for (id, host) in zip(ids, hosts) {
        engine.emit(.committed(URL(string: "https://\(host)/page-\(id.rawValue.uuidString.prefix(4))")!), for: id)
        engine.emit(.finished(title: "Page on \(host)", url: URL(string: "https://\(host)/page-\(id.rawValue.uuidString.prefix(4))")!), for: id)
    }
    return (model, engine, ids)
}

@Test @MainActor
func withoutAModelTheSameSiteFallbackIsOffered() async throws {
    let (model, _, ids) = windowWithTabs(["github.com", "gist.github.com", "github.com", "example.com"])
    model.tabGrouping.modelGrouper = { nil }

    model.tabGrouping.begin()
    try #require(await waitFor { model.tabGrouping.phase != .working })

    #expect(model.tabGrouping.phase == .ready)
    #expect(model.tabGrouping.usedModel == false)
    #expect(model.tabGrouping.rows.count == 1)
    #expect(model.tabGrouping.rows[0].tabs.map(\.id) == [ids[0], ids[1], ids[2]])
}

@Test @MainActor
func modelSuggestionsArePreviewedAndNothingChangesUntilConfirmed() async throws {
    let (model, _, ids) = windowWithTabs(["a.example", "b.example", "c.example", "d.example"])
    model.tabGrouping.modelGrouper = {
        FakeGrouper { candidates in
            [TabGroupProposal(name: "Reading", tabIDs: [candidates[0].id, candidates[2].id])]
        }
    }
    model.tabGrouping.begin()
    try #require(await waitFor { model.tabGrouping.phase != .working })

    #expect(model.tabGrouping.usedModel)
    #expect(model.tabGrouping.isPresented)
    #expect(model.session.folders.isEmpty, "A suggestion must not create anything")

    model.tabGrouping.apply()
    #expect(model.session.folders.map(\.name) == ["Reading"])
    let folder = try #require(model.session.folders.first)
    #expect(model.session.tabs.first { $0.id == ids[0] }?.folderID == folder.id)
    #expect(model.session.tabs.first { $0.id == ids[2] }?.folderID == folder.id)
    #expect(model.session.tabs.first { $0.id == ids[1] }?.folderID == nil)
    #expect(model.tabGrouping.isPresented == false)
}

@Test @MainActor
func declinedRowsAndChangedTabsAreSkipped() async throws {
    let (model, _, ids) = windowWithTabs(["a.example", "b.example", "c.example", "d.example"])
    model.tabGrouping.modelGrouper = {
        FakeGrouper { candidates in
            [
                TabGroupProposal(name: "Kept", tabIDs: [candidates[0].id, candidates[1].id, candidates[2].id]),
                TabGroupProposal(name: "Declined", tabIDs: [candidates[3].id, candidates[0].id])
            ]
        }
    }
    model.tabGrouping.begin()
    try #require(await waitFor { model.tabGrouping.phase == .ready })

    model.tabGrouping.rows[1].isIncluded = false
    // Between suggestion and confirmation one tab is pinned and one closed.
    model.togglePin(ids[0])
    model.closeTab(ids[1])
    model.tabGrouping.apply()

    // "Kept" lost two of its three members, so it is below the two-tab
    // minimum and is not created; the declined row never is.
    #expect(model.session.folders.isEmpty)
}

@Test @MainActor
func aSpaceChangeCancelsTheApply() async throws {
    let (model, _, _) = windowWithTabs(["a.example", "a.example", "a.example"])
    model.tabGrouping.modelGrouper = { nil }
    model.tabGrouping.begin()
    try #require(await waitFor { model.tabGrouping.phase == .ready })

    let other = model.createGroup(named: "Other")
    #expect(model.session.activeSpaceID == other)
    model.tabGrouping.apply()

    #expect(model.session.folders.isEmpty)
    #expect(model.statusMessage?.contains("space changed") == true)
}

@Test @MainActor
func privateWindowsAndTinySpacesAreRefusedWithAnExplanation() {
    let (model, _, _) = windowWithTabs(["a.example", "b.example"])
    model.tabGrouping.begin()
    #expect(model.tabGrouping.isPresented == false)
    #expect(model.statusMessage?.contains("Not enough") == true)

    model.enterPrivateMode()
    model.tabGrouping.begin()
    #expect(model.tabGrouping.isPresented == false)
    #expect(model.statusMessage?.contains("private") == true)
}

@Test @MainActor
func pinnedAndFiledTabsAreNeverCandidates() async throws {
    let (model, _, ids) = windowWithTabs(["a.example", "a.example", "a.example", "a.example", "a.example"])
    model.togglePin(ids[0])
    let folder = model.createFolder(named: "Mine")
    model.assignTab(ids[1], toFolder: folder)
    model.tabGrouping.modelGrouper = { nil }

    model.tabGrouping.begin()
    try #require(await waitFor { model.tabGrouping.phase != .working })

    let offered = model.tabGrouping.rows.flatMap(\.tabs).map(\.id)
    #expect(!offered.contains(ids[0]))
    #expect(!offered.contains(ids[1]))
    #expect(Set(offered) == Set([ids[2], ids[3], ids[4]]))
}

@Test @MainActor
func closingDuplicatesKeepsTheActiveTabAndSkipsPinned() {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    let first = model.session.activeTabID!
    let second = model.newTab(url: nil)
    let third = model.newTab(url: nil)
    let page = URL(string: "https://example.com/a")!
    for id in [first, second, third] {
        engine.emit(.committed(page), for: id)
        engine.emit(.finished(title: "A", url: page), for: id)
    }
    model.selectTab(third)

    #expect(Set(model.duplicateTabIDs) == Set([first, second]))
    model.closeDuplicateTabs()

    #expect(model.session.tabs.map(\.id) == [third])
    #expect(model.session.activeTabID == third)
    model.closeDuplicateTabs()
    #expect(model.statusMessage == "No duplicate tabs")
}

@Test @MainActor
func theTwoNewCommandsAreInThePaletteAndDispatch() {
    let (model, _, _) = windowWithTabs(["a.example", "a.example"])
    #expect(model.paletteCommands.contains { $0.id == "group-tabs" })
    #expect(model.paletteCommands.contains { $0.id == "close-duplicates" })
    model.perform(.closeDuplicateTabs)
    #expect(model.session.tabs.count == 2) // different paths, so not duplicates
}
