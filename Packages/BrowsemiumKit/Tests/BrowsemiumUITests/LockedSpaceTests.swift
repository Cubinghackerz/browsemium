import BrowsemiumCore
import BrowsemiumData
import BrowsemiumUI
import Foundation
import Testing
import BrowsemiumEngineKit

/// Drives the locked-space gating without a Touch ID prompt.
@MainActor
private final class FakeSpaceAuthenticator: SpaceUnlockAuthenticating {
    var grants = true
    private(set) var reasons: [String] = []

    func authenticate(reason: String) async -> Bool {
        reasons.append(reason)
        return grants
    }
}

@Test @MainActor
func aLockedSpaceRefusesToOpenWhenAuthenticationFails() async throws {
    let model = BrowserWindowModel()
    let personal = model.session.activeSpaceID
    let secret = model.createGroup(named: "Secret")
    model.switchGroup(personal)
    model.setSpaceLocked(secret, locked: true)

    let authenticator = FakeSpaceAuthenticator()
    authenticator.grants = false
    model.spaceUnlockAuthenticator = authenticator

    model.switchGroup(secret)
    // The switch is asynchronous: the system prompt is not.
    try await Task.sleep(for: .milliseconds(50))

    #expect(model.session.activeSpaceID == personal)
    #expect(model.statusMessage == "“Secret” stayed locked")
    #expect(authenticator.reasons == ["Unlock “Secret”"])
}

@Test @MainActor
func aLockedSpaceOpensAfterAuthentication() async throws {
    let model = BrowserWindowModel()
    let personal = model.session.activeSpaceID
    let secret = model.createGroup(named: "Secret")
    model.switchGroup(personal)
    model.setSpaceLocked(secret, locked: true)

    let authenticator = FakeSpaceAuthenticator()
    model.spaceUnlockAuthenticator = authenticator

    model.switchGroup(secret)
    try await Task.sleep(for: .milliseconds(50))

    #expect(model.session.activeSpaceID == secret)
    #expect(model.isSpaceUnlocked(secret))

    // Switching back and forth does not re-prompt within the same run.
    model.switchGroup(personal)
    model.switchGroup(secret)
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.session.activeSpaceID == secret)
    #expect(authenticator.reasons.count == 1)
}

@Test @MainActor
func lockingASpaceNowMovesYouToAnUnlockedOne() async throws {
    let model = BrowserWindowModel()
    let personal = model.session.activeSpaceID
    let secret = model.createGroup(named: "Secret")
    model.setSpaceLocked(secret, locked: true)
    let authenticator = FakeSpaceAuthenticator()
    model.spaceUnlockAuthenticator = authenticator
    model.switchGroup(secret)
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.session.activeSpaceID == secret)

    model.lockSpaceNow(secret)

    #expect(model.session.activeSpaceID == personal)
    #expect(!model.isSpaceUnlocked(secret))
}

@Test @MainActor
func theLastUnlockedSpaceCannotBeLocked() {
    let model = BrowserWindowModel()
    let onlySpace = model.session.activeSpaceID

    model.setSpaceLocked(onlySpace, locked: true)

    #expect(model.session.spaces.first?.isLocked == false)
    #expect(model.statusMessage == "Keep at least one space unlocked")
}

@Test @MainActor
func lockedSpaceTabsStayOutOfThePalette() async throws {
    let model = BrowserWindowModel()
    let personal = model.session.activeSpaceID
    let secret = model.createGroup(named: "Secret")
    model.newTab(url: URL(string: "https://secret.example/private"))
    let secretTab = model.session.activeTabID!
    model.switchGroup(personal)
    model.setSpaceLocked(secret, locked: true)

    let hidden = model.filteredCommands(query: "secret")
    #expect(!hidden.contains { $0.command == .selectTab(secretTab) })

    // Once unlocked (in this run) the tab is reachable again.
    model.spaceUnlockAuthenticator = FakeSpaceAuthenticator()
    model.switchGroup(secret)
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.session.activeSpaceID == secret)
    model.switchGroup(personal)
    let visible = model.filteredCommands(query: "secret")
    #expect(visible.contains { $0.command == .selectTab(secretTab) })
}

