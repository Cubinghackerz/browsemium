import BrowsemiumCore
import BrowsemiumData
import BrowsemiumEngineKit
import BrowsemiumUI
import Foundation
import Testing

@MainActor
private final class RoutingAuthenticator: SpaceUnlockAuthenticating {
    var grants = true
    private(set) var reasons: [String] = []
    var suspends = false
    var pending: CheckedContinuation<Bool, Never>?

    func authenticate(reason: String) async -> Bool {
        reasons.append(reason)
        if suspends {
            return await withCheckedContinuation { pending = $0 }
        }
        return grants
    }

    func resolve(_ granted: Bool) {
        pending?.resume(returning: granted)
        pending = nil
    }
}

/// A model with a Personal space (active) and a Work space, plus a rule that
/// sends `work.example` to Work.
@MainActor
private struct Fixture {
    let engine = StubEngine()
    let model: BrowserWindowModel
    let personal: SpaceID
    let work: SpaceID
    let tab: TabID

    init(workLocked: Bool = false, subdomains: Bool = false) {
        model = BrowserWindowModel(environment: .inMemory(engine: engine))
        personal = model.session.activeSpaceID
        work = model.createGroup(named: "Work")
        model.switchGroup(personal)
        if workLocked { model.setSpaceLocked(work, locked: true) }
        tab = model.session.activeTabID!
        model.routing.setRoute(host: "work.example", includesSubdomains: subdomains, to: work)
    }

    func commit(_ url: String, tab: TabID? = nil) {
        engine.emit(.committed(URL(string: url)!), for: tab ?? self.tab)
    }

    func space(of id: TabID) -> SpaceID? { model.session.tabs.first { $0.id == id }?.spaceID }
}

@Test @MainActor
func aRoutedNavigationMovesTheActiveTabAndOffersUndo() throws {
    let f = Fixture()
    f.commit("https://work.example/dashboard")

    #expect(f.space(of: f.tab) == f.work)
    #expect(f.model.session.activeSpaceID == f.work)
    guard case .moved(let notice)? = f.model.routing.notice else {
        Issue.record("Expected a moved notice"); return
    }
    #expect(notice.host == "work.example")
    #expect(notice.toSpaceName == "Work")
    #expect(notice.fromSpaceID == f.personal)

    f.model.routing.undo()
    #expect(f.space(of: f.tab) == f.personal)
    #expect(f.model.routing.notice == nil)
}

@Test @MainActor
func reloadingAfterTheMoveDoesNotRouteAgainAndUndoIsNotFoughtByTheRule() {
    let f = Fixture()
    f.commit("https://work.example/")
    f.commit("https://work.example/") // reload: already in Work, nothing to do
    #expect(f.space(of: f.tab) == f.work)

    f.model.routing.undo()
    #expect(f.space(of: f.tab) == f.personal)
    // The person said "not here": the same host in the same tab stays put…
    f.commit("https://work.example/again")
    #expect(f.space(of: f.tab) == f.personal)
    #expect(f.model.routing.notice == nil)
    // …until the tab visits a different host and comes back.
    f.commit("https://elsewhere.example/")
    f.commit("https://work.example/")
    #expect(f.space(of: f.tab) == f.work)
}

@Test @MainActor
func nonMatchingAndSiblingHostsAreLeftAlone() {
    let f = Fixture()
    f.commit("https://notwork.example/")
    f.commit("https://work.example.evil.test/")
    f.commit("https://sub.work.example/") // exact rule: subdomains do not match
    #expect(f.space(of: f.tab) == f.personal)
    #expect(f.model.routing.notice == nil)
}

@Test @MainActor
func subdomainRulesRouteSubdomains() {
    let f = Fixture(subdomains: true)
    f.commit("https://app.work.example/")
    #expect(f.space(of: f.tab) == f.work)
}

@Test @MainActor
func privateWindowsNeverRoute() {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    let work = model.createGroup(named: "Work")
    model.routing.setRoute(host: "work.example", includesSubdomains: false, to: work)
    model.enterPrivateMode()
    let tab = model.session.activeTabID!

    engine.emit(.committed(URL(string: "https://work.example/")!), for: tab)

    #expect(model.session.isPrivate)
    #expect(model.session.tabs.first { $0.id == tab }?.spaceID == model.session.activeSpaceID)
    #expect(model.routing.notice == nil)
}

