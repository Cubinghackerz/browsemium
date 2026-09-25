import BrowsemiumCore
import BrowsemiumEngineKit
import AppKit
import Foundation
import WebKit

@MainActor
public final class BrowserRuntimeController: BrowserRuntime, BrowserEngine {
    /// The concrete coordinator, which owns the WebKit download delegate.
    private let downloadCoordinator = DownloadCoordinator()
    /// What windows observe. Typed as the protocol so the window model never
    /// names a WebKit type.
    public var downloads: any DownloadReporting { downloadCoordinator }
    public let captureService: ContentCaptureService
    public let memoryPressure = MemoryPressureCoordinator()
    public let contentRules = ContentRuleListManager()
    public var sleepPolicy: TabSleepPolicy
    public private(set) var protectionLevel: ProtectionLevel = .standard
    private var appliedBlocking: Bool?
    private var pausedBlockingHosts: Set<String> = []

    /// Answers camera and microphone requests. Set by the window that owns the
    /// prompt; every runtime in this controller asks it.
    public weak var permissionPrompter: PermissionPrompting? {
        didSet {
            for runtime in runtimes.values {
        runtime.permissionPrompter = permissionPrompter
        runtime.blockingPausedHosts = { [weak self] in
            self?.pausedBlockingHosts ?? []
        }
        runtime.applyProtection(protectionLevel)
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
        WebViewFactory.protectionLevel = settings.protectionLevel

        if protectionLevel != settings.protectionLevel {
            protectionLevel = settings.protectionLevel
            warmPool.release()
            if settings.warmTabPreloading {
                warmPool.prepare()
            }
            for runtime in runtimes.values {
                runtime.applyProtection(settings.protectionLevel)
            }
        }

        if settings.contentBlockingEnabled {
            contentRules.activate()
        } else {
            contentRules.deactivate()
        }

        if appliedBlocking != settings.contentBlockingEnabled {
            appliedBlocking = settings.contentBlockingEnabled
            applyRulesToOpenTabs()
        }
    }

    public var liveWebViewCount: Int {
        runtimes.values.filter(\.hasLiveWebView).count
    }

    // MARK: - BrowserEngine conformance

    /// Whether the tab currently holds a live web view.
    public func isLive(tabID: TabID) -> Bool {
        runtimes[tabID]?.hasLiveWebView ?? false
    }

    public var liveTabCount: Int {
        liveWebViewCount
    }

    public func currentURL(tabID: TabID) -> URL? {
        runtimes[tabID]?.currentWebView?.url
    }

    /// Runs a script in the page and returns its value. WebKit needs the page's
    /// content world, which is what `callAsyncJavaScript` uses here.
    public func evaluateJavaScript(tabID: TabID, script: String) async throws -> Any? {
        guard let webView = runtimes[tabID]?.currentWebView else {
            throw BrowsemiumError.webContentUnavailable
        }
        return try await webView.callAsyncJavaScript(
            script,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
    }

    /// Blocking as the window sees it. WebKit reports rule state but not how
    /// many requests it stopped, so no count is offered here.
    public var blocking: BlockingState {
        switch contentRules.state {
        case .inactive: .inactive
        case .compiling: .compiling
        case .active: .active(ruleCount: contentRules.ruleCount)
        case .failed(let message): .failed(message)
        }
    }

    public var onBlockingActivated: (() -> Void)? {
        get { contentRules.onActivated }
        set { contentRules.onActivated = newValue }
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
            isPrivate: isPrivate || isPrivateBrowsingEnabled,
            factory: factory,
            warmPool: warmPool,
            contentRules: contentRules,
            captureService: captureService,
            downloadCoordinator: downloadCoordinator
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

    public func setContentRulesPaused(tabID: TabID, paused: Bool) {
        runtimes[tabID]?.setContentRulesSuppressed(paused)
    }

    public func replacePausedBlockingHosts(_ hosts: Set<String>) {
        pausedBlockingHosts = Set(hosts.map { $0.lowercased() })
        for runtime in runtimes.values where !runtime.isPrivate {
            guard let host = runtime.currentWebView?.url?.host?.lowercased() else { continue }
            runtime.setContentRulesSuppressed(pausedBlockingHosts.contains(host))
        }
    }

    public func isBlockingPaused(host: String) -> Bool {
        pausedBlockingHosts.contains(host.lowercased())
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

    public func goBack(tabID: TabID) {
        runtimes[tabID]?.goBack()
    }

    public func goForward(tabID: TabID) {
        runtimes[tabID]?.goForward()
    }

    public func reload(tabID: TabID) {
        runtimes[tabID]?.reload()
    }

    public func stopLoading(tabID: TabID) {
        runtimes[tabID]?.stopLoading()
    }

    public func canGoBack(tabID: TabID) -> Bool {
        runtimes[tabID]?.canGoBack ?? false
    }

    public func canGoForward(tabID: TabID) -> Bool {
        runtimes[tabID]?.canGoForward ?? false
    }

    public func isLoading(tabID: TabID) -> Bool {
        runtimes[tabID]?.isLoading ?? false
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

    public func find(tabID: TabID, query: String, backwards: Bool = false) async -> FindOutcome {
        let found = await runtimes[tabID]?.find(query, backwards: backwards) ?? false
        // WebKit reports whether it matched, not how many times.
        return FindOutcome(found: found, matchCount: nil)
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

    public func currentZoom(tabID: TabID) -> CGFloat {
        runtimes[tabID]?.currentZoom ?? 1
    }

    public func setZoom(tabID: TabID, to zoom: CGFloat) {
        runtimes[tabID]?.setZoom(zoom)
    }

    public func printPage(tabID: TabID) {
        runtimes[tabID]?.printPage()
    }

    public func pagePDF(tabID: TabID) async throws -> Data {
        guard let runtime = runtimes[tabID] else {
            throw BrowsemiumError.webContentUnavailable
        }
        return try await runtime.renderPDF()
    }

    public func pageScreenshot(tabID: TabID) async throws -> Data {
        guard let runtime = runtimes[tabID] else {
            throw BrowsemiumError.webContentUnavailable
        }
        return try await runtime.renderScreenshot()
    }

    public func togglePictureInPicture(tabID: TabID) async -> Bool {
        guard let runtime = runtimes[tabID] else { return false }
        return await runtime.togglePictureInPicture()
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

    // MARK: - Private browsing

    /// Whether new web views go into private mode. A private runtime uses
    /// `WKWebsiteDataStore.nonPersistent()`: cookies, caches, and site
    /// storage die with the tab.
    public private(set) var isPrivateBrowsingEnabled = false

    public func setPrivateBrowsing(_ isPrivate: Bool) {
        guard isPrivateBrowsingEnabled != isPrivate else { return }
        isPrivateBrowsingEnabled = isPrivate
        // Existing web views belong to the other mode. Reusing a persistent
        // web view in a private session — or the reverse — would leak exactly
        // what the mode promises not to keep, so they are dropped instead.
        for runtime in runtimes.values {
            runtime.hibernate()
        }
        runtimes.removeAll()
        activePanes.removeAll()
        warmPool.release()
    }

    /// Whether a tab's web view is running against an ephemeral store.
    public func isPrivateRuntime(tabID: TabID) -> Bool {
        runtimes[tabID]?.isPrivate ?? false
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

    /// Deletes the persistent store container itself. WebKit requires every
    /// WKWebView using the identifier to have been released before this call.
    public func removeProfileDataStore(dataStoreIdentifier: UUID) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            WKWebsiteDataStore.remove(forIdentifier: dataStoreIdentifier) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
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
