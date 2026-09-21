import BrowsemiumEngineKit
import Foundation
import WebKit

/// WebKit has no public per-tab "is playing audio" API, so this observes the
/// page instead: media elements, AudioContexts, and microphone/camera/screen
/// capture tracks report through a message handler, and muting is applied by
/// the script. Best-effort by design — a page that plays audio without
/// `<audio>`/`<video>` or Web Audio, or that obtained a capture track before
/// the script ran, is invisible to it.
enum TabAudioMonitor {
    static let messageHandlerName = "browsemiumAudio"

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
      if (window.__browsemiumAudioInstalled) { return; }
      window.__browsemiumAudioInstalled = true;
      window.__browsemiumContexts = window.__browsemiumContexts || [];
      window.__browsemiumMuted = window.__browsemiumMuted || false;
      window.__browsemiumCaptureStreams = window.__browsemiumCaptureStreams || [];

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

      // Microphone, camera, and screen-share tracks are tracked so a silent
      // call still counts as "in use". Wrapping the promise-returning methods
      // is the only public way to observe this; a page that obtains a track
      // before this script runs is invisible to it.
      try {
        var devices = navigator.mediaDevices;
        if (devices && !devices.__browsemiumPatched) {
          var remember = function(promise) {
            return promise.then(function(stream) {
              try {
                window.__browsemiumCaptureStreams.push(stream);
                var tracks = stream.getTracks ? stream.getTracks() : [];
                tracks.forEach(function(track) {
                  track.addEventListener('ended', function() { window.__browsemiumReportAudio(); });
                });
                window.__browsemiumReportAudio();
              } catch (error) {}
              return stream;
            });
          };
          var wrap = function(name) {
            var original = devices[name];
            if (typeof original !== 'function') { return; }
            devices[name] = function(constraints) {
              return remember(original.call(devices, constraints));
            };
          };
          wrap('getUserMedia');
          wrap('getDisplayMedia');
          devices.__browsemiumPatched = true;
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
        var capturing = false;
        try {
          capturing = window.__browsemiumCaptureStreams.some(function(stream) {
            return (stream.getTracks ? stream.getTracks() : []).some(function(track) {
              return track.readyState === 'live';
            });
          });
        } catch (error) {}
        try {
          window.webkit.messageHandlers.\(messageHandlerName).postMessage({
            playing: playing,
            muted: window.__browsemiumMuted,
            capturing: capturing
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
/// The protocol requirement is nonisolated, and in older WebKit SDKs
/// `WKScriptMessage` itself is main-actor isolated. WebKit delivers these
/// callbacks on the main thread, so the body is read inside
/// `MainActor.assumeIsolated`, which is portable across toolchains.
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
        MainActor.assumeIsolated {
            guard let payload = message.body as? [String: Any] else { return }
            let playing = payload["playing"] as? Bool ?? false
            let muted = payload["muted"] as? Bool ?? false
            let capturing = payload["capturing"] as? Bool ?? false
            runtime?.updateAudioState(isPlaying: playing, isMuted: muted, isCapturingMedia: capturing)
        }
    }
}
