import BrowsemiumCore
import Foundation
import WebKit

@MainActor
final class WebNavigationDelegate: NSObject, WKNavigationDelegate {
    weak var runtime: TabRuntime?

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
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
            runtime?.report(.requestedNewWindow(url))
            return .cancel
        }

        return .allow
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
        runtime?.report(.failed(error.localizedDescription))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        runtime?.report(.failed(error.localizedDescription))
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
