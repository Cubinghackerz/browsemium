import BrowsemiumEngineKit
import Foundation
import WebKit

/// WKWebView has no element-picking API, so a small script draws a highlight
/// over whatever is under the pointer and, on click, reports a verified CSS
/// selector for it. The script is injected into every page at document end
/// and stays dormant until the engine calls `start()`. Top frame only: a
/// click over a subframe picks the frame element itself, which is what a user
/// pointing at an embedded widget means anyway.
enum ElementPicker {
    static let messageHandlerName = "browsemiumElementPicker"

    /// `WKUserScript.init` is main-actor isolated in older WebKit SDKs, so the
    /// script is built on the main actor and handed to the runtime there.
    @MainActor
    static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
    }

    private static let source = """
    (function() {
      if (window.__browsemiumElementPickerInstalled) { return; }
      window.__browsemiumElementPickerInstalled = true;

      var active = false;
      var overlay = null;
      var badge = null;
      var current = null;

      function isHideable(el) {
        return !!el && el.nodeType === 1 && el !== document.documentElement && el !== document.body;
      }

      // A short human description for the confirmation UI.
      function describe(el) {
        var text = el.tagName ? el.tagName.toLowerCase() : "element";
        if (el.id) {
          text += "#" + el.id;
        } else if (el.classList && el.classList.length) {
          text += "." + Array.prototype.slice.call(el.classList, 0, 2).join(".");
        }
        return text;
      }

      function matchesExactly(selector, el) {
        try { return document.querySelector(selector) === el; } catch (error) { return false; }
      }

      function contains(selector, el) {
        try {
          var list = document.querySelectorAll(selector);
          for (var i = 0; i < list.length; i++) { if (list[i] === el) { return true; } }
        } catch (error) {}
        return false;
      }

      function matchCount(selector) {
        try { return document.querySelectorAll(selector).length; } catch (error) { return 0; }
      }

      // Prefer a unique id; otherwise an exact child path that round-trips to
      // this element. Refusing beats saving a rule that hides the wrong thing.
      function selectorFor(el) {
        if (!isHideable(el)) { return null; }
        if (el.id && /^[A-Za-z][A-Za-z0-9_-]*$/.test(el.id)) {
          var byId = "#" + el.id;
          if (matchesExactly(byId, el)) { return byId; }
        }
        var parts = [];
        var node = el;
        while (node && node.nodeType === 1 && node !== document.body && node !== document.documentElement) {
          if (node.id && /^[A-Za-z][A-Za-z0-9_-]*$/.test(node.id)) {
            parts.unshift("#" + node.id);
            break;
          }
          var parent = node.parentElement;
          if (!parent) { return null; }
          var part = node.tagName.toLowerCase();
          var sameTag = 0;
          var index = 0;
          for (var i = 0; i < parent.children.length; i++) {
            var sibling = parent.children[i];
            if (sibling.tagName === node.tagName) {
              sameTag += 1;
              if (sibling === node) { index = sameTag; }
            }
          }
          if (sameTag > 1) { part += ":nth-of-type(" + index + ")"; }
          parts.unshift(part);
          node = parent;
          if (parts.length > 12) { return null; }
        }
        if (!parts.length) { return null; }
        var selector = parts.join(" > ");
        return contains(selector, el) ? selector : null;
      }

      function position(el) {
        if (!overlay || !badge || !el) { return; }
        var rect = el.getBoundingClientRect();
        overlay.style.left = rect.left + "px";
        overlay.style.top = rect.top + "px";
        overlay.style.width = Math.max(0, rect.width - 4) + "px";
        overlay.style.height = Math.max(0, rect.height - 4) + "px";
        var top = rect.top - 22;
        if (top < 4) { top = Math.min(window.innerHeight - 22, rect.bottom + 4); }
        badge.style.left = Math.max(4, rect.left) + "px";
        badge.style.top = Math.max(4, top) + "px";
        badge.textContent = describe(el);
      }

      function onMove(event) {
        var el = document.elementFromPoint(event.clientX, event.clientY);
        if (!isHideable(el)) { el = null; }
        current = el;
        if (!el) {
          if (overlay) { overlay.style.width = "0px"; overlay.style.height = "0px"; }
          if (badge) { badge.style.display = "none"; }
          return;
        }
        if (badge) { badge.style.display = "block"; }
        position(el);
      }

      function onClick(event) {
        if (!active) { return; }
        event.preventDefault();
        event.stopImmediatePropagation();
        var el = event.target && event.target.nodeType === 1 ? event.target : current;
        var selector = selectorFor(el);
        if (!selector) {
          post({ failed: true });
          stop();
          return;
        }
        post({ selector: selector, label: describe(el), count: matchCount(selector) });
        stop();
      }

      function onKeyDown(event) {
        if (event.key !== "Escape") { return; }
        event.preventDefault();
        event.stopImmediatePropagation();
        post({ cancelled: true });
        stop();
      }

      function onViewportChanged() {
        if (current) { position(current); }
      }

      function post(payload) {
        try {
          window.webkit.messageHandlers.\(messageHandlerName).postMessage(payload);
        } catch (error) {}
      }

      function start() {
        if (active) { return; }
        active = true;
        overlay = document.createElement("div");
        overlay.setAttribute("data-browsemium-picker", "highlight");
        overlay.style.cssText = "position:fixed;z-index:2147483646;pointer-events:none;" +
          "border:2px solid #2b6cff;background:rgba(43,108,255,0.10);border-radius:2px;box-sizing:border-box;";
        badge = document.createElement("div");
        badge.setAttribute("data-browsemium-picker", "badge");
        badge.style.cssText = "position:fixed;z-index:2147483647;pointer-events:none;" +
          "background:#101010;color:#fff;font:11px/1.5 -apple-system,system-ui,sans-serif;" +
          "padding:2px 7px;border-radius:3px;white-space:nowrap;max-width:70vw;overflow:hidden;text-overflow:ellipsis;";
        document.documentElement.appendChild(overlay);
        document.documentElement.appendChild(badge);
        document.addEventListener("mousemove", onMove, true);
        document.addEventListener("click", onClick, true);
        document.addEventListener("keydown", onKeyDown, true);
        window.addEventListener("scroll", onViewportChanged, true);
        window.addEventListener("resize", onViewportChanged);
        document.documentElement.style.cursor = "crosshair";
      }

      function stop() {
        if (!active) { return; }
        active = false;
        current = null;
        document.removeEventListener("mousemove", onMove, true);
        document.removeEventListener("click", onClick, true);
        document.removeEventListener("keydown", onKeyDown, true);
        window.removeEventListener("scroll", onViewportChanged, true);
        window.removeEventListener("resize", onViewportChanged);
        document.documentElement.style.cursor = "";
        if (overlay && overlay.parentNode) { overlay.parentNode.removeChild(overlay); }
        if (badge && badge.parentNode) { badge.parentNode.removeChild(badge); }
        overlay = null;
        badge = null;
      }

      window.__browsemiumElementPicker = { start: start, stop: stop };
    })();
    """
}

