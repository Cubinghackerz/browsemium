import BrowsemiumCore
import BrowsemiumData
import BrowsemiumEngineKit
import BrowsemiumUI
import Foundation
import Testing
@testable import BrowsemiumUI

@MainActor
private func makeModel() -> (BrowserWindowModel, StubEngine) {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    model.startObservingRuntime()
    return (model, engine)
}

@Test @MainActor
func aSeparateGroupGetsItsOwnStoreAndAnOrdinaryGroupDoesNot() throws {
    let (model, engine) = makeModel()
    let ordinaryTab = model.session.activeTabID!
    let separate = model.createGroup(named: "Client", separateData: true)
    let separateTab = model.session.activeTabID!
    let plain = model.createGroup(named: "Plain")
    let plainTab = model.session.activeTabID!

    let store = try #require(model.session.spaces.first { $0.id == separate }?.dataStoreID)
    #expect(engine.resolvedDataStore(for: separateTab) == store)
    #expect(engine.resolvedDataStore(for: ordinaryTab) == nil)
    #expect(engine.resolvedDataStore(for: plainTab) == nil)
    #expect(model.session.spaces.first { $0.id == plain }?.dataStoreID == nil)
    #expect(model.containerStoreIDs == [store])
}

@Test @MainActor
func eachSeparateGroupHasADifferentStore() {
    let (model, _) = makeModel()
    _ = model.createGroup(named: "A", separateData: true)
    _ = model.createGroup(named: "B", separateData: true)
    let stores = model.containerStoreIDs
    #expect(stores.count == 2)
    #expect(Set(stores).count == 2)
    #expect(!stores.contains(model.environment.activeProfile.dataStoreUUID))
}

@Test @MainActor
func privateWindowsNeverUseAContainer() {
    let (model, engine) = makeModel()
    model.enterPrivateMode()
    let created = model.createGroup(named: "Nope", separateData: true)
    #expect(model.session.spaces.first { $0.id == created }?.dataStoreID == nil)
    #expect(engine.resolvedDataStore(for: model.session.activeTabID!) == nil)
}

@Test @MainActor
func renamingKeepsTheStoreAndTheLock() throws {
    let (model, _) = makeModel()
    let separate = model.createGroup(named: "Client", separateData: true)
    let store = try #require(model.session.spaces.first { $0.id == separate }?.dataStoreID)
    model.switchGroup(model.session.spaces[0].id)
    model.setSpaceLocked(separate, locked: true)

    model.renameGroup(separate, to: "Renamed")

    let space = try #require(model.session.spaces.first { $0.id == separate })
    #expect(space.name == "Renamed")
    #expect(space.dataStoreID == store)
    #expect(space.isLocked)
}

@Test @MainActor
func theStoreSurvivesRelaunch() throws {
    let environment = BrowserEnvironment.inMemory(engine: StubEngine())
    let model = BrowserWindowModel(environment: environment)
    let separate = model.createGroup(named: "Client", separateData: true)
    let store = try #require(model.session.spaces.first { $0.id == separate }?.dataStoreID)
    try environment.sessionRepository.save(model.session)

    let restored = try #require(try environment.sessionRepository.load())
    #expect(restored.spaces.first { $0.id == separate }?.dataStoreID == store)
    #expect(restored.spaces.first { $0.id != separate }?.dataStoreID == nil)

    // Saving again (as every session save does) must not rewrite the store.
    try environment.sessionRepository.save(restored)
    #expect(try environment.sessionRepository.load()?.spaces.first { $0.id == separate }?.dataStoreID == store)
}

@Test @MainActor
func olderSessionsWithoutAStoreStillDecode() throws {
    let json = #"{"id":{"rawValue":"11111111-1111-1111-1111-111111111111"},"name":"Old","createdAt":0}"#.data(using: .utf8)!
    let space = try JSONDecoder().decode(BrowserSpace.self, from: json)
    #expect(space.dataStoreID == nil)
    #expect(space.isLocked == false)
}

