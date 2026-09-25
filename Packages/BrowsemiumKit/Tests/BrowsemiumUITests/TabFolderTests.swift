import BrowsemiumCore
import BrowsemiumUI
import Foundation
import Testing
import BrowsemiumEngineKit

@Test @MainActor
func creatingAFolderStoresItInTheActiveSpace() {
    let model = BrowserWindowModel()
    let folderID = model.createFolder(named: "Research")

    #expect(model.session.folders.count == 1)
    #expect(model.activeFolders.map(\.id) == [folderID])
    #expect(model.folder(folderID)?.name == "Research")
    #expect(model.folder(folderID)?.isCollapsed == false)
    #expect(model.folder(folderID)?.spaceID == model.session.activeSpaceID)
}

@Test @MainActor
func creatingAFolderWithoutANameFallsBackToADefault() {
    let model = BrowserWindowModel()
    let folderID = model.createFolder(named: "   ")
    #expect(model.folder(folderID)?.name == "New Folder")
}

@Test @MainActor
func assigningTabsKeepsFolderMembersContiguous() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    model.newTab(url: URL(string: "https://two.example"))
    model.newTab(url: URL(string: "https://three.example"))
    let tabs = model.visibleTabs
    let folderID = model.createFolder(named: "Work")

    // File the middle tab; it must land next to the folder's run.
    model.assignTab(tabs[1].id, toFolder: folderID)
    #expect(model.tabs(inFolder: folderID).map(\.id) == [tabs[1].id])

    // A second member is appended to the folder's run, not left behind.
    model.assignTab(tabs[2].id, toFolder: folderID)
    let memberIDs = model.tabs(inFolder: folderID).map(\.id)
    #expect(memberIDs == [tabs[1].id, tabs[2].id])
    let order = model.visibleTabs.map(\.id)
    let firstIndex = order.firstIndex(of: tabs[1].id)
    let secondIndex = order.firstIndex(of: tabs[2].id)
    #expect(firstIndex != nil && secondIndex == firstIndex.map { $0 + 1 })
}

@Test @MainActor
func aTabMovedToAnotherFolderChangesMembership() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    let tabID = model.visibleTabs.last!.id
    let first = model.createFolder(named: "First")
    let second = model.createFolder(named: "Second")

    model.assignTab(tabID, toFolder: first)
    model.assignTab(tabID, toFolder: second)

    #expect(model.tabs(inFolder: first).isEmpty)
    #expect(model.tabs(inFolder: second).map(\.id) == [tabID])
    // The emptied folder is gone; the tab's new home stays.
    #expect(model.folder(first) == nil)
    #expect(model.folder(second) != nil)
}

@Test @MainActor
func removingTheLastTabDissolvesItsFolder() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    let tabID = model.visibleTabs.last!.id
    let folderID = model.createFolder(named: "Solo")
    model.assignTab(tabID, toFolder: folderID)

    model.assignTab(tabID, toFolder: nil)
    #expect(model.folder(folderID) == nil)
    #expect(model.session.tabs.first { $0.id == tabID }?.folderID == nil)
}

@Test @MainActor
func collapsingAFolderFlipsItsFlagAndSelectingInsideExpandsIt() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    let tabID = model.visibleTabs.last!.id
    let folderID = model.createFolder(named: "Collapsed")
    model.assignTab(tabID, toFolder: folderID)

    model.toggleFolderCollapsed(folderID)
    #expect(model.folder(folderID)?.isCollapsed == true)

    // Activating a member reveals it — the active tab is never hidden.
    model.selectTab(tabID)
    #expect(model.folder(folderID)?.isCollapsed == false)

    model.toggleFolderCollapsed(folderID)
    model.toggleFolderCollapsed(folderID)
    #expect(model.folder(folderID)?.isCollapsed == false)
}

