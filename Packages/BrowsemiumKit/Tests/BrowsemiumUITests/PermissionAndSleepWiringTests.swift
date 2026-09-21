import AppKit
import BrowsemiumCore
import BrowsemiumEngine
import Foundation
import Testing
import BrowsemiumEngineKit
@testable import BrowsemiumUI

/// The sleep policy is only as good as the signals the window hands it. These
/// cover the wiring that used to be missing: the model passed an empty signal
/// map, so an audible tab, a call, or a download could be unloaded mid-flight.
@MainActor
@Test
func sleepSignalsCarryEveryProtection() {
    let spaceID = SpaceID()
    let audible = BrowserTab(spaceID: spaceID, title: "Playing", lifecycle: .active)
    let onCall = BrowserTab(spaceID: spaceID, title: "Call", lifecycle: .active)
    let downloading = BrowserTab(spaceID: spaceID, title: "Downloading", lifecycle: .active)
    let kept = BrowserTab(spaceID: spaceID, title: "Kept", lifecycle: .active)
    let quiet = BrowserTab(spaceID: spaceID, title: "Quiet", lifecycle: .active)
    let tabs = [audible, onCall, downloading, kept, quiet]

    let signals = BrowserWindowModel.makeSignals(
        tabs: tabs,
        audio: [
            audible.id: TabAudioState(isPlaying: true, isMuted: false),
            onCall.id: TabAudioState(isPlaying: false, isMuted: true, isCapturingMedia: true)
        ],
        activeDownloads: [downloading.id],
        keepAwake: [kept.id]
    )

    #expect(signals[audible.id]?.isAudible == true)
    #expect(signals[onCall.id]?.isCapturingMedia == true)
    #expect(signals[downloading.id]?.hasActiveDownload == true)
    #expect(signals[kept.id]?.isKeepAwake == true)
    #expect(signals[quiet.id]?.protectsFromSleep == false)
    #expect(signals.count == tabs.count)
}

/// A muted tab that is holding a call is not audible, so the capture signal is
/// the only thing that protects it.
@MainActor
@Test
func mutedCallStillProtectsItsTab() {
    let spaceID = SpaceID()
    let tab = BrowserTab(spaceID: spaceID, title: "Call", lifecycle: .active)
    let signals = BrowserWindowModel.makeSignals(
        tabs: [tab],
        audio: [tab.id: TabAudioState(isPlaying: false, isMuted: true, isCapturingMedia: true)],
        activeDownloads: [],
        keepAwake: []
    )
    #expect(signals[tab.id]?.protectsFromSleep == true)
}

/// Keep-awake is a user promise: the memory saver must leave the tab alone.
@MainActor
@Test
func keepAwakeTabsSurviveTheSleepPolicy() {
    let model = BrowserWindowModel()
    let tabID = model.newTab()
    #expect(model.isKeptAwake(tabID) == false)

    model.toggleKeepAwake(tabID)
    #expect(model.isKeptAwake(tabID))

    let signals = model.sleepSignals(for: model.session.tabs)
    #expect(signals[tabID]?.isKeepAwake == true)

    model.toggleKeepAwake(tabID)
    #expect(model.isKeptAwake(tabID) == false)
}

/// A closed tab must not stay in the keep-awake set, or a later tab reusing
/// the identifier would inherit the protection.
@MainActor
@Test
func closingATabForgetsItsKeepAwakeMark() {
    let model = BrowserWindowModel()
    let tabID = model.newTab()
    model.toggleKeepAwake(tabID)
    model.closeTab(tabID)
    #expect(model.isKeptAwake(tabID) == false)
}

/// The camera/microphone prompt: nothing is decided silently, an "always"
/// answer is remembered, and a blocked site is not asked again.
@MainActor
@Test
func permissionPromptIsAnsweredAndRemembered() async {
    let model = BrowserWindowModel()
    let origin = "https://meet.example.com"

    let ask = Task { await model.permissionDecision(origin: origin, kind: .microphone) }
    await waitForPendingPermissions(model, count: 1)
    #expect(model.pendingPermissionRequest?.origin == origin)
    #expect(model.pendingPermissionRequest?.kind == .microphone)

    model.answerPermissionRequest(.allowAlways)
    #expect(await ask.value == .allow)
    #expect(model.pendingPermissionRequest == nil)
    #expect(model.sitePermissions.contains { $0.origin == origin && $0.kind == .microphone && $0.decision == .allow })

    // Remembered: the next request is answered without a prompt.
    let second = await model.permissionDecision(origin: origin, kind: .microphone)
    #expect(second == .allow)
    #expect(model.pendingPermissionRequest == nil)
}

