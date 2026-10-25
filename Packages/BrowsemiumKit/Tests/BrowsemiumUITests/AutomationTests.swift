import BrowsemiumCore
import BrowsemiumEngineKit
import BrowsemiumUI
import Foundation
import Testing

@MainActor
private final class AutomationAuthenticator: SpaceUnlockAuthenticating {
    var grants = true
    private(set) var reasons: [String] = []
    func authenticate(reason: String) async -> Bool {
        reasons.append(reason)
        return grants
    }
}

@MainActor
private func newModel() -> (BrowserWindowModel, StubEngine) {
    let engine = StubEngine()
    return (BrowserWindowModel(environment: .inMemory(engine: engine)), engine)
}

// MARK: - browsemium:// links

@Test @MainActor
func anOpenLinkOpensANewTab() {
    let (model, _) = newModel()
    let before = model.session.tabs.count
    model.performURLCommand(URL(string: "browsemium://open?url=https%3A%2F%2Fexample.com%2Fa")!)
    #expect(model.session.tabs.count == before + 1)
    #expect(model.tabURLs[model.session.activeTabID!]?.absoluteString == "https://example.com/a")
}

@Test @MainActor
func aSearchLinkSearchesWithTheChosenEngine() {
    let (model, _) = newModel()
    model.selectSearchEngine(.duckDuckGo)
    let before = model.session.tabs.count
    model.performURLCommand(URL(string: "browsemium://search?q=swift%20actors")!)
    #expect(model.session.tabs.count == before + 1)
    let url = model.tabURLs[model.session.activeTabID!]
    #expect(url?.host == "duckduckgo.com")
    #expect(url?.absoluteString.contains("swift") == true)
}

@Test @MainActor
func aSpaceLinkSwitchesByNameIgnoringCase() {
    let (model, _) = newModel()
    let personal = model.session.activeSpaceID
    let work = model.createGroup(named: "Work")
    model.switchGroup(personal)

    model.performURLCommand(URL(string: "browsemium://space?name=wORK")!)
    #expect(model.session.activeSpaceID == work)

    model.performURLCommand(URL(string: "browsemium://space?name=Nope")!)
    #expect(model.session.activeSpaceID == work)
    #expect(model.statusMessage == "There is no space named “Nope”.")
}

@Test @MainActor
func aSpaceLinkCannotBypassALockedSpace() async throws {
    let (model, _) = newModel()
    let personal = model.session.activeSpaceID
    let secret = model.createGroup(named: "Secret")
    model.switchGroup(personal)
    model.setSpaceLocked(secret, locked: true)
    let authenticator = AutomationAuthenticator()
    authenticator.grants = false
    model.spaceUnlockAuthenticator = authenticator

    model.performURLCommand(URL(string: "browsemium://space?name=Secret")!)
    try #require(await waitFor { model.statusMessage == "“Secret” stayed locked" })

    #expect(model.session.activeSpaceID == personal)
    #expect(authenticator.reasons == ["Unlock “Secret”"])
}

@Test @MainActor
func linksThatAreNotNavigationAreReportedAndIgnored() {
    let (model, _) = newModel()
    let before = model.session.tabs.count
    model.performURLCommand(URL(string: "browsemium://open?url=javascript%3Aalert(1)")!)
    #expect(model.session.tabs.count == before)
    #expect(model.statusMessage == AppURLCommand.ParseError.invalidURL.message)

    model.performURLCommand(URL(string: "browsemium://ask?q=hello")!)
    #expect(model.statusMessage == AppURLCommand.ParseError.unknownCommand("ask").message)
}

@Test @MainActor
func spaceLinksAreRefusedInAPrivateWindow() {
    let (model, _) = newModel()
    model.enterPrivateMode()
    model.performURLCommand(URL(string: "browsemium://space?name=Private")!)
    #expect(model.statusMessage == "Spaces are not available in a private window.")
}

// MARK: - What automation may read

@Test @MainActor
func openTabsOmitPrivateWindowsAndLockedSpaces() {
    let registry = LiveWindowIndex()
    let (ordinary, ordinaryEngine) = newModel()
    let personal = ordinary.session.activeSpaceID
    let first = ordinary.session.activeTabID!
    ordinaryEngine.emit(.committed(URL(string: "https://user:pw@example.com/page?token=1#frag")!), for: first)
    ordinaryEngine.emit(.finished(title: "Example", url: URL(string: "https://user:pw@example.com/page?token=1#frag")!), for: first)
    let secret = ordinary.createGroup(named: "Secret")
    let hiddenTab = ordinary.session.activeTabID!
    ordinary.switchGroup(personal)
    ordinary.setSpaceLocked(secret, locked: true)

    let (privateModel, _) = newModel()
    privateModel.enterPrivateMode()
    registry.register(ordinary)
    registry.register(privateModel)

    let tabs = AppAutomation.openTabs(registry: registry)
    #expect(tabs.map(\.title) == ["Example"])
    #expect(!tabs.contains { $0.id == hiddenTab.rawValue.uuidString })
    // Credentials and fragment are gone; the rest of the address stays.
    #expect(tabs.first?.url?.absoluteString == "https://example.com/page?token=1")
    #expect(tabs.first?.spaceName == "Personal")
}

@Test @MainActor
func theCurrentPageComesFromTheFocusedOrdinaryWindow() {
    let registry = LiveWindowIndex()
    let (first, firstEngine) = newModel()
    let (second, secondEngine) = newModel()
    firstEngine.emit(.committed(URL(string: "https://first.example/")!), for: first.session.activeTabID!)
    firstEngine.emit(.finished(title: "First", url: URL(string: "https://first.example/")!), for: first.session.activeTabID!)
    secondEngine.emit(.committed(URL(string: "https://second.example/")!), for: second.session.activeTabID!)
    secondEngine.emit(.finished(title: "Second", url: URL(string: "https://second.example/")!), for: second.session.activeTabID!)
    registry.register(first)
    registry.register(second)

    #expect(AppAutomation.currentPage(registry: registry)?.title == "Second")
    registry.markActive(first)
    #expect(AppAutomation.currentPage(registry: registry)?.title == "First")

    first.enterPrivateMode()
    #expect(AppAutomation.currentPage(registry: registry) == nil)
}

@Test @MainActor
func spacesAreListedForTheActiveOrdinaryWindowOnly() {
    let registry = LiveWindowIndex()
    let (model, _) = newModel()
    _ = model.createGroup(named: "Work")
    registry.register(model)
    #expect(AppAutomation.spaces(registry: registry).map(\.name) == ["Personal", "Work"])
    model.enterPrivateMode()
    #expect(AppAutomation.spaces(registry: registry).isEmpty)
}

@Test @MainActor
func theRegistryIgnoresRepeatRegistrationsAndPrefersTheFocusedWindow() {
    let registry = LiveWindowIndex()
    let (first, _) = newModel()
    let (second, _) = newModel()
    registry.register(first)
    registry.register(first)
    registry.register(second)
    #expect(registry.models.count == 2)
    // With nothing focused, the newest ordinary window is the target.
    #expect(registry.activeModel === second)
    registry.markActive(first)
    #expect(registry.activeModel === first)

    // A private window is never preferred while an ordinary one exists.
    let (hidden, _) = newModel()
    hidden.enterPrivateMode()
    let other = LiveWindowIndex()
    other.register(first)
    other.register(hidden)
    #expect(other.activeModel === first)
}
