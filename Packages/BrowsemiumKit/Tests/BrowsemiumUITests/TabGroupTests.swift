import BrowsemiumCore
import BrowsemiumUI
import Foundation
import Testing
import BrowsemiumEngineKit

@Test @MainActor
func creatingAGroupMovesFocusToItsFirstTab() {
    let model = BrowserWindowModel()
    let originalSpace = model.session.activeSpaceID
    let groupID = model.createGroup(named: "Work")

    #expect(model.session.spaces.count == 2)
    #expect(model.session.activeSpaceID == groupID)
    #expect(model.visibleTabs.count == 1)
    #expect(model.visibleTabs.first?.spaceID == groupID)
    // The original group keeps its tabs; they are just not visible.
    #expect(model.session.tabs.contains { $0.spaceID == originalSpace })
}

@Test @MainActor
func switchingGroupsShowsOnlyThatGroupsTabs() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://personal.example"))
    let personalSpace = model.session.activeSpaceID
    let personalCount = model.visibleTabs.count

    let workID = model.createGroup(named: "Work")
    model.newTab(url: URL(string: "https://work.example"))
    #expect(model.visibleTabs.count == 2)

    model.switchGroup(personalSpace)
    #expect(model.session.activeSpaceID == personalSpace)
    #expect(model.visibleTabs.count == personalCount)
    #expect(model.visibleTabs.allSatisfy { $0.spaceID == personalSpace })

    model.switchGroup(workID)
    #expect(model.visibleTabs.count == 2)
    #expect(model.visibleTabs.allSatisfy { $0.spaceID == workID })
}

@Test @MainActor
func closingATabPicksANeighbourInsideItsOwnGroup() {
    let model = BrowserWindowModel()
    // Personal: two tabs.
    model.newTab(url: URL(string: "https://personal.example"))
    let personalSpace = model.session.activeSpaceID
    let personalTabs = model.visibleTabs

    // Work: two tabs.
    model.createGroup(named: "Work")
    model.newTab(url: URL(string: "https://work.example"))
    let workTabs = model.visibleTabs

    // Close the active work tab; the replacement must come from the work
    // group, never the personal one.
    model.closeTab(workTabs.last?.id)
    #expect(model.session.activeSpaceID != personalSpace)
    #expect(model.visibleTabs.allSatisfy { $0.spaceID != personalSpace })
    #expect(model.session.tabs.contains { $0.id == personalTabs.first?.id })
}

@Test @MainActor
func movingATabToAnotherGroupMovesItBetweenSets() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://personal.example"))
    let personalSpace = model.session.activeSpaceID
    let movingID = model.session.activeTabID!

    let workID = model.createGroup(named: "Work")
    model.moveTab(movingID, toGroup: workID)

    let moved = model.session.tabs.first { $0.id == movingID }
    #expect(moved?.spaceID == workID)
    // Moving the active tab follows it into its new group.
    #expect(model.session.activeSpaceID == workID)
    #expect(model.visibleTabs.contains { $0.id == movingID })
    #expect(model.session.tabs.contains { $0.spaceID == personalSpace })
}

@Test @MainActor
func deletingAGroupClosesItsTabsAndKeepsOthers() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://personal.example"))
    let personalSpace = model.session.activeSpaceID
    let personalTabIDs = Set(model.session.tabs.filter { $0.spaceID == personalSpace }.map(\.id))

    let workID = model.createGroup(named: "Work")
    model.newTab(url: URL(string: "https://work.example"))
    model.deleteGroup(workID)

    #expect(model.session.spaces.count == 1)
    #expect(model.session.activeSpaceID == personalSpace)
    #expect(model.session.tabs.allSatisfy { $0.spaceID == personalSpace })
    #expect(Set(model.session.tabs.map(\.id)) == personalTabIDs)
}

@Test @MainActor
func theLastGroupCannotBeDeleted() {
    let model = BrowserWindowModel()
    let onlySpace = model.session.activeSpaceID
    model.deleteGroup(onlySpace)
    #expect(model.session.spaces.count == 1)
    #expect(model.session.activeSpaceID == onlySpace)
}

@Test @MainActor
func groupsPersistAcrossReloads() async throws {
    let environment = BrowserEnvironment.inMemory()
    let model = BrowserWindowModel(environment: environment)
    model.createGroup(named: "Work")
    model.newTab(url: URL(string: "https://work.example"))

    // Session writes are serialized off the main thread; wait for the write.
    // Poll on the tab itself, not the space count: the group write can satisfy
    // `spaces == 2` one queue-turn before the tab write lands.
    var restored: BrowserSessionState?
    for _ in 0..<50 {
        restored = try? environment.sessionRepository.load()
        if restored?.tabs.contains(where: { $0.lastCommittedURL?.absoluteString == "https://work.example" }) == true { break }
        try? await Task.sleep(for: .milliseconds(20))
    }
    let session = try #require(restored)
    #expect(session.spaces.count == 2)
    #expect(session.spaces.contains { $0.name == "Work" })
    #expect(session.tabs.contains { $0.lastCommittedURL?.absoluteString == "https://work.example" })
}
