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
      var hideTimer = null;
      var evalTimer = null;
      var px = 0;
      var py = 0;
      var hasPointer = false;

      // Climbs past shadow boundaries; parentElement alone cannot see anchors
      // inside shadow roots, which is most modern component-based pages.
      function climb(el) {
        while (el && el !== document && el !== window) {
          if (el.tagName === 'A' && el.href) { return el.href; }
          var parent = el.parentElement;
          if (!parent && el.getRootNode) {
            var root = el.getRootNode();
            parent = root && root.host ? root.host : null;
          }
          el = parent;
        }
        return null;
      }

      function deliver(href) {
        if (href === last) { return; }
        last = href;
        try {
          window.webkit.messageHandlers.\(messageHandlerName).postMessage({ href: href });
        } catch (error) {}
      }

      // Clears are debounced so brief gaps — iframe edges, shadow-DOM
      // retargets, element churn — do not flash the bar off and on. Showing a
      // link stays instant.
      function report(href) {
        if (href !== null) {
          if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
          deliver(href);
          return;
        }
        if (last === null || hideTimer) { return; }
        hideTimer = setTimeout(function() {
          hideTimer = null;
          deliver(null);
        }, 90);
      }

      // composedPath sees through shadow roots, unlike event.target.
      function hrefFromEvent(event) {
        var path = event.composedPath ? event.composedPath() : null;
        if (path) {
          for (var i = 0; i < path.length; i++) {
            var node = path[i];
            if (node && node.tagName === 'A' && node.href) { return node.href; }
            if (node === window) { break; }
          }
        }
        return climb(event.target);
      }

      document.addEventListener('mousemove', function(event) {
        px = event.clientX;
        py = event.clientY;
        hasPointer = true;
      }, true);

      document.addEventListener('mouseover', function(event) {
        report(hrefFromEvent(event));
      }, true);

      // Moving within the same anchor must not flicker the status bar, so the
      // cleared value is taken from where the pointer actually went.
      document.addEventListener('mouseout', function(event) {
        var to = event.relatedTarget;
        report(to ? climb(to) : null);
      }, true);

      document.addEventListener('mouseleave', function() { report(null); }, true);

      window.addEventListener('blur', function() {
        if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
        deliver(null);
      });

      // Scrolling moves the page under a still pointer without firing mouse
      // events; re-evaluate what is actually underneath, throttled.
      function scheduleEvaluate() {
        if (!hasPointer || evalTimer) { return; }
        evalTimer = setTimeout(function() {
          evalTimer = null;
          var el = document.elementFromPoint(px, py);
          report(el ? climb(el) : null);
        }, 60);
      }
      document.addEventListener('scroll', scheduleEvaluate, true);
      window.addEventListener('resize', scheduleEvaluate);
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
