import BrowsemiumCore
import Foundation
import WebKit

@MainActor
public struct WebViewFactory {
    public enum Store: Sendable {
        case persistent
        case ephemeral
    }

    public init() {}

    /// Set by the runtime controller once the content rules compile.
    public static var contentRuleListProvider: (@MainActor (WKWebViewConfiguration) -> Void)?

    public func makeConfiguration(store: Store) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        if let provider = Self.contentRuleListProvider {
            provider(configuration)
        }
        configuration.websiteDataStore = store == .persistent ? .default() : .nonPersistent()
        configuration.preferences.inactiveSchedulingPolicy = .suspend
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = [.audio]
        configuration.suppressesIncrementalRendering = false
        // Report as desktop Safari so sites serve their full desktop UI.
        // Without a Version/Safari token, Google, ChatGPT, and others fall
        // back to degraded or mobile layouts.
        configuration.applicationNameForUserAgent = "Version/18.6 Safari/605.1.15"
        return configuration
    }

    public func makeWebView(store: Store) -> WKWebView {
        let configuration = makeConfiguration(store: store)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }
}
