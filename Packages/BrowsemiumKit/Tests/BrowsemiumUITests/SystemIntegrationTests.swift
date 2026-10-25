import BrowsemiumCore
import BrowsemiumData
import BrowsemiumEngineKit
import BrowsemiumExtensions
import Foundation
import Testing
@testable import BrowsemiumUI

/// Records what would reach Spotlight.
private final class RecordingIndex: SearchableIndexing, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private var indexed: [[SpotlightItem]] = []

    var events: [String] { lock.withLock { storage } }
    var batches: [[SpotlightItem]] { lock.withLock { indexed } }

    func index(_ items: [SpotlightItem], domain: String) async throws {
        lock.withLock { storage.append("index:\(domain):\(items.count)"); indexed.append(items) }
    }

    func deleteAll(domain: String) async throws {
        lock.withLock { storage.append("delete:\(domain)") }
    }
}

@MainActor
private func makeModel() -> (BrowserWindowModel, StubEngine, BrowserEnvironment, RecordingIndex) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-system-integration-\(UUID().uuidString)", isDirectory: true)
    let engine = StubEngine()
    let environment = BrowserEnvironment.inMemory(engine: engine, extensionStore: ExtensionStore(rootDirectory: root))
    let index = RecordingIndex()
    environment.spotlight.index = index
    return (BrowserWindowModel(environment: environment), engine, environment, index)
}

@MainActor
private func visit(_ engine: StubEngine, _ model: BrowserWindowModel, _ url: String, title: String = "Fixture") {
    let tab = model.session.activeTabID!
    engine.emit(.committed(URL(string: url)!), for: tab)
    engine.emit(.finished(title: title, url: URL(string: url)!), for: tab)
}

// MARK: - Spotlight

@Test @MainActor
func spotlightStaysOffByDefaultAndOnlyClearsItsOwnDomain() async throws {
    let (model, engine, environment, index) = makeModel()
    visit(engine, model, "https://a.example/")
    model.toggleBookmark()

    await environment.spotlight.reconcile().value

    #expect(model.environment.loadSettings().indexBookmarksInSpotlight == false)
    #expect(index.batches.isEmpty, "Nothing is ever indexed while the setting is off")
    #expect(index.events.allSatisfy { $0 == "delete:\(SpotlightPolicy.domainIdentifier)" })
}

@Test @MainActor
func turningSpotlightOnIndexesOnlyTitleAndAddress() async throws {
    let (model, engine, environment, index) = makeModel()
    visit(engine, model, "https://a.example/page", title: "A page")
    model.toggleBookmark()
    model.updateSettings { $0.indexBookmarksInSpotlight = true }

    await environment.spotlight.reconcile().value
    try #require(await waitFor { !index.batches.isEmpty })

    let item = try #require(index.batches.last?.first)
    #expect(item.url.absoluteString == "https://a.example/page")
    #expect(item.title == "A page")
    #expect(item.host == "a.example")
    #expect(index.batches.last?.count == 1)
}

@Test @MainActor
func turningSpotlightOffRemovesEverything() async throws {
    let (model, engine, environment, index) = makeModel()
    visit(engine, model, "https://a.example/")
    model.toggleBookmark()
    model.updateSettings { $0.indexBookmarksInSpotlight = true }
    await environment.spotlight.reconcile().value
    try #require(await waitFor { !index.batches.isEmpty })
    let before = index.events.count

    model.updateSettings { $0.indexBookmarksInSpotlight = false }
    await environment.spotlight.reconcile().value
    try #require(await waitFor { index.events.count > before })

    #expect(index.events.last == "delete:\(SpotlightPolicy.domainIdentifier)")
    #expect(environment.spotlight.lastItems.isEmpty)
}

@Test @MainActor
func anUnchangedSetSendsNothingAgain() async throws {
    let (model, engine, environment, index) = makeModel()
    visit(engine, model, "https://a.example/")
    model.toggleBookmark()
    model.updateSettings { $0.indexBookmarksInSpotlight = true }
    await environment.spotlight.reconcile().value
    try #require(await waitFor { !index.batches.isEmpty })
    let count = index.events.count

    for _ in 0..<5 { model.refreshBookmarks() }
    await environment.spotlight.reconcile().value
    try await Task.sleep(for: .milliseconds(100))

    #expect(index.events.count == count)
}

