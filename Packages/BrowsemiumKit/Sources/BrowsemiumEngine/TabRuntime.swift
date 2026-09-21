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
    public private(set) var audioState = TabAudioState(isPlaying: false, isMuted: false)

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
        // Audio state is reported by an injected script. The handler is added
        // before the first real navigation, so nothing is missed.
        let proxy = TabAudioMessageProxy(runtime: self)
        view.configuration.userContentController.addUserScript(TabAudioMonitor.makeUserScript())
        view.configuration.userContentController.add(proxy, name: TabAudioMonitor.messageHandlerName)
        audioProxy = proxy
        let hoverProxy = LinkHoverMessageProxy(runtime: self)
        view.configuration.userContentController.addUserScript(LinkHoverMonitor.makeUserScript())
        view.configuration.userContentController.add(hoverProxy, name: LinkHoverMonitor.messageHandlerName)
        linkHoverProxy = hoverProxy
        progressObservation = view.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor [weak self] in
                self?.report(.progressChanged(webView.estimatedProgress))
            }
        }
        webView = view
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
        guard let webView, let ruleList = contentRules?.compiledRuleList else { return }
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        controller.add(ruleList)
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
          var video = document.querySelector('video');
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
        case .crashed:
            setLifecycle(.crashed)
        case .progressChanged, .requestedNewWindow, .requestedExternalScheme, .downloadStarted, .downloadFinished, .downloadFailed, .audioStateChanged, .requestedAISelection, .lifecycleChanged, .linkHovered:
            break
        }
        onEvent?(event)
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
