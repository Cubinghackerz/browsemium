import BrowsemiumCore
import AppKit
import Foundation
import WebKit

@MainActor
public final class BrowserRuntimeController: BrowserRuntime {
    public let downloads = DownloadCoordinator()
    public let captureService: ContentCaptureService
    public let memoryPressure = MemoryPressureCoordinator()
    public let contentRules = ContentRuleListManager()
    public var sleepPolicy: TabSleepPolicy

    /// Answers camera and microphone requests. Set by the window that owns the
    /// prompt; every runtime in this controller asks it.
    public weak var permissionPrompter: PermissionPrompting? {
        didSet {
            for runtime in runtimes.values {
                runtime.permissionPrompter = permissionPrompter
            }
        }
    }

    /// Window models register here rather than assigning a single callback:
    /// with two windows open, the last one to register used to receive every
    /// event and the first went silent.
    private var eventObservers: [UUID: (TabID, TabRuntimeEvent) -> Void] = [:]

    @discardableResult
    public func addEventObserver(_ handler: @escaping (TabID, TabRuntimeEvent) -> Void) -> UUID {
        let token = UUID()
        eventObservers[token] = handler
        return token
    }

    public func removeEventObserver(_ token: UUID) {
        eventObservers[token] = nil
    }

    private let factory = WebViewFactory()
    private let warmPool: WarmWebViewPool
    private var runtimes: [TabID: TabRuntime] = [:]
    private var activePanes: [TabID: PaneID] = [:]

    public init(
        capturePolicy: ContentCaptureService.Policy = ContentCaptureService.Policy(),
        sleepPolicy: TabSleepPolicy = TabSleepPolicy()
    ) {
        captureService = ContentCaptureService(policy: capturePolicy)
        self.sleepPolicy = sleepPolicy
        warmPool = WarmWebViewPool(factory: factory)
        WebViewFactory.contentRuleListProvider = { [weak self] configuration in
            self?.contentRules.apply(to: configuration)
        }
        contentRules.onActivated = { [weak self] in
            self?.applyRulesToOpenTabs()
        }
    }

    /// Rules only affect a page at navigation time, so hand them to the web
    /// views that are already open. They take effect on the next load.
    private func applyRulesToOpenTabs() {
        for runtime in runtimes.values {
            runtime.applyContentRules()
        }
    }

    /// Keeps one idle WebKit view ready so new tabs open faster.
    public func prepareWarmTab() {
        warmPool.prepare()
    }

    public var hasWarmTab: Bool {
        warmPool.hasSpare
    }

    public func setWarmTabPreloading(_ enabled: Bool) {
        warmPool.setEnabled(enabled)
    }

    /// Applies a settings change to live behaviour. Cheap and idempotent, so
    /// it is safe to call whenever settings are saved.
    public func apply(_ settings: BrowserSettings) {
        sleepPolicy = settings.memorySaverEnabled
            ? TabSleepPolicy(
                idleInterval: settings.tabSleepInterval,
                maximumLiveTabs: max(settings.maximumLiveTabs, 1)
            )
            : TabSleepPolicy(idleInterval: .greatestFiniteMagnitude, maximumLiveTabs: Int.max)

        warmPool.setEnabled(settings.warmTabPreloading)

        if settings.contentBlockingEnabled {
            contentRules.activate()
        } else {
            contentRules.deactivate()
        }
    }

    public var liveWebViewCount: Int {
        runtimes.values.filter(\.hasLiveWebView).count
    }

    public var activeTabIDs: Set<TabID> {
        Set(activePanes.keys)
    }

    public func runtime(for tabID: TabID, isPrivate: Bool = false) -> TabRuntime {
        if let existing = runtimes[tabID] {
            return existing
        }
        let runtime = TabRuntime(
            tabID: tabID,
            isPrivate: isPrivate,
            factory: factory,
            warmPool: warmPool,
            contentRules: contentRules,
            captureService: captureService,
            downloadCoordinator: downloads
        )
        runtime.permissionPrompter = permissionPrompter
        runtime.onEvent = { [weak self] event in
            guard let self else { return }
            for observer in self.eventObservers.values {
                observer(tabID, event)
            }
        }
        runtimes[tabID] = runtime
        return runtime
    }

    public func webView(for tabID: TabID) -> WKWebView? {
        runtimes[tabID]?.currentWebView
    }

    public func attach(tabID: TabID, to host: NSView) {
        let runtime = runtime(for: tabID)
        let view = runtime.ensureWebView()
        if view.superview !== host {
            view.removeFromSuperview()
            view.frame = host.bounds
            view.autoresizingMask = [.width, .height]
            host.addSubview(view)
        }
    }

    public func detach(tabID: TabID) {
        runtimes[tabID]?.suspend()
    }

    public func discard(tabID: TabID) {
        runtimes[tabID]?.hibernate()
        runtimes[tabID] = nil
        activePanes[tabID] = nil
    }

    public func activate(tabID: TabID, in pane: PaneID) async {
        let previousTabs = activePanes.compactMap { id, activePane in
            activePane == pane && id != tabID ? id : nil
        }
        for previousID in previousTabs {
            activePanes[previousID] = nil
            runtimes[previousID]?.suspend()
        }
        activePanes[tabID] = pane
    }

    public func deactivate(tabID: TabID) async {
        activePanes[tabID] = nil
    }

    public func navigate(tabID: TabID, to request: NavigationRequest) async throws {
        let runtime = runtime(for: tabID)
        runtime.load(request.url)
    }

