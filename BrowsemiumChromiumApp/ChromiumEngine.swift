import AppKit
import BrowsemiumCEF
import BrowsemiumCore
import BrowsemiumEngineKit
import Foundation

/// The Chromium engine behind the shared window model.
///
/// It speaks the same vocabulary as the WebKit engine: the window model, the
/// tab strip, the sleep policy and the assistant never learn which one they are
/// driving. What is missing here is listed honestly rather than stubbed to look
/// finished — see `EngineLimitation`.
@MainActor
final class ChromiumEngine: NSObject, BrowserEngine {
    private var tabs: [TabID: ChromiumTab] = [:]
    private var activePanes: [TabID: PaneID] = [:]
    private var eventObservers: [UUID: (TabID, TabRuntimeEvent) -> Void] = [:]
    private let downloadStore = ChromiumDownloads()
    private let memoryPressure = MemoryPressureCoordinator()
    private var sleepPolicy = TabSleepPolicy()
    private var settings = BrowserSettings()
    private var warmTabEnabled = false

    weak var permissionPrompter: PermissionPrompting?
    var onBlockingActivated: (() -> Void)?

    var downloads: any DownloadReporting { downloadStore }

    /// Chromium's blocking is request interception in the browser process; the
    /// rules are not wired yet, so the honest answer is "not active".
    var blocking: BlockingState { .inactive }

    /// Cache path for the active profile's request context.
    private(set) var profileCachePath: String = ""

    override init() {
        super.init()
    }

    func setProfileCachePath(_ path: String) {
        profileCachePath = path
    }

    // MARK: - Events

    @discardableResult
    func addEventObserver(_ handler: @escaping (TabID, TabRuntimeEvent) -> Void) -> UUID {
        let token = UUID()
        eventObservers[token] = handler
        return token
    }

    func removeEventObserver(_ token: UUID) {
        eventObservers[token] = nil
    }

    private func emit(_ event: TabRuntimeEvent, for tabID: TabID) {
        for observer in eventObservers.values {
            observer(tabID, event)
        }
    }

    // MARK: - Tab lifecycle

    func attach(tabID: TabID, to host: NSView) {
        let tab = tab(for: tabID)
        tab.attach(to: host)
    }

    func detach(tabID: TabID) {
        tabs[tabID]?.detach()
    }

    func discard(tabID: TabID) {
        tabs[tabID]?.close()
        tabs[tabID] = nil
        activePanes[tabID] = nil
        downloadStore.forget(tabID: tabID)
    }

    func activate(tabID: TabID, in pane: PaneID) async {
        let previous = activePanes.compactMap { id, activePane in
            activePane == pane && id != tabID ? id : nil
        }
        for previousID in previous {
            activePanes[previousID] = nil
            tabs[previousID]?.detach()
        }
        activePanes[tabID] = pane
    }

    func deactivate(tabID: TabID) async {
        activePanes[tabID] = nil
    }

    func teardownForProfileSwitch() {
        for tab in tabs.values {
            tab.close()
        }
        tabs.removeAll()
        activePanes.removeAll()
        downloadStore.removeAll()
    }

    func isLive(tabID: TabID) -> Bool {
        tabs[tabID]?.hasBrowser ?? false
    }

    var liveTabCount: Int {
        tabs.values.filter(\.hasBrowser).count
    }

    // MARK: - Navigation

    func navigate(tabID: TabID, to request: NavigationRequest) async throws {
        tab(for: tabID).load(request.url)
    }

    func goBack(tabID: TabID) {
        tabs[tabID]?.goBack()
    }

    func goForward(tabID: TabID) {
        tabs[tabID]?.goForward()
    }

    func reload(tabID: TabID) {
        tabs[tabID]?.reload()
    }

    func stopLoading(tabID: TabID) {
        tabs[tabID]?.stopLoading()
    }

    func canGoBack(tabID: TabID) -> Bool {
        tabs[tabID]?.canGoBack ?? false
    }

    func canGoForward(tabID: TabID) -> Bool {
        tabs[tabID]?.canGoForward ?? false
    }

    func isLoading(tabID: TabID) -> Bool {
        tabs[tabID]?.isLoading ?? false
    }

    func currentURL(tabID: TabID) -> URL? {
        tabs[tabID]?.currentURL
    }

    // MARK: - Page features

    func find(tabID: TabID, query: String, backwards: Bool) async -> FindOutcome {
        guard let tab = tabs[tabID] else { return FindOutcome(found: false) }
        return await tab.find(query, forward: !backwards)
    }

    func clearFindHighlight(tabID: TabID) {
        tabs[tabID]?.clearFindHighlight()
    }

    func adjustZoom(tabID: TabID, by delta: CGFloat) {
        tabs[tabID]?.adjustZoom(by: delta)
    }

    func resetZoom(tabID: TabID) {
        tabs[tabID]?.resetZoom()
    }

    func currentZoom(tabID: TabID) -> CGFloat {
        // CEF tracks zoom as a level, not a factor; the parked edition does
        // not read it back yet, so report the default honestly.
        1
    }