@MainActor
@Test
func blockingASiteIsRememberedAsDenied() async {
    let model = BrowserWindowModel()
    let origin = "https://camera.example.com"

    let ask = Task { await model.permissionDecision(origin: origin, kind: .camera) }
    await waitForPendingPermissions(model, count: 1)
    model.answerPermissionRequest(.block)
    #expect(await ask.value == .deny)

    let second = await model.permissionDecision(origin: origin, kind: .camera)
    #expect(second == .deny)
    #expect(model.pendingPermissionRequest == nil)
}

/// "Allow" without "always" is deliberately not written down.
@MainActor
@Test
func allowOnceIsNotRemembered() async {
    let model = BrowserWindowModel()
    let origin = "https://once.example.com"

    let ask = Task { await model.permissionDecision(origin: origin, kind: .camera) }
    await waitForPendingPermissions(model, count: 1)
    model.answerPermissionRequest(.allowOnce)
    #expect(await ask.value == .allow)
    #expect(model.sitePermissions.contains { $0.origin == origin } == false)
}

/// Two pages can ask at the same time; the second waits its turn instead of
/// overwriting the first prompt.
@MainActor
@Test
func concurrentPermissionRequestsQueue() async {
    let model = BrowserWindowModel()
    let first = Task { await model.permissionDecision(origin: "https://one.example.com", kind: .camera) }
    await waitForPendingPermissions(model, count: 1)
    let second = Task { await model.permissionDecision(origin: "https://two.example.com", kind: .microphone) }
    await waitForPendingPermissions(model, count: 2)

    #expect(model.pendingPermissionRequest?.origin == "https://one.example.com")
    model.answerPermissionRequest(.allowOnce)
    #expect(await first.value == .allow)

    await waitForPendingPermissions(model, count: 1)
    #expect(model.pendingPermissionRequest?.origin == "https://two.example.com")
    model.answerPermissionRequest(.block)
    #expect(await second.value == .deny)
    #expect(model.pendingPermissionCount == 0)
}

@MainActor
@Test
func removingASitePermissionMakesTheSiteAskAgain() async {
    let model = BrowserWindowModel()
    let origin = "https://forget.example.com"

    let ask = Task { await model.permissionDecision(origin: origin, kind: .camera) }
    await waitForPendingPermissions(model, count: 1)
    model.answerPermissionRequest(.allowAlways)
    _ = await ask.value
    let stored = model.sitePermissions.first { $0.origin == origin }
    #expect(stored != nil)

    if let stored {
        model.removeSitePermission(stored)
    }
    #expect(model.sitePermissions.contains { $0.origin == origin } == false)
}

/// Favicon caching has to stay bounded and must not mark a host as hopeless
/// after one failed attempt.
@MainActor
@Test
func faviconCacheStaysBoundedAndRetriesOnce() {
    let store = FaviconStore()
    let image = NSImage(size: NSSize(width: 16, height: 16))

    for index in 0..<400 {
        store.store(image, for: "host\(index).example.com")
    }
    #expect(store.images.count <= 256)

    #expect(store.canAttempt("retry.example.com"))
    store.recordAttempt("retry.example.com")
    #expect(store.canAttempt("retry.example.com"))
    store.recordAttempt("retry.example.com")
    #expect(store.canAttempt("retry.example.com") == false)

    for index in 0..<600 {
        store.recordAttempt("tracked\(index).example.com")
    }
    // The tracker stays bounded, so the oldest hosts are forgotten and may be
    // attempted again rather than being blocked for the session.
    #expect(store.canAttempt("tracked0.example.com"))
}

/// Waits for the model to surface `count` queued prompts. Bounded so a wiring
/// bug fails the test instead of hanging the suite.
@MainActor
private func waitForPendingPermissions(
    _ model: BrowserWindowModel,
    count: Int,
    attempts: Int = 200
) async {
    for _ in 0..<attempts {
        if model.pendingPermissionCount >= count { return }
        await Task.yield()
    }
}
