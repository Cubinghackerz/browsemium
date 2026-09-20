import Foundation
import WebKit

/// Per-tab audio state reported by the injected page script.
public struct TabAudioState: Hashable, Sendable {
    public let isPlaying: Bool
    public let isMuted: Bool

    public init(isPlaying: Bool, isMuted: Bool) {
        self.isPlaying = isPlaying
        self.isMuted = isMuted
    }
}

/// WebKit has no public per-tab "is playing audio" API, so this observes the
/// page instead: media elements and AudioContexts report through a message
/// handler, and muting is applied by the script. Best-effort by design — a
/// page that plays audio without `<audio>`/`<video>` or Web Audio is invisible
/// to it.
enum TabAudioMonitor {
    static let messageHandlerName = "browsemiumAudio"

    static var userScript: WKUserScript {
        WKUserScript(
            source: source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
    }

    private static let source = """
    (function() {
      if (window.__browsemiumAudioInstalled) { return; }
      window.__browsemiumAudioInstalled = true;
      window.__browsemiumContexts = window.__browsemiumContexts || [];
      window.__browsemiumMuted = window.__browsemiumMuted || false;

      try {
        var Original = window.AudioContext || window.webkitAudioContext;
        if (Original && !Original.__browsemiumPatched) {
          var Patched = function() {
            var ctx = new (Function.prototype.bind.apply(Original, [null].concat(Array.prototype.slice.call(arguments))))();
            window.__browsemiumContexts.push(ctx);
            return ctx;
          };
          Patched.prototype = Original.prototype;
          Patched.__browsemiumPatched = true;
          window.AudioContext = Patched;
          window.webkitAudioContext = Patched;
        }
      } catch (error) {}

      window.__browsemiumReportAudio = function() {
        var playing = false;
        var media = document.querySelectorAll('audio, video');
        for (var i = 0; i < media.length; i++) {
          var el = media[i];
          if (!el.paused && !el.ended && el.volume > 0 && !el.muted) { playing = true; break; }
        }
        if (!playing && !window.__browsemiumMuted) {
          playing = window.__browsemiumContexts.some(function(ctx) {
            return ctx.state === 'running';
          });
        }
        try {
          window.webkit.messageHandlers.\(messageHandlerName).postMessage({
            playing: playing,
            muted: window.__browsemiumMuted
          });
        } catch (error) {}
      };

      window.__browsemiumSetMuted = function(muted) {
        window.__browsemiumMuted = !!muted;
        var media = document.querySelectorAll('audio, video');
        for (var i = 0; i < media.length; i++) {
          try { media[i].muted = !!muted; } catch (error) {}
        }
        window.__browsemiumContexts.forEach(function(ctx) {
          try {
            if (muted && ctx.state === 'running') { ctx.suspend(); }
            else if (!muted && ctx.state === 'suspended') { ctx.resume(); }
          } catch (error) {}
        });
        window.__browsemiumReportAudio();
      };

      ['play', 'playing', 'pause', 'ended', 'volumechange', 'loadeddata'].forEach(function(event) {
        document.addEventListener(event, function() { window.__browsemiumReportAudio(); }, true);
      });
      document.addEventListener('visibilitychange', function() { window.__browsemiumReportAudio(); });
    })();
    """
}

/// Receives audio reports from a tab's pages. Holds the runtime weakly so the
/// content controller never keeps a discarded tab alive.
///
/// The protocol requirement is nonisolated: older WebKit SDKs do not annotate
/// `WKScriptMessageHandler` with `@MainActor`, so the conformance has to be
/// portable across toolchains. Values are extracted on the callback thread and
/// the state update hops to the main actor.
@MainActor
final class TabAudioMessageProxy: NSObject, WKScriptMessageHandler {
    weak var runtime: TabRuntime?

    init(runtime: TabRuntime) {
        self.runtime = runtime
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let payload = message.body as? [String: Any] else { return }
        let playing = payload["playing"] as? Bool ?? false
        let muted = payload["muted"] as? Bool ?? false
        Task { @MainActor [weak self] in
            self?.runtime?.updateAudioState(isPlaying: playing, isMuted: muted)
        }
    }
}
