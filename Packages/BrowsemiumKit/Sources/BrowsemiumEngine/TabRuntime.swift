import AppKit
import BrowsemiumCore
import Foundation
import WebKit

public enum TabRuntimeEvent: Sendable {
    case startedLoading(URL?)
    case committed(URL?)
    case finished(title: String?, url: URL?)
    case failed(String)
    case crashed
    case progressChanged(Double)
    case requestedNewWindow(URL)
    case requestedExternalScheme(URL)
    case downloadStarted(UUID)
    case downloadFinished(UUID)
    case downloadFailed(UUID, String)
    case audioStateChanged(TabAudioState)
}

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
    public private(set) var audioState = TabAudioState(isPlaying: false, isMuted: false)

    public var onEvent: ((TabRuntimeEvent) -> Void)?

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
        view.configuration.userContentController.addUserScript(TabAudioMonitor.userScript)
        view.configuration.userContentController.add(proxy, name: TabAudioMonitor.messageHandlerName)
        audioProxy = proxy
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
        audioState = TabAudioState(isPlaying: muted ? false : audioState.isPlaying, isMuted: muted)
        report(.audioStateChanged(audioState))
        guard let webView else { return }
        webView.evaluateJavaScript("window.__browsemiumSetMuted && window.__browsemiumSetMuted(\(muted ? "true" : "false"))")
    }

    func updateAudioState(isPlaying: Bool, isMuted: Bool) {
        let state = TabAudioState(isPlaying: isMuted ? false : isPlaying, isMuted: isMuted)
        guard state != audioState else { return }
        audioState = state
        report(.audioStateChanged(state))
    }

    @discardableResult
    public func load(_ url: URL) -> WKNavigation? {
        let view = ensureWebView()
        lastRequestedURL = url
        lifecycle = .loading
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
            lifecycle = lastCommittedURL == nil ? .metadataOnly : .suspended
        }
    }

    public func suspend() {
        webView?.removeFromSuperview()
        if lifecycle != .metadataOnly && lifecycle != .hibernated {
            lifecycle = .suspended
        }
    }

    public func hibernate() {
        progressObservation?.invalidate()
        progressObservation = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        lifecycle = .hibernated
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

    public func adjustZoom(by delta: CGFloat) {
        guard let webView else { return }
        webView.pageZoom = min(max(webView.pageZoom + delta, 0.5), 3)
    }

    public func resetZoom() {
        webView?.pageZoom = 1
    }

    public func printPage() {
        guard let webView else { return }
        webView.printOperation(with: NSPrintInfo.shared).run()
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

    func report(_ event: TabRuntimeEvent) {
        switch event {
        case .startedLoading:
            lifecycle = .loading
        case .committed(let url):
            if let url {
                lastCommittedURL = url
            }
        case .finished(_, let url):
            if let url {
                lastCommittedURL = url
            }
            lifecycle = .active
        case .failed:
            lifecycle = lastCommittedURL == nil ? .metadataOnly : .crashed
        case .crashed:
            lifecycle = .crashed
        case .progressChanged, .requestedNewWindow, .requestedExternalScheme, .downloadStarted, .downloadFinished, .downloadFailed, .audioStateChanged:
            break
        }
        onEvent?(event)
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