@Test @MainActor
func choosingAnotherSpaceAbandonsAPendingUnlock() async throws {
    let model = BrowserWindowModel()
    let personal = model.session.activeSpaceID
    let secret = model.createGroup(named: "Secret")
    model.switchGroup(personal)
    model.setSpaceLocked(secret, locked: true)
    let authenticator = FakeSpaceAuthenticator()
    model.spaceUnlockAuthenticator = authenticator

    // Ask for the locked space, then change your mind before the prompt
    // resolves: the newer choice wins.
    model.switchGroup(secret)
    model.switchGroup(personal)
    try await Task.sleep(for: .milliseconds(80))

    #expect(model.session.activeSpaceID == personal)
}

@Test @MainActor
func selectingATabInAnotherSpaceSwitchesSpaces() {
    let model = BrowserWindowModel()
    let personal = model.session.activeSpaceID
    let work = model.createGroup(named: "Work")
    let workTab = model.session.activeTabID!

    model.selectTab(workTab)

    // Selecting a tab from another space moves the window there instead of
    // showing a tab the strip does not contain.
    #expect(model.session.activeSpaceID == work)
    #expect(model.session.activeTabID == workTab)
    #expect(model.session.spaces.contains { $0.id == personal })
}

@Test @MainActor
func aLockedSpaceIsNeverTheLaunchSpace() async throws {
    let environment = BrowserEnvironment.inMemory()
    // The locked space sorts first (older creation date), which is what the
    // session loader picks as active — the model has to correct that.
    let secret = BrowserSpace(
        name: "Secret",
        createdAt: Date().addingTimeInterval(-600),
        isLocked: true
    )
    let personal = BrowserSpace(name: "Personal")
    let secretTab = BrowserTab(
        spaceID: secret.id,
        title: "Private",
        lastCommittedURL: URL(string: "https://secret.example"),
        lastAccessedAt: Date().addingTimeInterval(60)
    )
    let personalTab = BrowserTab(spaceID: personal.id, title: "Home")
    try environment.sessionRepository.save(BrowserSessionState(
        spaces: [personal, secret],
        tabs: [personalTab, secretTab],
        folders: [],
        activeSpaceID: secret.id,
        activeTabID: secretTab.id
    ))

    let model = BrowserWindowModel(environment: environment)

    // The lock holds across relaunches: the window opens in an unlocked
    // space, and the active tab belongs to that space.
    #expect(model.session.activeSpaceID == personal.id)
    #expect(model.session.activeTabID == personalTab.id)
    #expect(!model.isSpaceUnlocked(secret.id))
    #expect(model.session.spaces.contains { $0.id == secret.id })
}

@Test @MainActor
func theLockFlagPersistsAcrossReloads() async throws {
    let environment = BrowserEnvironment.inMemory()
    let model = BrowserWindowModel(environment: environment)
    let personal = model.session.activeSpaceID
    let secret = model.createGroup(named: "Secret")
    model.switchGroup(personal)
    model.setSpaceLocked(secret, locked: true)

    var restored: BrowserSessionState?
    for _ in 0..<50 {
        restored = try? environment.sessionRepository.load()
        if restored?.spaces.contains(where: { $0.id == secret && $0.isLocked }) == true { break }
        try? await Task.sleep(for: .milliseconds(20))
    }
    let session = try #require(restored)
    #expect(session.spaces.first { $0.id == secret }?.isLocked == true)
    #expect(session.spaces.first { $0.id == personal }?.isLocked == false)
}

