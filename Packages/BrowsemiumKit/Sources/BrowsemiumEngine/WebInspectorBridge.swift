import AppKit
import Foundation
import WebKit

/// Developer tools for WebKit pages.
///
/// Two layers, both off unless the person turns developer tools on:
/// - `isInspectable` is public API (macOS 13.3+). It makes a page appear in
///   Safari's Develop menu, which can attach the full inspector.
/// - Showing the inspector from inside Browsemium (and the "Inspect Element"
///   context-menu item) needs WebKit's internal `developerExtrasEnabled`
///   preference and `_inspector` object. Those are not public API, so every
///   call checks that the selector exists first and quietly does nothing when
///   a future WebKit removes it. The Develop-menu route keeps working either
///   way.
@MainActor
enum WebInspectorBridge {
    private static let setExtrasSelector = NSSelectorFromString("_setDeveloperExtrasEnabled:")
    private static let inspectorSelector = NSSelectorFromString("_inspector")
    private static let showSelector = NSSelectorFromString("show")
    private static let showConsoleSelector = NSSelectorFromString("showConsole")

    /// For a configuration that has not built a web view yet.
    static func configure(_ preferences: WKPreferences, enabled: Bool) {
        guard preferences.responds(to: setExtrasSelector) else { return }
        preferences.setValue(enabled, forKey: "developerExtrasEnabled")
    }

    /// For a live web view. Both settings apply immediately.
    static func apply(_ enabled: Bool, to webView: WKWebView) {
        webView.isInspectable = enabled
        configure(webView.configuration.preferences, enabled: enabled)
    }

    static var isInspectorAvailable: Bool {
        WKWebView.instancesRespond(to: inspectorSelector)
    }

    /// Opens the inspector window for this page. False when developer tools
    /// are off for the view or this WebKit has no such inspector.
    @discardableResult
    static func show(on webView: WKWebView, console: Bool = false) -> Bool {
        guard webView.isInspectable,
              webView.responds(to: inspectorSelector),
              let unmanaged = webView.perform(inspectorSelector) else { return false }
        let inspector = unmanaged.takeUnretainedValue()
        let selector = console && inspector.responds(to: showConsoleSelector) ? showConsoleSelector : showSelector
        guard inspector.responds(to: selector) else { return false }
        _ = inspector.perform(selector)
        return true
    }
}