@Test @MainActor
func pinningATabTakesItOutOfItsFolder() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    let tabID = model.visibleTabs.last!.id
    let folderID = model.createFolder(named: "Pins")
    model.assignTab(tabID, toFolder: folderID)

    model.togglePin(tabID)
    let pinned = model.session.tabs.first { $0.id == tabID }
    #expect(pinned?.isPinned == true)
    #expect(pinned?.folderID == nil)
    #expect(model.folder(folderID) == nil)

    model.togglePin(tabID)
    #expect(model.session.tabs.first { $0.id == tabID }?.folderID == nil)
}

@Test @MainActor
func pinnedTabsCannotBeFiledIntoAFolder() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    let tabID = model.visibleTabs.last!.id
    model.togglePin(tabID)
    let folderID = model.createFolder(named: "Refused")

    model.assignTab(tabID, toFolder: folderID)
    #expect(model.session.tabs.first { $0.id == tabID }?.folderID == nil)
    #expect(model.statusMessage == "Unpin the tab before adding it to a folder")
}

@Test @MainActor
func droppingATabNextToAFolderMemberJoinsTheFolder() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    model.newTab(url: URL(string: "https://two.example"))
    let tabs = model.visibleTabs
    let folderID = model.createFolder(named: "Drop")
    model.assignTab(tabs[1].id, toFolder: folderID)

    // Drag the loose tab onto the member: it adopts the folder.
    model.moveTab(tabs[0].id, before: tabs[1].id)
    #expect(model.session.tabs.first { $0.id == tabs[0].id }?.folderID == folderID)
    #expect(Set(model.tabs(inFolder: folderID).map(\.id)) == Set([tabs[0].id, tabs[1].id]))
}

@Test @MainActor
func droppingAMemberOntoALooseTabLeavesTheFolder() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    model.newTab(url: URL(string: "https://two.example"))
    let tabs = model.visibleTabs
    let folderID = model.createFolder(named: "Leave")
    model.assignTab(tabs[1].id, toFolder: folderID)

    model.moveTab(tabs[1].id, before: tabs[0].id)
    #expect(model.session.tabs.first { $0.id == tabs[1].id }?.folderID == nil)
    // The tab was the folder's only member; the folder is gone.
    #expect(model.folder(folderID) == nil)
}

@Test @MainActor
func closingTheLastTabOfAFolderRemovesTheFolder() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    model.newTab(url: URL(string: "https://two.example"))
    let tabs = model.visibleTabs
    let folderID = model.createFolder(named: "Doomed")
    model.assignTab(tabs[0].id, toFolder: folderID)
    model.assignTab(tabs[1].id, toFolder: folderID)

    model.closeTab(tabs[0].id)
    #expect(model.folder(folderID) != nil)

    model.closeTab(tabs[1].id)
    #expect(model.folder(folderID) == nil)
}

@Test @MainActor
func ungroupingAFolderKeepsItsTabsOpen() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    let tabID = model.visibleTabs.last!.id
    let folderID = model.createFolder(named: "Keep")
    model.assignTab(tabID, toFolder: folderID)

    model.ungroupFolder(folderID)
    #expect(model.folder(folderID) == nil)
    #expect(model.session.tabs.contains { $0.id == tabID })
    #expect(model.session.tabs.first { $0.id == tabID }?.folderID == nil)
}

@Test @MainActor
func closeFolderClosesEveryMember() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    model.newTab(url: URL(string: "https://two.example"))
    let tabs = model.visibleTabs
    let folderID = model.createFolder(named: "Bulk")
    model.assignTab(tabs[0].id, toFolder: folderID)
    model.assignTab(tabs[1].id, toFolder: folderID)

    model.closeFolder(folderID)
    #expect(model.folder(folderID) == nil)
    #expect(!model.session.tabs.contains { $0.id == tabs[0].id })
    #expect(!model.session.tabs.contains { $0.id == tabs[1].id })
}

@Test @MainActor
func renamingAFolderUpdatesItsName() {
    let model = BrowserWindowModel()
    let folderID = model.createFolder(named: "Old")
    model.renameFolder(folderID, to: "  New  ")
    #expect(model.folder(folderID)?.name == "New")
    model.renameFolder(folderID, to: "   ")
    #expect(model.folder(folderID)?.name == "New")
}

