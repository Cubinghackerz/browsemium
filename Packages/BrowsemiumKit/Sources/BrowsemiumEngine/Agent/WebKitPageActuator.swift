import AppKit
import BrowsemiumCore
import BrowsemiumEngineKit
import Foundation
import WebKit

/// Resolves a continuation exactly once, with an optional deadline. Used for
/// page loads and script runs, which can otherwise hang forever on a page
/// that never finishes or never yields the main thread.
@MainActor
final class SingleResume<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var timer: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    func startTimer(after duration: Duration, error: any Error, onTimeout: (@MainActor () -> Void)? = nil) {
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.continuation != nil else { return }
            onTimeout?()
            self.resolve(.failure(error))
        }
    }

    func resolve(_ result: Result<Value, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        timer = nil
        continuation.resume(with: result)
    }
}

/// The WebKit implementation of `PageActuating`.
///
/// Scope of what it does: it owns its own web views (never a tab the person
/// opened), on the persistent store the grant names, and it exposes a fixed
/// set of operations. There is no script entry point. Private windows never
/// reach it because it never builds an ephemeral store.
///
/// Scope of what it does not do: it cannot tell a harmless page from a hostile
/// one. It runs browser-owned scripts in an isolated `WKContentWorld`, but the
/// DOM is shared with the page.
@MainActor
public final class WebKitPageActuator: PageActuating {
    /// Deadlines for a page load and a browser-owned script. Instance state so
    /// tests can exercise the hang path quickly; the defaults are the product.
    var navigationTimeout: Duration = .seconds(30)
    var scriptTimeout: Duration = .seconds(15)

    final class Tab {
        let id: TabID
        let webView: WKWebView
        let delegate: AgentWebDelegate
        let authorize: @MainActor (URL) -> Bool
        var pendingNavigation: SingleResume<Void>?
        /// Origin of the document that actually committed. `WKWebView.url` can
        /// name a provisional URL that never loaded (for example a redirect the
        /// policy refused), so it is never used to decide scope.
        var committedOrigin: AgentOrigin?

        init(id: TabID, webView: WKWebView, delegate: AgentWebDelegate, authorize: @escaping @MainActor (URL) -> Bool) {
            self.id = id
            self.webView = webView
            self.delegate = delegate
            self.authorize = authorize
        }
    }

    private(set) var tabs: [TabID: Tab] = [:]
    private(set) var agentAccess = false
    private let world = WKContentWorld.world(name: "BrowsemiumAgent")

    public init() {}

    // MARK: - Lifecycle