@Test @MainActor
func bookmarksSavedFromPrivateLockedOrSeparateContextsAreNeverEligible() async throws {
    let (model, engine, environment, _) = makeModel()
    let personal = model.session.activeSpaceID
    let separate = model.createGroup(named: "Separate", separateData: true)
    let locked = model.createGroup(named: "Locked")
    model.switchGroup(personal)

    visit(engine, model, "https://ordinary.example/")
    model.toggleBookmark()

    model.switchGroup(separate)
    visit(engine, model, "https://separate.example/")
    model.toggleBookmark()

    model.switchGroup(locked)
    model.setSpaceLocked(locked, locked: true)
    // A locked space the person has unlocked this run is still locked.
    model.switchGroup(locked)
    if model.session.activeSpaceID == locked {
        visit(engine, model, "https://locked.example/")
        model.toggleBookmark()
    }

    model.switchGroup(personal)
    model.enterPrivateMode()
    visit(engine, model, "https://private.example/")
    model.toggleBookmark()

    let saved = try environment.bookmarkRepository.all()
    func eligible(_ host: String) -> Bool? {
        saved.first { $0.url.host == host }?.isSpotlightEligible
    }
    #expect(eligible("ordinary.example") == true)
    #expect(eligible("separate.example") == false)
    #expect(eligible("private.example") == false)
    if let value = eligible("locked.example") { #expect(value == false) }

    model.updateSettings { $0.indexBookmarksInSpotlight = true }
    let items = SpotlightBookmarkIndexer.items(for: saved, enabled: true)
    #expect(items.map(\.host) == ["ordinary.example"])
}

@Test @MainActor
func aSpotlightResultOpensOnlyAnEligibleBookmarkWhileTheFeatureIsOn() async throws {
    let (model, engine, environment, _) = makeModel()
    visit(engine, model, "https://a.example/page")
    model.toggleBookmark()
    let bookmark = try #require(try environment.bookmarkRepository.all().first)

    #expect(environment.spotlight.resolve(identifier: bookmark.id.uuidString) == nil, "Feature off")
    model.updateSettings { $0.indexBookmarksInSpotlight = true }
    #expect(environment.spotlight.resolve(identifier: bookmark.id.uuidString)?.absoluteString == "https://a.example/page")
    #expect(environment.spotlight.resolve(identifier: UUID().uuidString) == nil)
    #expect(environment.spotlight.resolve(identifier: "https://evil.example/") == nil, "An address is not an identifier")

    let tabsBefore = model.session.tabs.count
    model.openSpotlightResult(identifier: "not-a-bookmark")
    #expect(model.session.tabs.count == tabsBefore)
    model.openSpotlightResult(identifier: bookmark.id.uuidString)
    #expect(model.session.tabs.count == tabsBefore + 1)
}

@Test @MainActor
func aSpotlightResultNeverOpensInAPrivateWindow() async throws {
    let (model, engine, environment, _) = makeModel()
    visit(engine, model, "https://a.example/page")
    model.toggleBookmark()
    model.updateSettings { $0.indexBookmarksInSpotlight = true }
    let bookmark = try #require(try environment.bookmarkRepository.all().first)
    model.enterPrivateMode()
    let before = model.session.tabs.count

    model.openSpotlightResult(identifier: bookmark.id.uuidString)

    #expect(model.session.tabs.count == before)
}

@Test @MainActor
func bookmarkItemsAreCapped() {
    let many = (0..<(SpotlightPolicy.maxItems + 50)).map {
        Bookmark(url: URL(string: "https://e\($0).example/")!, title: "t\($0)")
    }
    #expect(SpotlightBookmarkIndexer.items(for: many, enabled: true).count == SpotlightPolicy.maxItems)
    #expect(SpotlightBookmarkIndexer.items(for: many, enabled: false).isEmpty)
}

// MARK: - Handoff

@Test @MainActor
func handoffOffersNothingByDefault() {
    let (model, engine, _, _) = makeModel()
    visit(engine, model, "https://a.example/")
    #expect(model.isHandoffEnabled == false)
    #expect(model.handoffURL == nil)
}

@Test @MainActor
func handoffOffersTheActiveHTTPSPageWhenOptedIn() {
    let (model, engine, _, _) = makeModel()
    model.updateSettings { $0.handoffActiveTab = true }
    visit(engine, model, "https://a.example/page?x=1#frag")
    #expect(model.handoffURL?.absoluteString == "https://a.example/page?x=1")
    visit(engine, model, "http://plain.example/")
    #expect(model.handoffURL == nil)
}

@Test @MainActor
func handoffNeverOffersPrivateLockedOrSeparateDataPages() {
    let (model, engine, _, _) = makeModel()
    model.updateSettings { $0.handoffActiveTab = true }
    let personal = model.session.activeSpaceID
    let separate = model.createGroup(named: "Separate", separateData: true)
    let locked = model.createGroup(named: "Locked")

    model.switchGroup(separate)
    visit(engine, model, "https://separate.example/")
    #expect(model.handoffURL == nil)

    model.switchGroup(personal)
    model.setSpaceLocked(locked, locked: true)
    model.switchGroup(personal)
    visit(engine, model, "https://ordinary.example/")
    #expect(model.handoffURL != nil)

    model.enterPrivateMode()
    visit(engine, model, "https://private.example/")
    #expect(model.handoffURL == nil)
}

@Test @MainActor
func handedOffAddressesOpenOnlyWhenOptedInAndPlainHTTPS() {
    let (model, _, _, _) = makeModel()
    let before = model.session.tabs.count
    model.openHandedOff(URL(string: "https://a.example/"))
    #expect(model.session.tabs.count == before, "Off by default")

    model.updateSettings { $0.handoffActiveTab = true }
    model.openHandedOff(URL(string: "http://a.example/"))
    model.openHandedOff(URL(string: "browsemium://open?url=https://a.example"))
    model.openHandedOff(nil)
    #expect(model.session.tabs.count == before)

    model.openHandedOff(URL(string: "https://a.example/"))
    #expect(model.session.tabs.count == before + 1)

    model.enterPrivateMode()
    let privateBefore = model.session.tabs.count
    model.openHandedOff(URL(string: "https://b.example/"))
    #expect(model.session.tabs.count == privateBefore, "Never into a private window")
}

// MARK: - Surface

@Test
func theAutomationSurfaceStillHasNoAIAgentOrSettingsCommand() throws {
    // Spotlight and Handoff must not add a way to reach AI, agents or settings.
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { root.deleteLastPathComponent() }
    let sources = root.appendingPathComponent("Sources/BrowsemiumUI/App")
    for name in ["SpotlightBookmarkIndexer.swift", "BrowserWindowModel+SystemIntegration.swift"] {
        let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
        for forbidden in ["AgentCoordinator", "AIAdapter", "runQuickAction", "updateSettings", "setEndpointEnabled", "ai."] {
            #expect(!text.contains(forbidden), "\(name) must not reference \(forbidden)")
        }
    }
}
