import BrowsemiumCore
import BrowsemiumEngineKit
import Foundation
import WebKit

/// Notices when a plain sign-in form is submitted, so the window can offer to
/// remember the password. It runs in its own content world: the page's
/// scripts cannot call the message handler or tell it anything, so a hostile
/// page cannot forge an offer. (It shares the DOM, so it reads exactly what
/// the person typed.)
///
/// It only looks at a form with exactly one password input, only reports
/// fields that can matter, and reports nothing for subframes.
enum SignInFormMonitor {
    static let messageHandlerName = "browsemiumSignIn"

    @MainActor
    static let world = WKContentWorld.world(name: "browsemium.signin")

    @MainActor
    static func makeUserScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)
    }

    private static let source = """
    (function() {
      if (window.__browsemiumSignInInstalled) { return; }
      window.__browsemiumSignInInstalled = true;
      var skipTypes = { hidden: 1, submit: 1, button: 1, checkbox: 1, radio: 1, file: 1, image: 1, reset: 1 };
      document.addEventListener('submit', function(event) {
        try {
          var form = event.target;
          if (!form || form.tagName !== 'FORM') { return; }
          var passwords = form.querySelectorAll('input[type=password]');
          if (passwords.length !== 1) { return; }
          var fields = [];
          for (var i = 0; i < form.elements.length; i++) {
            var el = form.elements[i];
            if (!el || el.tagName !== 'INPUT' || el.disabled) { continue; }
            var type = (el.type || 'text').toLowerCase();
            if (skipTypes[type]) { continue; }
            fields.push({
              name: String(el.name || el.id || '').slice(0, 80),
              type: type,
              autocomplete: String(el.autocomplete || '').toLowerCase().slice(0, 40),
              value: String(el.value || '').slice(0, 300)
            });
          }
          window.webkit.messageHandlers.\(messageHandlerName).postMessage({
            action: form.hasAttribute('action') ? String(form.action) : '',
            fields: fields
          });
        } catch (error) {}
      }, true);
    })();
    """

    /// Turns the page's report into a candidate, or nil when it is not a
    /// plain sign-in. The page URL comes from the web view, never from the
    /// message.
    static func candidate(from body: Any, pageURL: URL?) -> SignInCandidate? {
        guard let payload = body as? [String: Any],
              let rawFields = payload["fields"] as? [[String: Any]], rawFields.count <= 40 else { return nil }
        let fields = rawFields.compactMap { raw -> SignInField? in
            guard let type = raw["type"] as? String, let value = raw["value"] as? String else { return nil }
            return SignInField(
                name: (raw["name"] as? String) ?? "",
                type: type,
                autocomplete: (raw["autocomplete"] as? String) ?? "",
                value: value
            )
        }
        let actionText = (payload["action"] as? String) ?? ""
        let action = actionText.isEmpty ? nil : URL(string: actionText)
        if !actionText.isEmpty, action == nil { return nil }
        return SignInFormDetector.detect(fields: fields, pageURL: pageURL, formAction: action)
    }
}

@MainActor
final class SignInMessageProxy: NSObject, WKScriptMessageHandler {
    weak var runtime: TabRuntime?

    init(runtime: TabRuntime) {
        self.runtime = runtime
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            guard message.frameInfo.isMainFrame else { return }
            // The web view's own URL (not anything the page said) is the site
            // the password belongs to; it also follows single-page navigation.
            let pageURL = message.webView?.url ?? message.frameInfo.request.url
            guard let candidate = SignInFormMonitor.candidate(from: message.body, pageURL: pageURL) else { return }
            runtime?.report(.signInFormSubmitted(candidate))
        }
    }
}
