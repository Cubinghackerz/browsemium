import BrowsemiumCore
import AppKit
import Foundation
import WebKit

@MainActor
final class WebUIDelegate: NSObject, WKUIDelegate {
    weak var runtime: TabRuntime?

    /// Answers a camera/microphone request from a page. WebKit denies these
    /// outright when the delegate does not implement this method, so a site
    /// that needs the microphone — a voice session with an AI provider, a
    /// video call — used to fail without ever asking. The runtime owns the
    /// policy; this only translates the request.
    func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        guard let runtime, let originKey = origin.browsemiumOrigin else {
            return .deny
        }

        let kinds: [SitePermissionKind]
        switch type {
        case .camera: kinds = [.camera]
        case .microphone: kinds = [.microphone]
        case .cameraAndMicrophone: kinds = [.camera, .microphone]
        @unknown default: kinds = [.camera, .microphone]
        }

        for kind in kinds {
            let decision = await runtime.mediaCaptureDecision(origin: originKey, kind: kind)
            guard decision == .allow else { return .deny }
        }
        return .grant
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            runtime?.report(.requestedNewWindow(url))
        }
        return nil
    }

    /// Adds "Ask Browsemium AI" to the page context menu when text is
    /// selected. The selection is captured and attached in the assistant; the
    /// message itself is still typed and sent by the user.
    func webView(_ webView: WKWebView, willOpenMenu menu: NSMenu, with event: NSEvent) {
        let copySelector = Selector(("copy:"))
        let hasSelection = menu.items.contains { $0.action == copySelector }
        guard hasSelection else { return }
        let item = NSMenuItem(
            title: "Ask Browsemium AI About Selection",
            action: #selector(askAIAboutSelection(_:)),
            keyEquivalent: ""
        )
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
    }

    @objc private func askAIAboutSelection(_ sender: NSMenuItem) {
        runtime?.report(.requestedAISelection)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = webView.title ?? "Browsemium"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = webView.title ?? "Browsemium"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = webView.title ?? "Browsemium"
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    /// macOS disables file inputs unless the app supplies this delegate. Keep
    /// the browser's normal user-selected-file behavior instead of silently
    /// dropping uploads.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        guard frame.isMainFrame else {
            completionHandler(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose a file"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }
}

extension WKSecurityOrigin {
    /// The same `scheme://host[:port]` key `OriginNormalizer` produces for a
    /// URL, so a decision made on one page is found again on the next visit.
    /// Default ports are omitted so `https://example.com` is one origin
    /// whether or not WebKit reports the port.
    var browsemiumOrigin: String? {
        let scheme = `protocol`.lowercased()
        guard scheme == "http" || scheme == "https", !host.isEmpty else { return nil }
        let loweredHost = host.lowercased()
        let isDefaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return isDefaultPort ? "\(scheme)://\(loweredHost)" : "\(scheme)://\(loweredHost):\(port)"
    }
}