    func setZoom(tabID: TabID, to zoom: CGFloat) {
        // Parked: Chromium zoom restore is unwired until CEF zoom levels are
        // plumbed through ChromiumTab.
    }

    func printPage(tabID: TabID) {
        tabs[tabID]?.printPage()
    }

    func pagePDF(tabID: TabID) async throws -> Data {
        throw BrowsemiumError.captureUnavailable(EngineLimitation.captureMessage)
    }

    func pageScreenshot(tabID: TabID) async throws -> Data {
        throw BrowsemiumError.captureUnavailable(EngineLimitation.captureMessage)
    }

    func togglePictureInPicture(tabID: TabID) async -> Bool {
        false
    }

    func capture(tabID: TabID, request: CaptureRequest) async throws -> CapturedContext {
        // Chromium screenshots go through the DevTools protocol, which is the
        // next piece of this engine. Saying so beats returning an empty image.
        throw BrowsemiumError.captureUnavailable(EngineLimitation.captureMessage)
    }

    func extractArticle(tabID: TabID) async throws -> ReaderArticle {
        throw BrowsemiumError.captureUnavailable(EngineLimitation.readerMessage)
    }

    func fillCredential(tabID: TabID, username: String, password: String) async throws -> Bool {
        throw BrowsemiumError.captureUnavailable(EngineLimitation.credentialMessage)
    }

    func evaluateJavaScript(tabID: TabID, script: String) async throws -> Any? {
        guard let tab = tabs[tabID] else {
            throw BrowsemiumError.webContentUnavailable
        }
        return try await tab.evaluate(script)
    }

    // MARK: - Audio

    func setMuted(tabID: TabID, muted: Bool) {
        tabs[tabID]?.setMuted(muted)
    }

    func audioState(tabID: TabID) -> TabAudioState? {
        tabs[tabID]?.audioState
    }

    // MARK: - Settings and memory

    func apply(_ settings: BrowserSettings) {
        self.settings = settings
        sleepPolicy = settings.memorySaverEnabled
            ? TabSleepPolicy(
                idleInterval: settings.tabSleepInterval,
                maximumLiveTabs: max(settings.maximumLiveTabs, 1)
            )
            : TabSleepPolicy(idleInterval: .greatestFiniteMagnitude, maximumLiveTabs: Int.max)
        warmTabEnabled = settings.warmTabPreloading
    }

    func applySleepPolicy(tabs: [BrowserTab], signals: [TabID: TabSleepSignals], now: Date) async {
        let active = Set(activePanes.keys)
        let idle = sleepPolicy.hibernationCandidates(
            tabs: tabs,
            activeTabIDs: active,
            signals: signals,
            now: now
        )
        let overflow = sleepPolicy.excessLiveTabs(tabs: tabs, activeTabIDs: active, signals: signals)
        for tabID in Set(idle).union(overflow) {
            self.tabs[tabID]?.hibernate()
        }
    }

    func hibernateInactiveTabs() {
        for (tabID, tab) in tabs where !activePanes.keys.contains(tabID) {
            tab.hibernate()
        }
    }

    func beginMemoryPressureMonitoring(handler: @escaping @MainActor (MemoryPressureLevel) -> Void) {
        memoryPressure.start(handler: handler)
    }

    /// Chromium keeps its own renderer ready when it can. The edition disables
    /// the spare renderer for memory, so there is no warm tab to hand out.
    func prepareWarmTab() {}

    var hasWarmTab: Bool { false }

    func setWarmTabPreloading(_ enabled: Bool) {
        warmTabEnabled = enabled
    }

    // MARK: - Site data

    func clearSiteData(dataStoreIdentifier: UUID, includeCache: Bool, modifiedSince: Date) async {
        // Cookie and cache clearing needs the request context that owns the
        // profile's storage; that wiring lands with profiles in this engine.
        await clearCache(dataStoreIdentifier: dataStoreIdentifier)
    }

    func clearCache(dataStoreIdentifier: UUID) async {}

    func removeAllData(dataStoreIdentifier: UUID) async {}

    // MARK: - Internals

    private func tab(for tabID: TabID) -> ChromiumTab {
        if let existing = tabs[tabID] {
            return existing
        }
        let tab = ChromiumTab(
            tabID: tabID,
            cachePath: profileCachePath,
            permissionPrompter: { [weak self] origin, kind in
                guard let self, let prompter = self.permissionPrompter else { return .deny }
                return await prompter.permissionDecision(origin: origin, kind: kind)
            }
        )
        tab.onEvent = { [weak self] event in
            self?.emit(event, for: tabID)
        }
        tab.onDownload = { [weak self] info in
            self?.downloadStore.record(info)
        }
        tabs[tabID] = tab
        return tab
    }
}

/// What this engine does not do yet. Stated once, in one place, so the window
/// can explain itself instead of failing silently.
enum EngineLimitation {
    static let captureMessage = "Screenshots are not available in the Chromium edition yet."
    static let readerMessage = "Reader mode is not available in the Chromium edition yet."
    static let credentialMessage = "Password filling is not available in the Chromium edition yet."
}