@Test @MainActor
func previewsBackgroundTabsAndPinnedTabsAreNotRouted() {
    let f = Fixture()
    // A preview is not a tab.
    f.model.openPeek(url: URL(string: "https://work.example/")!)
    let peekTab = f.model.peek!.tabID
    f.engine.emit(.committed(URL(string: "https://work.example/")!), for: peekTab)
    #expect(f.model.routing.notice == nil)
    f.model.closePeek()

    // A background tab that navigates stays where it is.
    let background = f.model.newTab(url: nil)
    f.model.selectTab(f.tab)
    f.commit("https://work.example/", tab: background)
    #expect(f.space(of: background) == f.personal)

    // A pinned tab is deliberate placement.
    f.model.togglePin(f.tab)
    f.commit("https://work.example/")
    #expect(f.space(of: f.tab) == f.personal)
    #expect(f.model.routing.notice == nil)
}

@Test @MainActor
func splitViewExplainsInsteadOfMovingATab() {
    let f = Fixture()
    let other = f.model.newTab(url: nil)
    f.model.selectTab(f.tab)
    f.model.openInSplitView(other)
    #expect(f.model.isSplitViewActive)

    f.commit("https://work.example/")

    #expect(f.space(of: f.tab) == f.personal)
    #expect(f.model.statusMessage?.contains("Close split view") == true)
}

@Test @MainActor
func aLockedDestinationNeverMovesTheTabBeforeAUnlock() async throws {
    let f = Fixture(workLocked: true)
    let authenticator = RoutingAuthenticator()
    authenticator.grants = false
    f.model.spaceUnlockAuthenticator = authenticator

    f.commit("https://work.example/")
    // Nothing moved and nothing was asked: a navigation never triggers Touch ID.
    guard case .needsUnlock(let pending)? = f.model.routing.notice else {
        Issue.record("Expected an unlock choice"); return
    }
    #expect(pending.toSpaceName == "Work")
    #expect(f.space(of: f.tab) == f.personal)
    #expect(authenticator.reasons.isEmpty)

    // Denied: still nothing moved, and the space stays locked.
    f.model.routing.confirmUnlockAndMove()
    try #require(await waitFor { f.model.routing.notice == nil })
    #expect(f.space(of: f.tab) == f.personal)
    #expect(!f.model.isSpaceUnlocked(f.work))
    #expect(f.model.statusMessage == "“Work” stayed locked")
}

@Test @MainActor
func aGrantedUnlockMovesTheTabOnce() async throws {
    let f = Fixture(workLocked: true)
    let authenticator = RoutingAuthenticator()
    f.model.spaceUnlockAuthenticator = authenticator

    f.commit("https://work.example/")
    f.model.routing.confirmUnlockAndMove()
    try #require(await waitFor { f.space(of: f.tab) == f.work })

    #expect(f.model.isSpaceUnlocked(f.work))
    #expect(authenticator.reasons == ["Unlock “Work”"])
    guard case .moved? = f.model.routing.notice else {
        Issue.record("Expected a moved notice after the unlock"); return
    }
}

@Test @MainActor
func aNewerNavigationDuringUnlockCancelsTheMove() async throws {
    let f = Fixture(workLocked: true)
    let authenticator = RoutingAuthenticator()
    authenticator.suspends = true
    f.model.spaceUnlockAuthenticator = authenticator

    f.commit("https://work.example/")
    f.model.routing.confirmUnlockAndMove()
    try #require(await waitFor { !authenticator.reasons.isEmpty })

    // The page changes while the system prompt is up.
    f.commit("https://elsewhere.example/")
    authenticator.resolve(true)
    try await Task.sleep(for: .milliseconds(100))

    #expect(f.space(of: f.tab) == f.personal)
    #expect(f.model.routing.notice == nil)
}

@Test @MainActor
func closingTheTabDuringUnlockCancelsTheMove() async throws {
    let f = Fixture(workLocked: true)
    let spare = f.model.newTab(url: nil)
    f.model.selectTab(f.tab)
    let authenticator = RoutingAuthenticator()
    authenticator.suspends = true
    f.model.spaceUnlockAuthenticator = authenticator

    f.commit("https://work.example/")
    f.model.routing.confirmUnlockAndMove()
    try #require(await waitFor { !authenticator.reasons.isEmpty })
    f.model.closeTab(f.tab)
    authenticator.resolve(true)
    try await Task.sleep(for: .milliseconds(100))

    #expect(f.model.session.tabs.contains { $0.id == f.tab } == false)
    #expect(f.model.session.tabs.contains { $0.id == spare })
    #expect(f.model.routing.notice == nil)
}

