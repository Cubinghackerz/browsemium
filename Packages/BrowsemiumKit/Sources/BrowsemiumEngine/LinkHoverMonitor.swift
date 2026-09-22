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
      var isTop = (window === window.top);
      var px = 0;
      var py = 0;
      var hasPointer = false;

      // Every frame reports through the TOP frame's single state machine:
      // per-frame native posts would race — a subframe's "nothing hovered" can
      // arrive after the parent's "link hovered" and clear a live status. Each
      // frame dedupes its own reports, then subframes post one level up;
      // middle frames relay until the top frame is the only native sender.
      var lastLocal;
      var hasLastLocal = false;

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
        if (hasLastLocal && href === lastLocal) { return; }
        hasLastLocal = true;
        lastLocal = href;
        if (isTop) {
          report(href);
        } else {
          try { window.parent.postMessage({ __bmHover: href }, '*'); } catch (error) {}
        }
      }

      // Relay: only accept from a direct child frame (the sender is a window
      // we injected into); anything else cannot know this marker anyway.
      window.addEventListener('message', function(event) {
        if (!event.data || event.data.__bmHover === undefined) { return; }
        var ours = false;
        for (var i = 0; i < window.frames.length; i++) {
          if (window.frames[i] === event.source) { ours = true; break; }
        }
        if (ours) { deliver(event.data.__bmHover); }
      });

      var lastPosted = null;
      var hideTimer = null;
      var evalTimer = null;

      function post(href) {
        if (href === lastPosted) { return; }
        lastPosted = href;
        try {
          window.webkit.messageHandlers.\(messageHandlerName).postMessage({ href: href });
        } catch (error) {}
      }

      // Top frame only. Clears are debounced so brief gaps — element churn,
      // shadow-DOM retargets — do not flash the bar off and on; when the timer
      // fires the element under the pointer is re-verified rather than
      // trusted, because a fresher report may have arrived since. Showing a
      // link stays instant.
      function report(href) {
        if (href !== null) {
          if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
          post(href);
          return;
        }
        if (lastPosted === null || hideTimer) { return; }
        hideTimer = setTimeout(function() {
          hideTimer = null;
          var el = hasPointer ? document.elementFromPoint(px, py) : null;
          // Pointer inside a child frame: that frame owns hover state and its
          // own report will land shortly — this stale clear must not win.
          if (el && el.tagName === 'IFRAME') { return; }
          post(el ? climb(el) : null);
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
        deliver(hrefFromEvent(event));
      }, true);

      // Moving within the same anchor must not flicker the status bar, so the
      // cleared value is taken from where the pointer actually went.
      document.addEventListener('mouseout', function(event) {
        var to = event.relatedTarget;
        deliver(to ? climb(to) : null);
      }, true);

      document.addEventListener('mouseleave', function() { deliver(null); }, true);

      window.addEventListener('blur', function() { deliver(null); });

      // Scrolling moves the page under a still pointer without firing mouse
      // events; re-evaluate what is actually underneath, throttled.
      function scheduleEvaluate() {
        if (!hasPointer || evalTimer) { return; }
        evalTimer = setTimeout(function() {
          evalTimer = null;
          var el = document.elementFromPoint(px, py);
          deliver(el ? climb(el) : null);
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
