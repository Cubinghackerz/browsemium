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

    /// WebKit data store identifier for the active profile. Every persistent
    /// web view — tabs, warm spares, and AI provider panels — uses it, so a
    /// profile switch isolates cookies, logins, and site storage.
    public static var dataStoreIdentifier: UUID?

    /// The active profile's extension controller, when extensions are
    /// available (macOS 15.4+). Every web view this factory builds attaches
    /// it, so extensions inject into the same pages the user sees and see
    /// the same tabs. Nil on older systems and when the profile has no host.
    @available(macOS 15.4, *)
    public static var extensionController: WKWebExtensionController?

    public static var protectionLevel: ProtectionLevel = .standard

    public func makeConfiguration(store: Store) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        if let provider = Self.contentRuleListProvider {
            provider(configuration)
        }
        Self.applyPrivacyDefaults(to: configuration)
        switch store {
        case .persistent:
            if let identifier = Self.dataStoreIdentifier {
                configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: identifier)
            } else {
                configuration.websiteDataStore = .default()
            }
            // Extensions run only on persistent views. A private window gets
            // no extension code at all — the default browsers treat it the
            // same way, and injected scripts would undermine the promise.
            if #available(macOS 15.4, *), let controller = Self.extensionController {
                configuration.webExtensionController = controller
            }
        case .ephemeral:
            configuration.websiteDataStore = .nonPersistent()
        }
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
        return webView
    }

    static func applyPrivacyDefaults(to configuration: WKWebViewConfiguration) {
        guard let preferences = configuration.defaultWebpagePreferences else { return }
        // Each compile-time gate keeps SDKs that predate the API building
        // (Xcode 26.4 ships Swift 6.3 with the macOS 26.4 SDK, Xcode 27 ships
        // Swift 6.4 with the macOS 27 SDK); the runtime check keeps the
        // feature off below the OS version that provides it.
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            preferences.globalPrivacyControlEnabled = protectionLevel.sendsGlobalPrivacyControl
        }
        #endif
        #if compiler(>=6.3)
        if #available(macOS 26.4, *) {
            preferences.securityRestrictionMode = protectionLevel.hardensWebContent
                ? .maximizeCompatibility
                : .none
        }
        #endif
    }
}
