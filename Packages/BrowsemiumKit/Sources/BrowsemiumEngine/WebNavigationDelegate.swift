import BrowsemiumCore
import Foundation
import WebKit

extension WKNavigationAction {
    /// ⌘-click on a link asks for the peek overlay instead of a background
    /// tab. Only `linkActivated` navigations count — a page's scripted
    /// navigation must never be read as a user gesture.
    var requestsPeek: Bool {
        navigationType == .linkActivated && modifierFlags.contains(.command)
    }
}

@MainActor
final class WebNavigationDelegate: NSObject, WKNavigationDelegate {
    weak var runtime: TabRuntime?
    var protectionLevel: ProtectionLevel = .standard
    var preferredLanguages: () -> [String] = { Locale.preferredLanguages }

    private enum Decision {
        case allow
        case cancel
        case download
        case replace(URL)
    }

    private func decision(for navigationAction: WKNavigationAction) -> Decision {
        guard let url = navigationAction.request.url else {
            return .cancel
        }

        if navigationAction.shouldPerformDownload {
            return .download
        }

        guard let scheme = url.scheme?.lowercased() else {
            return .cancel
        }

        if scheme == "about" {
            return .allow
        }

        guard scheme == "http" || scheme == "https" else {
            runtime?.report(.requestedExternalScheme(url))
            return .cancel
        }

        if navigationAction.targetFrame == nil {
            runtime?.report(navigationAction.requestsPeek ? .requestedPeek(url) : .requestedNewWindow(url))
            return .cancel
        }

        if navigationAction.requestsPeek {
            runtime?.report(.requestedPeek(url))
            return .cancel
        }

        if navigationAction.targetFrame?.isMainFrame == true {
            runtime?.applyBlockingPause(forHost: url.host?.lowercased() ?? "")
        }

        if scheme == "http", navigationAction.targetFrame?.isMainFrame == true,
           let secure = protectionLevel.httpsUpgrade(of: url) {
            return .replace(secure)
        }

        if navigationAction.targetFrame?.isMainFrame == true,
           let localized = NavigationCompatibility.chromeWebStoreURL(
               from: url,
               preferredLanguages: preferredLanguages()
           ) {
            return .replace(localized)
        }

        return .allow
    }

    private func applyPrivacy(to preferences: WKWebpagePreferences) {
        // Compile-time gate: only SDKs from Xcode 27 (Swift 6.4) declare this.
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            preferences.globalPrivacyControlEnabled = protectionLevel.sendsGlobalPrivacyControl
        }
        #endif
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        switch decision(for: navigationAction) {
        case .allow: .allow
        case .cancel, .replace: .cancel
        case .download: .download
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        switch decision(for: navigationAction) {
        case .allow:
            applyPrivacy(to: preferences)
            return (.allow, preferences)
        case .cancel:
            return (.cancel, preferences)
        case .download:
            return (.download, preferences)
        case .replace(let url):
            // Compile-time gate: only SDKs from Xcode 27 (Swift 6.4) declare this.
            #if compiler(>=6.4)
            if #available(macOS 27.0, *) {
                var request = navigationAction.request
                request.url = url
                preferences.alternateRequest = request
                applyPrivacy(to: preferences)
                return (.allow, preferences)
            }
            #endif
            Task { @MainActor [weak self] in
                self?.runtime?.load(url)
            }
            return (.cancel, preferences)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        runtime?.report(.startedLoading(webView.url))
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        runtime?.report(.committed(webView.url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        runtime?.handleDidFinish(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        reportFailure(error)
    }

    private func reportFailure(_ error: Error) {
        if Self.isExpectedInterruption(error) {
            runtime?.report(.cancelled)
        } else {
            runtime?.report(.failed(error.localizedDescription))
        }
    }

    /// Errors WebKit reports through the failure callbacks that are not real
    /// failures: the user stopped the load, a redirect superseded it, or a
    /// policy decision turned the navigation into a download.
    static func isExpectedInterruption(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }
        // WebKitErrorFrameLoadInterruptedByPolicyChange — the .download policy
        // answer interrupts the provisional navigation on purpose.
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 {
            return true
        }
        return false
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        runtime?.report(.crashed)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        runtime?.adoptDownload(download)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        runtime?.adoptDownload(download)
    }
}
