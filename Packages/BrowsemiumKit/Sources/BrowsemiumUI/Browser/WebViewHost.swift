import BrowsemiumCore
import BrowsemiumEngine
import AppKit
import SwiftUI
import BrowsemiumEngineKit

/// The container an engine's web content lives inside.
///
/// `updateNSView` only runs when SwiftUI state changes — it does not run when
/// the view's frame changes during layout. CEF needs `WasResized` on every
/// frame change or its renderer keeps the viewport it was created with
/// (1x1 when the host attaches before layout) and paints nothing. WebKit
/// tracks its own bounds via autoresizing, so re-attaching is a no-op there.
final class EngineHostView: NSView {
    var onFrameChange: (@MainActor () -> Void)?
    /// Fires when the user clicks anywhere in the pane, including inside the
    /// web view. Split view uses it to move focus to the pane that was
    /// clicked. A gesture recognizer must not be used here: one installed on
    /// the web view's superview competes with WebKit's own click handling and
    /// the page never sees the click.
    var onClick: (@MainActor () -> Void)?
    private var clickMonitor: Any?

    /// Watches mouse-downs without consuming them, so the page still receives
    /// the click. Focus is deferred until after this event is delivered —
    /// focusing synchronously rebuilds SwiftUI state before WebKit handles it.
    func installClickMonitorIfNeeded() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard !self.bounds.isEmpty, self.bounds.contains(point) else { return event }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.onClick?()
                }
            }
            return event
        }
    }

    func removeClickMonitor() {
        guard let clickMonitor else { return }
        NSEvent.removeMonitor(clickMonitor)
        self.clickMonitor = nil
    }

    isolated deinit {
        removeClickMonitor()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard !NSEqualSizes(newSize, .zero) else { return }
        MainActor.assumeIsolated {
            onFrameChange?()
        }
    }

    // The webview is transparent (drawsBackground is off), so this color shows
    // through any unpainted page region. It must be the document canvas color,
    // not a fixed color: hardcoded black made pages with transparent heroes
    // render dark text on black, and flashed black on rubber-band overscroll
    // in light mode. CGColor is resolved at set-time, so re-resolve whenever
    // the effective appearance changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }
}

struct WebViewHost: NSViewRepresentable {
    let engine: any BrowserEngine
    let tabID: TabID
    let isPrivate: Bool
    /// Called when the user clicks into this pane. Split view passes a focus
    /// hand-off; single-pane hosts leave it nil.
    var onFocus: (@MainActor () -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let container = EngineHostView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let host = nsView as? EngineHostView {
            host.onFrameChange = { [engine, weak host] in
                guard let host else { return }
                engine.attach(tabID: tabID, to: host)
            }
            host.onClick = onFocus
            if onFocus != nil {
                host.installClickMonitorIfNeeded()
            } else {
                host.removeClickMonitor()
            }
        }
        engine.attach(tabID: tabID, to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? EngineHostView)?.onFrameChange = nil
        (nsView as? EngineHostView)?.onClick = nil
        (nsView as? EngineHostView)?.removeClickMonitor()
        for subview in nsView.subviews {
            subview.removeFromSuperview()
        }
    }
}