@Test
func olderSpacesWithoutALockFlagDecodeAsUnlocked() throws {
    // A session exported before locked spaces existed must still decode.
    let json = """
    {
      "id": { "rawValue": "\(UUID().uuidString)" },
      "name": "Personal",
      "createdAt": 700000000,
      "color": "#5B8DEF"
    }
    """
    let decoder = JSONDecoder()
    let space = try decoder.decode(BrowserSpace.self, from: Data(json.utf8))
    #expect(space.name == "Personal")
    #expect(space.isLocked == false)
}

@Test @MainActor
func deletingTheActiveSpaceLandsOnAnUnlockedSpace() {
    let model = BrowserWindowModel()
    let personal = model.session.activeSpaceID
    let secret = model.createGroup(named: "Secret")
    model.switchGroup(personal)
    model.setSpaceLocked(secret, locked: true)
    let work = model.createGroup(named: "Work")
    model.switchGroup(personal)

    // Deleting the space you are in must land on an unlocked space — landing
    // inside "Secret" would show exactly what its lock exists to hide.
    model.deleteGroup(personal)

    #expect(model.session.activeSpaceID == work)
    #expect(!model.isSpaceLocked(work))
    #expect(model.session.activeTabID != nil)
    #expect(model.session.tabs.contains { $0.spaceID == model.session.activeSpaceID })
}

@Test @MainActor
func lockingTheSpaceYouAreInMovesYouOut() {
    let model = BrowserWindowModel()
    let personal = model.session.activeSpaceID
    let work = model.createGroup(named: "Work")
    model.switchGroup(personal)

    // Enabling the lock on the space you are standing in locks it for real:
    // the window leaves for an unlocked space rather than sitting half-open
    // inside a space every other surface now treats as hidden.
    model.setSpaceLocked(personal, locked: true)

    #expect(model.session.activeSpaceID == work)
    #expect(model.isSpaceLocked(personal))
    #expect(!model.isSpaceUnlocked(personal))
}

@Test @MainActor
func aLockedActiveSpaceDoesNotSurviveAProfileSwitch() async throws {
    let environment = BrowserEnvironment.inMemory()
    let model = BrowserWindowModel(environment: environment)
    let profileB = try #require(model.createProfile(named: "Work"))

    // Persist a session whose active space is locked — a state only reachable
    // through a hand-edited or migrated database, but the switch must not
    // trust it. Model persistence is off so the crafted row survives.
    model.persistsSession = false
    let secret = BrowserSpace(name: "Secret", isLocked: true)
    let open = BrowserSpace(name: "Open")
    let secretTab = BrowserTab(spaceID: secret.id, title: "Hidden")
    let openTab = BrowserTab(spaceID: open.id, title: "Home")
    try environment.sessionRepository.save(BrowserSessionState(
        spaces: [secret, open],
        tabs: [secretTab, openTab],
        folders: [],
        activeSpaceID: secret.id,
        activeTabID: secretTab.id
    ))

    let profileA = try #require(model.profiles.first { $0.id != profileB.id })
    model.switchProfile(to: profileA)
    model.switchProfile(to: profileB)

    #expect(model.session.activeSpaceID == open.id)
    #expect(model.session.activeTabID == openTab.id)
}

@Test @MainActor
func unlocksDoNotCarryAcrossProfiles() async throws {
    let environment = BrowserEnvironment.inMemory()
    let model = BrowserWindowModel(environment: environment)
    let personal = model.session.activeSpaceID
    let secret = model.createGroup(named: "Secret")
    model.switchGroup(personal)
    model.setSpaceLocked(secret, locked: true)
    model.spaceUnlockAuthenticator = FakeSpaceAuthenticator()
    model.switchGroup(secret)
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.unlockedSpaceIDs.contains(secret))

    _ = model.createProfile(named: "Other")

    // The new profile's locked spaces were never unlocked here; the grant
    // from the previous profile must not leak through.
    #expect(model.unlockedSpaceIDs.isEmpty)
}