@Test @MainActor
func movingATabBetweenStoresReleasesItSoItReloadsInTheNewOne() throws {
    let (model, engine) = makeModel()
    let personal = model.session.activeSpaceID
    let tab = model.session.activeTabID!
    engine.emit(.committed(URL(string: "https://app.example/")!), for: tab)
    engine.emit(.finished(title: "App", url: URL(string: "https://app.example/")!), for: tab)
    let separate = model.createGroup(named: "Client", separateData: true)
    model.switchGroup(personal)
    #expect(engine.discardedTabs.isEmpty)

    model.moveTab(tab, toGroup: separate)

    #expect(engine.discardedTabs == [tab])
    #expect(model.tabURLs[tab]?.absoluteString == "https://app.example/")
    #expect(model.session.tabs.first { $0.id == tab }?.spaceID == separate)
    #expect(engine.resolvedDataStore(for: tab) == model.session.spaces.first { $0.id == separate }?.dataStoreID)
}

@Test @MainActor
func movingBetweenSpacesThatShareAStoreKeepsTheTabLoaded() {
    let (model, engine) = makeModel()
    let personal = model.session.activeSpaceID
    let tab = model.session.activeTabID!
    let other = model.createGroup(named: "Other")
    model.switchGroup(personal)

    model.moveTab(tab, toGroup: other)

    #expect(engine.discardedTabs.isEmpty)
}

@Test @MainActor
func deletingASeparateGroupWipesAndRemovesItsStore() async throws {
    let (model, engine) = makeModel()
    let personal = model.session.activeSpaceID
    let separate = model.createGroup(named: "Client", separateData: true)
    let store = try #require(model.session.spaces.first { $0.id == separate }?.dataStoreID)
    model.switchGroup(personal)

    model.deleteGroup(separate)
    try #require(await waitFor { engine.removedProfileDataStores.contains(store) })

    #expect(engine.wipedDataStores.contains(store))
    #expect(model.containerStoreIDs.isEmpty)
}

@Test @MainActor
func aStoreThatCannotBeRemovedYetIsRetriedLater() async throws {
    let (model, engine) = makeModel()
    let personal = model.session.activeSpaceID
    let separate = model.createGroup(named: "Client", separateData: true)
    let store = try #require(model.session.spaces.first { $0.id == separate }?.dataStoreID)
    model.switchGroup(personal)
    engine.profileDataStoreRemovalError = NSError(domain: "WebKit", code: 1)

    model.deleteGroup(separate)
    let key = "browsemium.pendingContainerRemovals.\(model.environment.activeProfile.id.uuidString)"
    try #require(await waitFor { model.environment.userDefaults.stringArray(forKey: key)?.contains(store.uuidString) == true })
    #expect(engine.wipedDataStores.contains(store), "The data is cleared even when the store cannot be removed")

    engine.profileDataStoreRemovalError = nil
    model.retryPendingContainerRemovals()
    try #require(await waitFor { engine.removedProfileDataStores.contains(store) })
    try #require(await waitFor { (model.environment.userDefaults.stringArray(forKey: key) ?? []).isEmpty })
}

@Test @MainActor
func clearingCookiesAndCacheCoversEverySeparateGroup() async throws {
    let (model, engine) = makeModel()
    _ = model.createGroup(named: "A", separateData: true)
    _ = model.createGroup(named: "B", separateData: true)
    let expected = Set([model.environment.activeProfile.dataStoreUUID] + model.containerStoreIDs)

    model.clearCookiesAndSiteData()
    try #require(await waitFor { Set(engine.clearedSiteDataStores) == expected })

    model.clearCache()
    try #require(await waitFor { Set(engine.clearedCacheStores) == expected })
}

@Test @MainActor
func tabsInASeparateGroupAreNotVisibleToExtensions() {
    let personal = BrowserSpace(name: "Personal")
    let separate = BrowserSpace(name: "Client", dataStoreID: UUID())
    let locked = BrowserSpace(name: "Locked", isLocked: true)
    let tabs = [
        BrowserTab(spaceID: personal.id, title: "a", position: 0),
        BrowserTab(spaceID: separate.id, title: "b", position: 1),
        BrowserTab(spaceID: locked.id, title: "c", position: 2)
    ]
    let session = BrowserSessionState(
        spaces: [personal, separate, locked], tabs: tabs, folders: [],
        activeSpaceID: personal.id, activeTabID: tabs[0].id
    )
    let visible = ExtensionTabAccessPolicy.tabIDs(in: session, unlocked: [])
    #expect(visible == [tabs[0].id])
    // Unlocking a locked ordinary space exposes it; a separate group stays hidden.
    #expect(ExtensionTabAccessPolicy.tabIDs(in: session, unlocked: [locked.id, separate.id]) == [tabs[0].id, tabs[2].id])
}