    public func suspend(tabID: TabID) async {
        runtimes[tabID]?.suspend()
    }

    public func hibernate(tabID: TabID) async {
        runtimes[tabID]?.hibernate()
    }

    public func capture(tabID: TabID, request: CaptureRequest) async throws -> CapturedContext {
        guard let runtime = runtimes[tabID] else {
            throw BrowsemiumError.webContentUnavailable
        }
        return try await runtime.capture(request)
    }

    public func extractArticle(tabID: TabID) async throws -> ReaderArticle {
        guard let webView = runtimes[tabID]?.currentWebView else {
            throw BrowsemiumError.webContentUnavailable
        }
        return try await captureService.extractArticle(from: webView)
    }

    public func find(tabID: TabID, query: String, backwards: Bool = false) async -> Bool {
        await runtimes[tabID]?.find(query, backwards: backwards) ?? false
    }

    public func setMuted(tabID: TabID, muted: Bool) {
        runtimes[tabID]?.setMuted(muted)
    }

    public func audioState(tabID: TabID) -> TabAudioState? {
        runtimes[tabID]?.audioState
    }

    public func clearFindHighlight(tabID: TabID) {
        runtimes[tabID]?.clearFindHighlight()
    }

    public func adjustZoom(tabID: TabID, by delta: CGFloat) {
        runtimes[tabID]?.adjustZoom(by: delta)
    }

    public func resetZoom(tabID: TabID) {
        runtimes[tabID]?.resetZoom()
    }

    public func printPage(tabID: TabID) {
        runtimes[tabID]?.printPage()
    }

    public func fillCredential(tabID: TabID, username: String, password: String) async throws -> Bool {
        guard let runtime = runtimes[tabID] else {
            throw BrowsemiumError.webContentUnavailable
        }
        return try await runtime.fillCredential(username: username, password: password)
    }

    public func applySleepPolicy(
        tabs: [BrowserTab],
        signals: [TabID: TabSleepSignals] = [:],
        now: Date = Date()
    ) async {
        let active = activeTabIDs
        let idleCandidates = sleepPolicy.hibernationCandidates(
            tabs: tabs,
            activeTabIDs: active,
            signals: signals,
            now: now
        )
        let overflowCandidates = sleepPolicy.excessLiveTabs(
            tabs: tabs,
            activeTabIDs: active,
            signals: signals
        )
        for tabID in Set(idleCandidates).union(overflowCandidates) {
            runtimes[tabID]?.hibernate()
        }
    }

    public func hibernateInactiveTabs() {
        for (tabID, runtime) in runtimes where !activeTabIDs.contains(tabID) {
            runtime.hibernate()
        }
        warmPool.release()
    }

    /// Drops every web view and the warm spare. Used when the active profile
    /// changes: existing web views belong to the previous profile's WebKit
    /// data store and must never be reused.
    public func teardownForProfileSwitch() {
        for runtime in runtimes.values {
            runtime.hibernate()
        }
        runtimes.removeAll()
        activePanes.removeAll()
        warmPool.release()
    }

    public func beginMemoryPressureMonitoring(
        handler: @escaping @MainActor (MemoryPressureLevel) -> Void
    ) {
        memoryPressure.start(handler: handler)
    }

    // MARK: - Site data

    /// Everything a site can leave behind in one profile's data store.
    public nonisolated static func siteDataTypes(includeCache: Bool) -> Set<String> {
        var types: Set<String> = [
            WKWebsiteDataTypeCookies,
            WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeIndexedDBDatabases,
            WKWebsiteDataTypeWebSQLDatabases,
            WKWebsiteDataTypeServiceWorkerRegistrations,
            WKWebsiteDataTypeFileSystem,
            WKWebsiteDataTypeMediaKeys
        ]
        if includeCache {
            types.formUnion(cacheDataTypes())
        }
        return types
    }

    /// Only the caches. Kept separate so "clear cache" does not sign the user
    /// out of every site.
    public nonisolated static func cacheDataTypes() -> Set<String> {
        [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeFetchCache
        ]
    }

    /// Removes cookies, site storage, and optionally cache for one profile.
    /// Addressed by data-store identifier, so it works with no tabs open and
    /// never touches another profile.
    public func clearSiteData(
        dataStoreIdentifier: UUID,
        includeCache: Bool = true,
        modifiedSince: Date = .distantPast
    ) async {
        await remove(
            types: Self.siteDataTypes(includeCache: includeCache),
            from: dataStoreIdentifier,
            modifiedSince: modifiedSince
        )
    }

    /// Removes only cached responses for one profile.
    public func clearCache(dataStoreIdentifier: UUID) async {
        await remove(types: Self.cacheDataTypes(), from: dataStoreIdentifier, modifiedSince: .distantPast)
    }

    /// Removes every kind of data WebKit holds for a profile. Used when a
    /// profile is deleted, so its logins do not outlive it.
    public func removeAllData(dataStoreIdentifier: UUID) async {
        await remove(
            types: WKWebsiteDataStore.allWebsiteDataTypes(),
            from: dataStoreIdentifier,
            modifiedSince: .distantPast
        )
    }

    private func remove(types: Set<String>, from dataStoreIdentifier: UUID, modifiedSince: Date) async {
        let store = WKWebsiteDataStore(forIdentifier: dataStoreIdentifier)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: types, modifiedSince: modifiedSince) {
                continuation.resume()
            }
        }
    }
}
