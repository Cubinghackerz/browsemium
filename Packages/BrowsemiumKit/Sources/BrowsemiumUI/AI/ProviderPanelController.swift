import BrowsemiumAI
import BrowsemiumCore
import BrowsemiumEngine
import Foundation
import Observation
import WebKit

@MainActor
@Observable
public final class ProviderPanelController {
    public private(set) var revision: Int = 0
    public private(set) var activeProvider: AIProviderID?

    private let factory = WebViewFactory()
    private var webViews: [AIProviderID: WKWebView] = [:]
    private var pendingURLs: [AIProviderID: URL] = [:]

    public init() {}

    public func webView(for provider: AIProviderID) -> WKWebView {
        if let existing = webViews[provider] {
            return existing
        }
        let webView = factory.makeWebView(store: .persistent)
        if let pending = pendingURLs[provider] {
            webView.load(URLRequest(url: pending))
            pendingURLs[provider] = nil
        } else {
            webView.load(URLRequest(url: ProviderPanelDescriptor.descriptor(for: provider).baseURL))
        }
        webViews[provider] = webView
        activeProvider = provider
        revision += 1
        return webView
    }

    public func open(url: URL, provider: AIProviderID) {
        if let webView = webViews[provider] {
            webView.load(URLRequest(url: url))
        } else {
            pendingURLs[provider] = url
            _ = webView(for: provider)
        }
        activeProvider = provider
    }

    public func suspendInactive(except provider: AIProviderID?) {
        for (key, webView) in webViews where key != provider {
            webView.removeFromSuperview()
            webView.stopLoading()
        }
    }

    public func release(except provider: AIProviderID?) {
        let keys = webViews.keys.filter { $0 != provider }
        for key in keys {
            webViews[key]?.stopLoading()
            webViews[key]?.removeFromSuperview()
            webViews.removeValue(forKey: key)
        }
    }

    public func releaseAll() {
        for (_, webView) in webViews {
            webView.stopLoading()
            webView.removeFromSuperview()
        }
        webViews.removeAll()
        pendingURLs.removeAll()
        activeProvider = nil
        revision += 1
    }
}
