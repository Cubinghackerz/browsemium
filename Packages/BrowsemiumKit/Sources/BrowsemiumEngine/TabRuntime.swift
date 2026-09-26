import AppKit
import BrowsemiumCore
import BrowsemiumEngineKit
import Foundation
import WebKit


@MainActor
public final class TabRuntime {
    public let tabID: TabID
    public let isPrivate: Bool
    public private(set) var lifecycle: TabLifecycle = .metadataOnly
    public private(set) var lastCommittedURL: URL?
    public private(set) var lastRequestedURL: URL?
    public private(set) var title: String?

    private let factory: WebViewFactory
    private let warmPool: WarmWebViewPool?
    private let contentRules: ContentRuleListManager?
    private let captureService: ContentCaptureService
    private let downloadCoordinator: DownloadCoordinator
    private let navigationDelegate: WebNavigationDelegate
    private let uiDelegate: WebUIDelegate
    private var webView: WKWebView?
    private var progressObservation: NSKeyValueObservation?
    private var audioProxy: TabAudioMessageProxy?
    private var linkHoverProxy: LinkHoverMessageProxy?
    private var pickerProxy: ElementPickerMessageProxy?
    /// Per-host cosmetic CSS, pushed by the runtime controller. Baked into a
    /// document-start script so saved rules apply before first paint.
    private var cosmeticRulesByHost: [String: String] = [:]
    /// Dedupes the double new-window report WebKit produces for one click:
    /// `decidePolicyFor` (targetFrame == nil) fires first, then `createWebViewWith`.
    /// Without this, one ⌘-click opens a peek, discards it, and reopens it —
    /// and one plain click on a `target=_blank` link opens two tabs.
    private var lastWindowRequest: (url: URL, isPeek: Bool, at: Date)?
    public private(set) var audioState = TabAudioState(isPlaying: false, isMuted: false)
    public private(set) var protectionLevel: ProtectionLevel = .standard
    var blockingPausedHosts: () -> Set<String> = { [] }
    private var contentRulesSuppressed = false

    public var onEvent: ((TabRuntimeEvent) -> Void)?

    /// Asked before a page is granted the camera or the microphone. Weak so a
    /// closed window never keeps a prompt alive.
    public weak var permissionPrompter: PermissionPrompting?

    public init(
        tabID: TabID,
        isPrivate: Bool,
        factory: WebViewFactory,
        warmPool: WarmWebViewPool? = nil,
        contentRules: ContentRuleListManager? = nil,
        captureService: ContentCaptureService,
        downloadCoordinator: DownloadCoordinator
    ) {
        self.tabID = tabID
        self.isPrivate = isPrivate
        self.factory = factory
        self.warmPool = warmPool
        self.contentRules = contentRules
        self.captureService = captureService
        self.downloadCoordinator = downloadCoordinator
        let navigationDelegate = WebNavigationDelegate()
        let uiDelegate = WebUIDelegate()
        self.navigationDelegate = navigationDelegate
        self.uiDelegate = uiDelegate
        navigationDelegate.runtime = self
        uiDelegate.runtime = self
    }

    public var hasLiveWebView: Bool {
        webView != nil
    }

    public var currentWebView: WKWebView? {
        webView
    }

    public var isLoading: Bool {
        webView?.isLoading ?? false
    }

    public var canGoBack: Bool {
        webView?.canGoBack ?? false
    }

    public var canGoForward: Bool {
        webView?.canGoForward ?? false
    }

