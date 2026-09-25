import BrowsemiumCore
import BrowsemiumData
import BrowsemiumUI
import Foundation
import Testing
import BrowsemiumEngineKit

// MARK: - Entering private mode

@Test @MainActor
func enteringPrivateModeStartsAFreshEphemeralSession() {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    model.newTab(url: URL(string: "https://before.example"))

    model.enterPrivateMode()

    #expect(model.session.isPrivate)
    #expect(model.session.spaces.count == 1)
    #expect(model.session.spaces.first?.name == "Private")
    #expect(model.session.tabs.count == 1)
    #expect(model.session.activeTabID != nil)
    #expect(model.session.tabs.first { $0.id == model.session.activeTabID! }?.lastCommittedURL == nil)
    // The engine was told before any view could build a persistent web view.
    #expect(engine.isPrivateMode)
    #expect(model.peek == nil)
    #expect(model.readerArticle == nil)
}

@Test @MainActor
func aPrivateWindowPersistsNothing() {
    let engine = StubEngine()
    let environment = BrowserEnvironment.inMemory(engine: engine)
    let model = BrowserWindowModel(environment: environment)
    model.enterPrivateMode()

    model.newTab(url: URL(string: "https://secret.example/page"))
    let tab = model.session.activeTabID!
    model.closeTab(tab)

    // No closed-tab record, no session snapshot, no history.
    #expect(model.recentlyClosedTabs().isEmpty)
    #expect((try? environment.sessionRepository.load()) == nil)
    #expect((try? environment.historyRepository.recent(limit: 10).isEmpty) == true)
}

@Test @MainActor
func privateWindowsNeverRecordHistoryEvenAfterNavigation() {
    let engine = StubEngine()
    let environment = BrowserEnvironment.inMemory(engine: engine)
    let model = BrowserWindowModel(environment: environment)
    model.enterPrivateMode()
    let tab = model.session.activeTabID!

    engine.emit(.committed(URL(string: "https://secret.example")!), for: tab)
    engine.emit(.finished(title: "Secret Page", url: URL(string: "https://secret.example")!), for: tab)

    #expect((try? environment.historyRepository.recent(limit: 10))?.isEmpty == true)
}

@Test @MainActor
func privateWindowsDoNotPrepareWarmTabs() {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    model.enterPrivateMode()
    let tab = model.session.activeTabID!

    engine.emit(.committed(URL(string: "https://secret.example")!), for: tab)
    engine.emit(.finished(title: "Secret", url: URL(string: "https://secret.example")!), for: tab)
    #expect(engine.warmTabPreparations == 0)

    // The normal path still refills the warm pool.
    let normalEngine = StubEngine()
    let normalModel = BrowserWindowModel(environment: .inMemory(engine: normalEngine))
    let normalTab = normalModel.session.activeTabID!
    normalEngine.emit(.finished(title: "Open", url: URL(string: "https://open.example")!), for: normalTab)
    #expect(normalEngine.warmTabPreparations == 1)
}

@Test @MainActor
func privateAddressSuggestionsExcludeHistory() throws {
    let engine = StubEngine()
    let environment = BrowserEnvironment.inMemory(engine: engine)
    try environment.historyRepository.record(
        url: URL(string: "https://bank.example/account")!,
        title: "Your bank"
    )
    let model = BrowserWindowModel(environment: environment)

    // The normal window suggests the recorded history…
    model.addressText = "bank"
    model.updateAddressSuggestions()
    #expect(model.addressSuggestions.contains { $0.kind == .history })

    // …the private window does not surface the profile's past.
    model.enterPrivateMode()
    model.addressText = "bank"
    model.updateAddressSuggestions()
    #expect(!model.addressSuggestions.contains { $0.kind == .history })
}

// MARK: - Window plumbing

@Test @MainActor
func thePrivateWindowRequestIsConsumedByExactlyOneWindow() {
    let request = PrivateWindowRequest.shared
    request.consume()  // clear any state from parallel tests

    request.arm()
    #expect(request.consume())
    #expect(!request.consume())
}
