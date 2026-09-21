import BrowsemiumEngineKit
import Foundation
import WebKit

/// WKWebView has no public "link under the pointer" API on macOS, so a small
/// script watches mouseover/mouseout in the capture phase and reports the
/// resolved href of the nearest enclosing anchor. Reports only on change, so
/// moving across a long link does not flood the message channel.
enum LinkHoverMonitor {
    static let messageHandlerName = "browsemiumLinkHover"

    /// `WKUserScript.init` is main-actor isolated in older WebKit SDKs, so the
    /// script is built on the main actor and handed to the runtime there.
    @MainActor
    static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
    }

    private static let source = """
    (function() {
      if (window.__browsemiumLinkHoverInstalled) { return; }
      window.__browsemiumLinkHoverInstalled = true;
      var last = null;

      function hrefFor(target) {
        var el = target;
        while (el && el !== document) {
          if (el.tagName === 'A' && el.href) { return el.href; }
          el = el.parentElement;
        }
        return null;
      }

      function report(href) {
        if (href === last) { return; }
        last = href;
        try {
          window.webkit.messageHandlers.\(messageHandlerName).postMessage({ href: href });
        } catch (error) {}
      }

      document.addEventListener('mouseover', function(event) {
        report(hrefFor(event.target));
      }, true);

      // Moving within the same anchor must not flicker the status bar, so the
      // cleared value is taken from where the pointer actually went.
      document.addEventListener('mouseout', function(event) {
        report(hrefFor(event.relatedTarget));
      }, true);

      document.addEventListener('mouseleave', function() { report(null); }, true);
    })();
    """
}

/// Receives hover reports from a tab's pages. Holds the runtime weakly so the
/// content controller never keeps a discarded tab alive. Same delivery and
/// isolation contract as `TabAudioMessageProxy`.
@MainActor
final class LinkHoverMessageProxy: NSObject, WKScriptMessageHandler {
    weak var runtime: TabRuntime?

    init(runtime: TabRuntime) {
        self.runtime = runtime
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            guard let payload = message.body as? [String: Any] else { return }
            let url = (payload["href"] as? String).flatMap { URL(string: $0) }
            runtime?.updateHoveredLink(url)
        }
    }
}
