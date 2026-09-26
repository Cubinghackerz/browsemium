import BrowsemiumCore
import BrowsemiumEngineKit
import AppKit
import Foundation

/// A no-op engine for tests that need engine state — live tabs, captured
/// pages — without spinning up real WebKit views. Everything defaults to
/// "did nothing"; the knobs a test needs are public vars.
@MainActor
final class StubEngine: BrowserEngine {
    /// Tabs the engine reports as live; tests set this directly.
    var liveTabs: Set<TabID> = []
    /// Every value passed to `setPrivateBrowsing`, in order.
    private(set) var privateModeChanges: [Bool] = []
    var isPrivateMode: Bool { privateModeChanges.last ?? false }
    /// How often `prepareWarmTab` ran.
    private(set) var warmTabPreparations = 0
    /// Tabs `capture` was asked about, in order.
    private(set) var capturedTabs: [TabID] = []
    private var zoomLevels: [TabID: CGFloat] = [:]
    /// The text each tab's fake readable page carries.
    var pageText: (TabID) -> String = { _ in "stub page text" }
    private(set) var removedProfileDataStores: [UUID] = []
    var profileDataStoreRemovalError: (any Error)?

    private var observers: [UUID: (TabID, TabRuntimeEvent) -> Void] = [:]

    func addEventObserver(_ handler: @escaping (TabID, TabRuntimeEvent) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    func removeEventObserver(_ token: UUID) { observers[token] = nil }

    /// Fires a runtime event the way a real page would — a link hover, a
    /// navigation starting — to every observer.
    func emit(_ event: TabRuntimeEvent, for tabID: TabID) {
        for handler in observers.values { handler(tabID, event) }
    }

    var downloads: any DownloadReporting { StubDownloads.shared }

    func attach(tabID: TabID, to host: NSView) {}
    func detach(tabID: TabID) {}
    func discard(tabID: TabID) { liveTabs.remove(tabID) }
    func activate(tabID: TabID, in pane: PaneID) async {}
    func deactivate(tabID: TabID) async {}
    func teardownForProfileSwitch() { liveTabs.removeAll() }
    func setPrivateBrowsing(_ isPrivate: Bool) {
        privateModeChanges.append(isPrivate)
    }
    func isLive(tabID: TabID) -> Bool { liveTabs.contains(tabID) }
    var liveTabCount: Int { liveTabs.count }

    func navigate(tabID: TabID, to request: NavigationRequest) async throws {}
    func goBack(tabID: TabID) {}
    func goForward(tabID: TabID) {}
    func reload(tabID: TabID) {}
    func stopLoading(tabID: TabID) {}
    func canGoBack(tabID: TabID) -> Bool { false }
    func canGoForward(tabID: TabID) -> Bool { false }
    func isLoading(tabID: TabID) -> Bool { false }
    func currentURL(tabID: TabID) -> URL? { nil }

    func find(tabID: TabID, query: String, backwards: Bool) async -> FindOutcome {
        FindOutcome(found: false)
    }
    func clearFindHighlight(tabID: TabID) {}
    func adjustZoom(tabID: TabID, by delta: CGFloat) {
        zoomLevels[tabID] = min(max((zoomLevels[tabID] ?? 1) + delta, 0.5), 3)
    }
    func resetZoom(tabID: TabID) { zoomLevels[tabID] = 1 }
    func currentZoom(tabID: TabID) -> CGFloat { zoomLevels[tabID] ?? 1 }
    func setZoom(tabID: TabID, to zoom: CGFloat) {
        zoomLevels[tabID] = min(max(zoom, 0.5), 3)
    }
    func printPage(tabID: TabID) {}
    func pagePDF(tabID: TabID) async throws -> Data { throw BrowsemiumError.webContentUnavailable }
    func pageScreenshot(tabID: TabID) async throws -> Data { throw BrowsemiumError.webContentUnavailable }
    func togglePictureInPicture(tabID: TabID) async -> Bool { false }

    func capture(tabID: TabID, request: CaptureRequest) async throws -> CapturedContext {
        capturedTabs.append(tabID)
        let text = PageTextContext(url: nil, title: nil, text: pageText(tabID))
        return CapturedContext(attachments: [.readablePage(text)])
    }

    func extractArticle(tabID: TabID) async throws -> ReaderArticle {
        throw BrowsemiumError.webContentUnavailable
    }
    func fillCredential(tabID: TabID, username: String, password: String) async throws -> Bool { false }
    func evaluateJavaScript(tabID: TabID, script: String) async throws -> Any? { nil }

    func setMuted(tabID: TabID, muted: Bool) {}
    func audioState(tabID: TabID) -> TabAudioState? { nil }

    var blocking: BlockingState { .inactive }
    var onBlockingActivated: (() -> Void)?
    var pausedTabs: [TabID: Bool] = [:]
    var pausedHosts: Set<String> = []

    func setContentRulesPaused(tabID: TabID, paused: Bool) {
        pausedTabs[tabID] = paused
    }

    func replacePausedBlockingHosts(_ hosts: Set<String>) {
        pausedHosts = hosts
    }

    var pickingTabs: [TabID] = []
    var cancelledPickingTabs: [TabID] = []
    var cosmeticRules: [String: String] = [:]

    func beginElementPicking(tabID: TabID) {
        pickingTabs.append(tabID)
    }

    func cancelElementPicking(tabID: TabID) {
        cancelledPickingTabs.append(tabID)
    }

    func replaceCosmeticRules(_ rulesByHost: [String: String]) {
        cosmeticRules = rulesByHost
    }

    func apply(_ settings: BrowserSettings) {}
    var permissionPrompter: (any PermissionPrompting)?
    func applySleepPolicy(tabs: [BrowserTab], signals: [TabID: TabSleepSignals], now: Date) async {}
    func hibernateInactiveTabs() {}
    func beginMemoryPressureMonitoring(handler: @escaping @MainActor (MemoryPressureLevel) -> Void) {}
    func prepareWarmTab() { warmTabPreparations += 1 }
    var hasWarmTab: Bool { false }
    func setWarmTabPreloading(_ enabled: Bool) {}

    func clearSiteData(dataStoreIdentifier: UUID, includeCache: Bool, modifiedSince: Date) async {}
    func clearCache(dataStoreIdentifier: UUID) async {}
    func removeAllData(dataStoreIdentifier: UUID) async {}
    func removeProfileDataStore(dataStoreIdentifier: UUID) async throws {
        if let profileDataStoreRemovalError { throw profileDataStoreRemovalError }
        removedProfileDataStores.append(dataStoreIdentifier)
    }
}

@MainActor
final class StubDownloads: DownloadReporting {
    static let shared = StubDownloads()
    func addObserver(_ handler: @escaping (DownloadInfo) -> Void) -> UUID { UUID() }
    func removeObserver(_ token: UUID) {}
    func allDownloads() -> [DownloadInfo] { [] }
}