@Test @MainActor
func movingATabToAnotherGroupLeavesItsFolder() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    let tabID = model.visibleTabs.last!.id
    let folderID = model.createFolder(named: "Origin")
    model.assignTab(tabID, toFolder: folderID)

    let workID = model.createGroup(named: "Work")
    model.moveTab(tabID, toGroup: workID)

    let moved = model.session.tabs.first { $0.id == tabID }
    #expect(moved?.spaceID == workID)
    #expect(moved?.folderID == nil)
    #expect(model.folder(folderID) == nil)
}

@Test @MainActor
func deletingAGroupRemovesItsFolders() {
    let model = BrowserWindowModel()
    let workID = model.createGroup(named: "Work")
    model.newTab(url: URL(string: "https://work.example"))
    let folderID = model.createFolder(named: "Work Stuff")
    model.assignTab(model.visibleTabs.last!.id, toFolder: folderID)

    model.deleteGroup(workID)
    #expect(model.folder(folderID) == nil)
    #expect(model.session.folders.allSatisfy { $0.spaceID != workID })
}

@Test @MainActor
func foldersDoNotLeakAcrossSpaces() {
    let model = BrowserWindowModel()
    let personal = model.session.activeSpaceID
    let personalFolder = model.createFolder(named: "Personal Notes")

    let workID = model.createGroup(named: "Work")
    let workFolder = model.createFolder(named: "Work Notes")
    #expect(workID == model.session.activeSpaceID)

    #expect(model.activeFolders.map(\.id) == [workFolder])
    #expect(model.session.folders.count == 2)

    model.switchGroup(personal)
    #expect(model.activeFolders.map(\.id) == [personalFolder])
    #expect(model.session.activeSpaceID == personal)
}

@Test @MainActor
func foldersAndCollapseStatePersistAcrossReloads() async throws {
    let environment = BrowserEnvironment.inMemory()
    let model = BrowserWindowModel(environment: environment)
    model.newTab(url: URL(string: "https://research.example"))
    let tabID = model.visibleTabs.last!.id
    let folderID = model.createFolder(named: "Research")
    model.assignTab(tabID, toFolder: folderID)
    model.toggleFolderCollapsed(folderID)

    // Session writes are serialized off the main thread; poll until the
    // folder write lands.
    var restored: BrowserSessionState?
    for _ in 0..<50 {
        restored = try? environment.sessionRepository.load()
        if restored?.folders.isEmpty == false { break }
        try? await Task.sleep(for: .milliseconds(20))
    }
    let session = try #require(restored)
    let folder = try #require(session.folders.first)
    #expect(folder.id == folderID)
    #expect(folder.name == "Research")
    #expect(folder.isCollapsed == true)
    #expect(session.tabs.first { $0.id == tabID }?.folderID == folderID)
}

@Test @MainActor
func aStoredFolderInACollapsedStateIsRevealedAtLaunchWhenActive() async throws {
    let environment = BrowserEnvironment.inMemory()
    let space = BrowserSpace(name: "Personal")
    let folder = TabFolder(spaceID: space.id, name: "Hidden", isCollapsed: true)
    let tab = BrowserTab(
        spaceID: space.id,
        title: "Inside",
        lastCommittedURL: URL(string: "https://inside.example"),
        folderID: folder.id
    )
    try environment.sessionRepository.save(BrowserSessionState(
        spaces: [space],
        tabs: [tab],
        folders: [folder],
        activeSpaceID: space.id,
        activeTabID: tab.id
    ))

    let model = BrowserWindowModel(environment: environment)
    // The restored active tab is inside the collapsed folder, so launch
    // expands it instead of hiding the tab the user was last on.
    #expect(model.folder(folder.id)?.isCollapsed == false)
    #expect(model.tabs(inFolder: folder.id).map(\.id) == [tab.id])
}