/// Receives picker reports from a tab's pages. Holds the runtime weakly so the
/// content controller never keeps a discarded tab alive. Same delivery and
/// isolation contract as `TabAudioMessageProxy`.
@MainActor
final class ElementPickerMessageProxy: NSObject, WKScriptMessageHandler {
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
            if payload["cancelled"] as? Bool == true {
                runtime?.updateElementPickCancelled()
                return
            }
            if payload["failed"] as? Bool == true {
                runtime?.updateElementPickFailed()
                return
            }
            guard let selector = payload["selector"] as? String, !selector.isEmpty else { return }
            let label = (payload["label"] as? String) ?? selector
            let count = (payload["count"] as? NSNumber)?.intValue ?? 1
            runtime?.updatePickedElement(selector: selector, label: label, matchCount: count)
        }
    }
}

/// Applies saved cosmetic rules at document start. The whole per-host map is
/// baked into one script: matching happens in the page by hostname, so a rule
/// change never has to rebuild scripts per navigation.
enum CosmeticRulesScript {
    @MainActor
    static func makeUserScript(rulesByHost: [String: String]) -> WKUserScript {
        WKUserScript(
            source: source(rulesByHost: rulesByHost),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    static func source(rulesByHost: [String: String]) -> String {
        """
        (function() {
          window.__browsemiumCosmeticRulesByHost = \(jsLiteral(rulesByHost));
          window.__browsemiumApplyCosmeticRules = function(text) {
            var style = document.getElementById("browsemium-cosmetic-rules");
            if (!style) {
              style = document.createElement("style");
              style.id = "browsemium-cosmetic-rules";
              (document.head || document.documentElement).appendChild(style);
            }
            style.textContent = text || "";
          };
          var host = (location.hostname || "").toLowerCase();
          window.__browsemiumApplyCosmeticRules(window.__browsemiumCosmeticRulesByHost[host] || "");
        })();
        """
    }

    /// A JSON object literal is a valid JavaScript expression; encoding the
    /// map with JSONSerialization keeps selectors with quotes or backslashes
    /// from breaking out of the script.
    static func jsLiteral(_ rulesByHost: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: rulesByHost, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    static func jsLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return String(json.dropFirst().dropLast())
    }
}