@Test @MainActor
func undoRefusesWhenTheTabHasMovedSince() {
    let f = Fixture()
    let third = f.model.createGroup(named: "Third")
    f.model.switchGroup(f.personal)
    f.commit("https://work.example/")
    guard case .moved? = f.model.routing.notice else { Issue.record("no notice"); return }

    // Someone moves the tab again before undoing.
    f.model.moveTab(f.tab, toGroup: third)
    f.model.routing.undo()

    #expect(f.space(of: f.tab) == third)
    #expect(f.model.statusMessage?.contains("moved since") == true)
}

@Test @MainActor
func undoNeverUnlocksOrResurrectsTheOriginalSpace() {
    // Origin deleted.
    let a = Fixture()
    let scratch = a.model.createGroup(named: "Scratch")
    a.model.moveTab(a.tab, toGroup: scratch)
    a.model.selectTab(a.tab)
    a.commit("https://work.example/")
    guard case .moved? = a.model.routing.notice else { Issue.record("no notice"); return }
    a.model.deleteGroup(scratch)
    a.model.routing.undo()
    #expect(a.space(of: a.tab) == a.work)
    #expect(!a.model.session.spaces.contains { $0.id == scratch })

    // Origin locked after the move.
    let b = Fixture()
    b.commit("https://work.example/")
    b.model.setSpaceLocked(b.personal, locked: true)
    b.model.routing.undo()
    #expect(b.space(of: b.tab) == b.work)
    #expect(!b.model.isSpaceUnlocked(b.personal))
    #expect(b.model.statusMessage?.contains("locked") == true)
}

@Test @MainActor
func undoRestoresTheOriginalFolderWhenItSurvives() {
    let f = Fixture()
    let folder = f.model.createFolder(named: "Reading")
    // A second member keeps the folder alive after the first one leaves; a
    // folder emptied by the move is dissolved by existing behavior.
    let sibling = f.model.newTab(url: nil)
    f.model.assignTab(sibling, toFolder: folder)
    f.model.selectTab(f.tab)
    f.model.assignTab(f.tab, toFolder: folder)
    f.commit("https://work.example/")
    #expect(f.model.session.tabs.first { $0.id == f.tab }?.folderID == nil)

    f.model.routing.undo()
    #expect(f.space(of: f.tab) == f.personal)
    #expect(f.model.session.tabs.first { $0.id == f.tab }?.folderID == folder)
}

@Test @MainActor
func deletingASpaceRemovesItsRulesAndTheyNeverFireAgain() {
    let f = Fixture()
    f.model.deleteGroup(f.work)
    #expect(f.model.routing.routes.isEmpty)
    f.commit("https://work.example/")
    #expect(f.space(of: f.tab) == f.personal)
}

@Test @MainActor
func rulesAndNoticesDoNotBleedAcrossProfiles() throws {
    let engine = StubEngine()
    let environment = BrowserEnvironment.inMemory(engine: engine)
    let model = BrowserWindowModel(environment: environment)
    let work = model.createGroup(named: "Work")
    model.routing.setRoute(host: "work.example", includesSubdomains: false, to: work)
    #expect(model.routing.routes.count == 1)

    let second = try environment.profileStore.create(name: "Second")
    model.switchProfile(to: second)

    #expect(model.routing.routes.isEmpty)
    #expect(model.routing.notice == nil)
    let tab = model.session.activeTabID!
    engine.emit(.committed(URL(string: "https://work.example/")!), for: tab)
    #expect(model.routing.notice == nil)
}

@Test @MainActor
func aRuleThatCannotBeSavedReportsInsteadOfPretending() {
    let f = Fixture()
    #expect(f.model.routing.setRoute(host: "https://bad.example/path", includesSubdomains: false, to: f.work) == false)
    #expect(f.model.statusMessage != nil)
    #expect(f.model.routing.routes.count == 1)
}

@Test @MainActor
func settingARuleForThePageYouAreOnMovesItImmediately() {
    let f = Fixture()
    f.engine.emit(.committed(URL(string: "https://other.example/")!), for: f.tab)
    #expect(f.space(of: f.tab) == f.personal)

    f.model.routing.setRoute(host: "other.example", includesSubdomains: false, to: f.work)
    f.model.routing.routeActiveTabNow()

    #expect(f.space(of: f.tab) == f.work)
}