    public func createTab(
        _ id: TabID,
        dataStoreID: UUID,
        authorizeNavigation: @escaping @MainActor (URL) -> Bool
    ) throws {
        guard tabs[id] == nil else { throw AgentError.denied }
        guard tabs.count < AgentLimits.maxTabs else { throw AgentError.tabLimit }

        let configuration = WebViewFactory().makeConfiguration(store: .persistent)
        // The grant's store, not whichever profile the factory last saw.
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: dataStoreID)
        // Extensions inject into pages; a task page stays predictable.
        if #available(macOS 15.4, *) { configuration.webExtensionController = nil }
        configuration.mediaTypesRequiringUserActionForPlayback = [.all]

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        let delegate = AgentWebDelegate(actuator: self, tabID: id)
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        tabs[id] = Tab(id: id, webView: webView, delegate: delegate, authorize: authorizeNavigation)
    }

    /// Turns the agent's ability to act on or off without touching the pages.
    /// Turning it off cancels loads the agent started and fails any call that
    /// is waiting on one. The pages and their state stay for the person.
    public func setAgentAccess(_ enabled: Bool) {
        agentAccess = enabled
        guard !enabled else { return }
        for tab in tabs.values {
            tab.webView.stopLoading()
            finishNavigation(tab, .failure(AgentError.denied))
        }
    }

    public func closeTab(_ id: TabID) {
        guard let tab = tabs.removeValue(forKey: id) else { return }
        finishNavigation(tab, .failure(AgentError.denied))
        tab.webView.stopLoading()
        tab.webView.navigationDelegate = nil
        tab.webView.uiDelegate = nil
        tab.webView.removeFromSuperview()
    }

    /// Shows a task page inside a host view (the task workspace). Attaching
    /// never changes the person's selected tab or takes keyboard focus.
    public func attach(_ id: TabID, to host: NSView) {
        guard let tab = tabs[id] else { return }
        tab.webView.removeFromSuperview()
        tab.webView.frame = host.bounds
        tab.webView.autoresizingMask = [.width, .height]
        host.addSubview(tab.webView)
    }

    public func detach(_ id: TabID) {
        tabs[id]?.webView.removeFromSuperview()
    }

    // MARK: - Reading state

    public func currentOrigin(_ id: TabID) -> AgentOrigin? {
        tabs[id]?.committedOrigin
    }

    // MARK: - Operations

    public func navigate(_ id: TabID, to url: URL) async throws {
        let tab = try activeTab(id)
        // A newer navigation supersedes the old one.
        finishNavigation(tab, .failure(AgentError.unavailable))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let pending = SingleResume<Void>(continuation)
            tab.pendingNavigation = pending
            pending.startTimer(after: navigationTimeout, error: AgentError.unavailable) { [weak tab] in
                tab?.webView.stopLoading()
            }
            tab.webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 25))
        }
    }

    public func snapshot(_ id: TabID) async throws -> AgentPageSnapshot {
        let tab = try activeTab(id)
        let raw = try await evaluate(AgentPageScripts.snapshot, ["limit": AgentLimits.maxSnapshotElements], in: tab)
        let dto = try Self.decode(SnapshotPayload.self, raw)
        let origin = try pageOrigin(dto.origin, tab: tab)
        return AgentPageSnapshot(
            title: dto.title,
            origin: origin,
            elements: dto.elements.map { $0.element(origin: origin) },
            isTruncated: dto.truncated
        )
    }

    public func readText(_ id: TabID) async throws -> String {
        let tab = try activeTab(id)
        return try await evaluate(AgentPageScripts.readText, ["limit": AgentLimits.maxReadCharacters], in: tab)
    }

    public func screenshot(_ id: TabID) async throws -> Data {
        let tab = try activeTab(id)
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        do {
            let image = try await tab.webView.takeSnapshot(configuration: configuration)
            return try ScreenshotEncoder.encode(image, maxDimension: 1600, maxBytes: 3_000_000).data
        } catch {
            throw AgentError.unavailable
        }
    }

    public func resolve(_ reference: String, in id: TabID) async throws -> AgentElement {
        let tab = try activeTab(id)
        let raw = try await evaluate(AgentPageScripts.resolve, ["id": reference], in: tab)
        let dto = try Self.decode(ResolvePayload.self, raw)
        guard let element = dto.element, let originText = dto.origin else { throw AgentError.staleElement }
        let origin = try pageOrigin(originText, tab: tab)
        return element.element(origin: origin)
    }

    public func perform(_ action: AgentPageAction, in id: TabID) async throws {
        let tab = try activeTab(id)
        let element = action.element
        var arguments: [String: Any] = [
            "id": element.id,
            "expected": element.fingerprint,
            "origin": element.origin.description
        ]
        switch action {
        case .click:
            arguments["kind"] = "click"
            arguments["text"] = ""
        case .type(_, let text):
            arguments["kind"] = "type"
            arguments["text"] = text
        }
        let outcome = try await evaluate(AgentPageScripts.perform, arguments, in: tab)
        switch outcome {
        case "ok": return
        case "stale": throw AgentError.staleElement
        case "sensitive": throw AgentError.sensitiveField
        case "origin", "notEditable": throw AgentError.denied
        default: throw AgentError.unavailable
        }
    }

    // MARK: - Internals

    private func activeTab(_ id: TabID) throws -> Tab {
        guard agentAccess, let tab = tabs[id] else { throw AgentError.denied }
        return tab
    }

    /// The origin a script reports must be the origin WebKit reports for the
    /// page; any disagreement means the page is not what the gate verified.
    private func pageOrigin(_ reported: String, tab: Tab) throws -> AgentOrigin {
        guard let actual = tab.committedOrigin,
              let claimed = try? AgentOrigin(string: reported),
              actual == claimed else { throw AgentError.denied }
        return actual
    }

    func finishNavigation(_ tab: Tab, _ result: Result<Void, any Error>) {
        guard let pending = tab.pendingNavigation else { return }
        tab.pendingNavigation = nil
        pending.resolve(result)
    }

    /// Runs a browser-owned script with a deadline, so a page that never yields
    /// the main thread cannot hold the task's single operation slot forever.
    private func evaluate(_ body: String, _ arguments: [String: Any], in tab: Tab) async throws -> String {
        let world = world
        let deadline = scriptTimeout
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            let once = SingleResume<String>(continuation)
            once.startTimer(after: deadline, error: AgentError.unavailable)
            tab.webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { result in
                switch result {
                case .success(let value):
                    if let text = value as? String, text.utf8.count <= 2_000_000 {
                        once.resolve(.success(text))
                    } else {
                        once.resolve(.failure(AgentError.unavailable))
                    }
                case .failure:
                    once.resolve(.failure(AgentError.unavailable))
                }
            }
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ raw: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: Data(raw.utf8)) } catch { throw AgentError.unavailable }
    }

    private struct ElementPayload: Decodable {
        let id: String
        let role: String
        let name: String
        let fingerprint: String
        let editable: Bool
        let sensitive: Bool

        func element(origin: AgentOrigin) -> AgentElement {
            AgentElement(
                id: id, role: role, name: name, origin: origin, fingerprint: fingerprint,
                isEditable: editable, isSensitive: sensitive
            )
        }
    }

    private struct SnapshotPayload: Decodable {
        let title: String
        let origin: String
        let elements: [ElementPayload]
        let truncated: Bool
    }

    private struct ResolvePayload: Decodable {
        let origin: String?
        let element: ElementPayload?
    }

    // MARK: - Test seams

    func webViewForTesting(_ id: TabID) -> WKWebView? { tabs[id]?.webView }
}

