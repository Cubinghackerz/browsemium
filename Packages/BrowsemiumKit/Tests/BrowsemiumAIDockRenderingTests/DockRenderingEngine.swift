import AppKit
import BrowsemiumCore
import BrowsemiumEngineKit
import Foundation

/// No navigation, network request or page capture occurs in these fixtures.
@MainActor
final class DockRenderingEngine: BrowserEngine {
    private var observers: [UUID: (TabID, TabRuntimeEvent) -> Void] = [:]
    private(set) var capturedTabs: [TabID] = []
    let downloads: any DownloadReporting = DockRenderingDownloads()
    var blocking: BlockingState { .inactive }
    var onBlockingActivated: (() -> Void)?
    var permissionPrompter: (any PermissionPrompting)?
    var liveTabCount: Int { 0 }
    var hasWarmTab: Bool { false }

    func addEventObserver(_ handler: @escaping (TabID, TabRuntimeEvent) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }
    func removeEventObserver(_ token: UUID) { observers[token] = nil }
    func emit(_ event: TabRuntimeEvent, for tab: TabID) {
        for observer in observers.values { observer(tab, event) }
    }
    func attach(tabID: TabID, to host: NSView) {}
    func detach(tabID: TabID) {}
    func discard(tabID: TabID) {}
    func activate(tabID: TabID, in pane: PaneID) async {}
    func deactivate(tabID: TabID) async {}
    func teardownForProfileSwitch() {}
    func isLive(tabID: TabID) -> Bool { false }
    func navigate(tabID: TabID, to request: NavigationRequest) async throws {}
    func goBack(tabID: TabID) {}
    func goForward(tabID: TabID) {}
    func reload(tabID: TabID) {}
    func stopLoading(tabID: TabID) {}
    func canGoBack(tabID: TabID) -> Bool { false }
    func canGoForward(tabID: TabID) -> Bool { false }
    func isLoading(tabID: TabID) -> Bool { false }
    func currentURL(tabID: TabID) -> URL? { nil }
    func find(tabID: TabID, query: String, backwards: Bool) async -> FindOutcome { .init(found: false) }
    func clearFindHighlight(tabID: TabID) {}
    func adjustZoom(tabID: TabID, by delta: CGFloat) {}
    func resetZoom(tabID: TabID) {}
    func currentZoom(tabID: TabID) -> CGFloat { 1 }
    func setZoom(tabID: TabID, to zoom: CGFloat) {}
    func printPage(tabID: TabID) {}
    func pagePDF(tabID: TabID) async throws -> Data { throw BrowsemiumError.webContentUnavailable }
    func pageScreenshot(tabID: TabID) async throws -> Data { throw BrowsemiumError.webContentUnavailable }
    func togglePictureInPicture(tabID: TabID) async -> Bool { false }
    func capture(tabID: TabID, request: CaptureRequest) async throws -> CapturedContext {
        capturedTabs.append(tabID)
        throw BrowsemiumError.webContentUnavailable
    }
    func extractArticle(tabID: TabID) async throws -> ReaderArticle { throw BrowsemiumError.webContentUnavailable }
    func fillCredential(tabID: TabID, username: String, password: String) async throws -> Bool { false }
    func evaluateJavaScript(tabID: TabID, script: String) async throws -> Any? { nil }
    func setMuted(tabID: TabID, muted: Bool) {}
    func audioState(tabID: TabID) -> TabAudioState? { nil }
    func apply(_ settings: BrowserSettings) {}
    func applySleepPolicy(tabs: [BrowserTab], signals: [TabID: TabSleepSignals], now: Date) async {}
    func hibernateInactiveTabs() {}
    func beginMemoryPressureMonitoring(handler: @escaping @MainActor (MemoryPressureLevel) -> Void) {}
    func prepareWarmTab() {}
    func setWarmTabPreloading(_ enabled: Bool) {}
    func clearSiteData(dataStoreIdentifier: UUID, includeCache: Bool, modifiedSince: Date) async {}
    func clearCache(dataStoreIdentifier: UUID) async {}
    func removeAllData(dataStoreIdentifier: UUID) async {}
    func removeProfileDataStore(dataStoreIdentifier: UUID) async throws {}
}

@MainActor
private final class DockRenderingDownloads: DownloadReporting {
    func addObserver(_ handler: @escaping (DownloadInfo) -> Void) -> UUID { UUID() }
    func removeObserver(_ token: UUID) {}
    func allDownloads() -> [DownloadInfo] { [] }
}