    @discardableResult
    public func ensureWebView() -> WKWebView {
        if let webView {
            return webView
        }
        let store: WebViewFactory.Store = isPrivate ? .ephemeral : .persistent
        // Adopt the pre-warmed view when one is ready: its WebKit process is
        // already running, so the first paint comes sooner.
        let view = (isPrivate ? nil : warmPool?.take()) ?? factory.makeWebView(store: store)
        view.navigationDelegate = navigationDelegate
        view.uiDelegate = uiDelegate
        // Audio state, link hover, and element picking are reported by
        // injected scripts. The handlers are added before the first real
        // navigation, so nothing is missed.
        let proxy = TabAudioMessageProxy(runtime: self)
        view.configuration.userContentController.add(proxy, name: TabAudioMonitor.messageHandlerName)
        audioProxy = proxy
        let hoverProxy = LinkHoverMessageProxy(runtime: self)
        view.configuration.userContentController.add(hoverProxy, name: LinkHoverMonitor.messageHandlerName)
        linkHoverProxy = hoverProxy
        let picker = ElementPickerMessageProxy(runtime: self)
        view.configuration.userContentController.add(picker, name: ElementPicker.messageHandlerName)
        pickerProxy = picker
        installUserScripts(on: view)
        progressObservation = view.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor [weak self] in
                self?.report(.progressChanged(webView.estimatedProgress))
            }
        }
        webView = view
        applyProtection(protectionLevel)
        return view
    }

    /// Applies the tab's mute state to the page. Called on user action and
    /// again after each navigation, since a fresh document starts unmuted.
    public func setMuted(_ muted: Bool) {
        audioState = TabAudioState(
            isPlaying: muted ? false : audioState.isPlaying,
            isMuted: muted,
            isCapturingMedia: audioState.isCapturingMedia
        )
        report(.audioStateChanged(audioState))
        guard let webView else { return }
        webView.evaluateJavaScript("window.__browsemiumSetMuted && window.__browsemiumSetMuted(\(muted ? "true" : "false"))")
    }

    /// Rebuilds the injected script set. `removeAllUserScripts` is the only
    /// removal API WebKit offers, so every script is re-added together.
    private func installUserScripts(on view: WKWebView) {
        let controller = view.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(TabAudioMonitor.makeUserScript())
        controller.addUserScript(LinkHoverMonitor.makeUserScript())
        controller.addUserScript(ElementPicker.makeUserScript())
        controller.addUserScript(CosmeticRulesScript.makeUserScript(rulesByHost: cosmeticRulesByHost))
    }

    /// Applies the per-host cosmetic rules: future navigations get them at
    /// document start, and the page on screen is updated in place so no tab
    /// reloads for a rule change.
    public func applyCosmeticRules(_ rulesByHost: [String: String]) {
        cosmeticRulesByHost = rulesByHost
        guard let view = webView else { return }
        installUserScripts(on: view)
        let host = (view.url?.host ?? "").lowercased()
        let css = rulesByHost[host] ?? ""
        view.evaluateJavaScript(
            "window.__browsemiumApplyCosmeticRules && window.__browsemiumApplyCosmeticRules(\(CosmeticRulesScript.jsLiteral(css)))"
        )
    }

    public func beginElementPicking() {
        guard let view = webView else { return }
        view.evaluateJavaScript("window.__browsemiumElementPicker && window.__browsemiumElementPicker.start()")
    }

    public func cancelElementPicking() {
        webView?.evaluateJavaScript("window.__browsemiumElementPicker && window.__browsemiumElementPicker.stop()")
    }

    func updatePickedElement(selector: String, label: String, matchCount: Int) {
        report(.elementPicked(ElementPick(selector: selector, label: label, matchCount: matchCount)))
    }

    func updateElementPickCancelled() {
        report(.elementPickCancelled)
    }

    func updateElementPickFailed() {
        report(.elementPickFailed)
    }

    func updateAudioState(isPlaying: Bool, isMuted: Bool, isCapturingMedia: Bool = false) {
        let state = TabAudioState(
            isPlaying: isMuted ? false : isPlaying,
            isMuted: isMuted,
            isCapturingMedia: isCapturingMedia
        )
        guard state != audioState else { return }
        audioState = state
        report(.audioStateChanged(state))
    }

    /// Resolves a media-capture request for one kind. Denies when no window is
    /// available to ask, which is the safe default.
    func mediaCaptureDecision(origin: String, kind: SitePermissionKind) async -> SitePermissionDecision {
        guard let permissionPrompter else { return .deny }
        return await permissionPrompter.permissionDecision(origin: origin, kind: kind)
    }

    @discardableResult
    public func load(_ url: URL) -> WKNavigation? {
        let view = ensureWebView()
        lastRequestedURL = url
        setLifecycle(.loading)
        return view.load(URLRequest(url: url))
    }

    public func goBack() {
        webView?.goBack()
    }

    public func goForward() {
        webView?.goForward()
    }

    public func reload() {
        webView?.reload()
    }

    public func stopLoading() {
        webView?.stopLoading()
        if lifecycle == .loading {
            setLifecycle(lastCommittedURL == nil ? .metadataOnly : .suspended)
        }
    }

    public func suspend() {
        webView?.removeFromSuperview()
        if lifecycle != .metadataOnly && lifecycle != .hibernated {
            setLifecycle(.suspended)
        }
    }

    public func hibernate() {
        progressObservation?.invalidate()
        progressObservation = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        setLifecycle(.hibernated)
    }

    public func find(_ query: String, backwards: Bool = false) async -> Bool {
        guard let webView, !query.isEmpty else { return false }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        return await withCheckedContinuation { continuation in
            webView.find(query, configuration: configuration) { result in
                continuation.resume(returning: result.matchFound)
            }
        }
    }

    /// Adds the compiled content rules to this tab's existing web view so the
    /// next navigation is filtered without recreating the tab.
    public func applyContentRules() {
        guard let webView else { return }
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        guard !contentRulesSuppressed, protectionLevel.blocksContentRules,
              let ruleList = contentRules?.compiledRuleList else { return }
        controller.add(ruleList)
    }

    public func setContentRulesSuppressed(_ suppressed: Bool) {
        contentRulesSuppressed = suppressed
        applyContentRules()
    }

    func applyBlockingPause(forHost host: String) {
        let paused = !isPrivate && blockingPausedHosts().contains(host.lowercased())
        setContentRulesSuppressed(paused)
    }

    public func applyProtection(_ level: ProtectionLevel) {
        protectionLevel = level
        navigationDelegate.protectionLevel = level
        guard let webView else { return }
        WebViewFactory.applyPrivacyDefaults(to: webView.configuration)
        applyContentRules()
    }

    /// Clears the find highlight WebKit leaves behind.
    public func clearFindHighlight() {
        guard let webView else { return }
        webView.evaluateJavaScript("window.getSelection && window.getSelection().removeAllRanges();")
    }

    public var currentZoom: CGFloat {
        webView?.pageZoom ?? 1
    }

    public func adjustZoom(by delta: CGFloat) {
        guard let webView else { return }
        webView.pageZoom = min(max(webView.pageZoom + delta, 0.5), 3)
    }

    public func setZoom(_ zoom: CGFloat) {
        webView?.pageZoom = min(max(zoom, 0.5), 3)
    }

    public func resetZoom() {
        webView?.pageZoom = 1
    }

    /// The hovered link a page last reported, surfaced as a status-bar event.
    func updateHoveredLink(_ url: URL?) {
        report(.linkHovered(url))
    }

    public func printPage() {
        guard let webView else { return }
        webView.printOperation(with: NSPrintInfo.shared).run()
    }

    /// The whole scrollable page as PDF data. WKPDFConfiguration's default
    /// rect is the full page, not just the viewport.
    public func renderPDF() async throws -> Data {
        guard let webView else {
            throw BrowsemiumError.webContentUnavailable
        }
        return try await webView.pdf(configuration: WKPDFConfiguration())
    }

    /// The visible viewport as PNG data.
    public func renderScreenshot() async throws -> Data {
        guard let webView else {
            throw BrowsemiumError.webContentUnavailable
        }
        let image = try await webView.takeSnapshot(configuration: nil)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw BrowsemiumError.webContentUnavailable
        }
        return png
    }

    /// Toggles Picture in Picture on the page's first video, if WebKit's
    /// presentation-mode API allows it. Reports honestly when it cannot.
    public func togglePictureInPicture() async -> Bool {
        guard let webView else { return false }
        let script = """
        (function() {
          // The first <video> in DOM order is often a decorative background
          // clip; the one actually playing is the one the user means.
          var videos = document.querySelectorAll('video');
          var video = null;
          for (var i = 0; i < videos.length; i++) {
            if (!videos[i].paused && !videos[i].ended) { video = videos[i]; break; }
          }
          if (!video) { video = videos[0] || null; }
          if (!video) { return 'no-video'; }
          try {
            if (video.webkitSupportsPresentationMode
                && video.webkitSupportsPresentationMode('picture-in-picture')) {
              var inPiP = video.webkitPresentationMode === 'picture-in-picture';
              video.webkitSetPresentationMode(inPiP ? 'inline' : 'picture-in-picture');
              return inPiP ? 'exited' : 'entered';
            }
          } catch (error) {}
          return 'unsupported';
        })()
        """
        let result = try? await webView.evaluateJavaScript(script) as? String
        return result == "entered" || result == "exited"
    }

    public func capture(_ request: CaptureRequest) async throws -> CapturedContext {
        guard let webView else {
            throw BrowsemiumError.webContentUnavailable
        }
        return try await captureService.capture(request, from: webView, tabID: tabID)
    }

    public func fillCredential(username: String, password: String) async throws -> Bool {
        guard let webView else {
            throw BrowsemiumError.webContentUnavailable
        }
        let script = """
        const visible = element => {
          const style = window.getComputedStyle(element);
          const rect = element.getBoundingClientRect();
          return style.visibility !== 'hidden' && style.display !== 'none' && rect.width > 0 && rect.height > 0;
        };
        const passwordField = [...document.querySelectorAll('input[type="password"]')].find(visible);
        if (!passwordField) return false;
        const form = passwordField.form || document;
        const usernameField = [...form.querySelectorAll('input[autocomplete="username"], input[type="email"], input[type="text"]')].find(visible);
        const setValue = (field, value) => {
          if (!field) return;
          const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
          setter ? setter.call(field, value) : field.value = value;
          field.dispatchEvent(new Event('input', { bubbles: true }));
          field.dispatchEvent(new Event('change', { bubbles: true }));
        };
        setValue(usernameField, username);
        setValue(passwordField, password);
        passwordField.focus();
        return true;
        """
        let result = try await webView.callAsyncJavaScript(
            script,
            arguments: ["username": username, "password": password],
            in: nil,
            contentWorld: .page
        )
        return result as? Bool ?? false
    }

    /// Entry point for runtime state changes. Navigation and UI delegates call
    /// it; it is also public so a host can report state it observed itself.
    public func report(_ event: TabRuntimeEvent) {
        switch event {
        case .requestedPeek(let url):
            if isDuplicateWindowRequest(url: url, isPeek: true) { return }
        case .requestedNewWindow(let url):
            if isDuplicateWindowRequest(url: url, isPeek: false) { return }
        case .startedLoading:
            setLifecycle(.loading)
        case .committed(let url):
            if let url {
                lastCommittedURL = url
            }
        case .finished(_, let url):
            if let url {
                lastCommittedURL = url
            }
            setLifecycle(.active)
        case .failed:
            setLifecycle(lastCommittedURL == nil ? .metadataOnly : .crashed)
        case .cancelled:
            // A cancelled navigation changed nothing: whatever was committed
            // (if anything) is still the page, and the lifecycle is untouched.
            break
        case .crashed:
            setLifecycle(.crashed)
        case .progressChanged, .requestedExternalScheme, .downloadStarted, .downloadFinished, .downloadFailed, .audioStateChanged, .requestedAISelection, .lifecycleChanged, .linkHovered, .elementPicked, .elementPickCancelled, .elementPickFailed:
            break
        }
        onEvent?(event)
    }

    /// True when the same window/peek request arrived again within the
    /// dedupe window — WebKit's double report for a single user click.
    private func isDuplicateWindowRequest(url: URL, isPeek: Bool) -> Bool {
        let now = Date()
        if let last = lastWindowRequest,
           last.isPeek == isPeek,
           last.url == url,
           now.timeIntervalSince(last.at) < 0.15 {
            return true
        }
        lastWindowRequest = (url, isPeek, now)
        return false
    }

    /// The only place `lifecycle` is assigned, so every change reaches the
    /// model. Hibernation happens on a timer rather than a navigation, and
    /// without this the tab strip, the stats card, and the sleep policy all
    /// kept believing the tab was still loaded.
    private func setLifecycle(_ value: TabLifecycle) {
        guard lifecycle != value else { return }
        lifecycle = value
        onEvent?(.lifecycleChanged(value))
    }

    func handleDidFinish(_ webView: WKWebView) {
        title = webView.title
        report(.finished(title: webView.title, url: webView.url))
        // A new document starts unmuted; restore the tab's mute state.
        if audioState.isMuted {
            setMuted(true)
        }
    }

    func adoptDownload(_ download: WKDownload) {
        downloadCoordinator.adopt(download, tabID: tabID) { [weak self] event in
            self?.report(event)
        }
    }
}
