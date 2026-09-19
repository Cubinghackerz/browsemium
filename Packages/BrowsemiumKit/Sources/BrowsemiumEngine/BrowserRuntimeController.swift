import BrowsemiumCore
import AppKit
import Foundation
import WebKit

@MainActor
public final class BrowserRuntimeController: BrowserRuntime {
    public var onEvent: ((TabID, TabRuntimeEvent) -> Void)?
    public let downloads = DownloadCoordinator()
    public let captureService: ContentCaptureService
    public let memoryPressure = MemoryPressureCoordinator()
    public let contentRules = ContentRuleListManager()
    public var sleepPolicy: TabSleepPolicy

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
        runtime.onEvent = { [weak self] event in
            self?.onEvent?(tabID, event)
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

    public func find(tabID: TabID, query: String, backwards: Bool = false) async -> Bool {
        await runtimes[tabID]?.find(query, backwards: backwards) ?? false
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

    public func beginMemoryPressureMonitoring(
        handler: @escaping @MainActor (MemoryPressureLevel) -> Void
    ) {
        memoryPressure.start(handler: handler)
    }
}