/// Navigation and UI policy for one task page. It never shows a modal panel
/// (a hostile page must not be able to stack dialogs over the person's work),
/// never opens a window, and never answers a permission request in the page's
/// favour.
@MainActor
final class AgentWebDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private weak var actuator: WebKitPageActuator?
    private let tabID: TabID

    init(actuator: WebKitPageActuator, tabID: TabID) {
        self.actuator = actuator
        self.tabID = tabID
    }

    private var tab: WebKitPageActuator.Tab? { actuator?.tabs[tabID] }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let actuator, let tab else { return .cancel }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
        let decision = AgentNavigationPolicy.decide(
            url: navigationAction.request.url,
            isMainFrame: isMainFrame,
            opensNewWindow: navigationAction.targetFrame == nil,
            isDownload: navigationAction.shouldPerformDownload,
            agentAccess: actuator.agentAccess,
            authorize: tab.authorize
        )
        switch decision {
        case .allow:
            return .allow
        case .cancel:
            // A refused top-level navigation ends the call that caused it.
            if isMainFrame, actuator.agentAccess {
                actuator.finishNavigation(tab, .failure(AgentError.denied))
            }
            return .cancel
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .cancel
    }

    func webView(
        _ webView: WKWebView,
        respondTo challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        // No prompt, no credential: a task page cannot ask the person for a
        // password and the agent cannot supply one.
        switch AuthChallengePolicy.action(forMethod: challenge.protectionSpace.authenticationMethod) {
        case .prompt: (.cancelAuthenticationChallenge, nil)
        case .performDefaultHandling: (.performDefaultHandling, nil)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        tab?.committedOrigin = webView.url.flatMap { try? AgentOrigin($0) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let actuator, let tab else { return }
        actuator.finishNavigation(tab, .success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        guard let actuator, let tab else { return }
        actuator.finishNavigation(tab, .failure(AgentError.unavailable))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        guard let actuator, let tab else { return }
        actuator.finishNavigation(tab, .failure(AgentError.unavailable))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let actuator, let tab else { return }
        tab.committedOrigin = nil
        actuator.finishNavigation(tab, .failure(AgentError.unavailable))
    }

    // MARK: - UI delegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        completionHandler(false)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        completionHandler(nil)
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        completionHandler(nil)
    }

    func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        .deny
    }
}
