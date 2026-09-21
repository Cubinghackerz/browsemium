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
        }
        engine.attach(tabID: tabID, to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? EngineHostView)?.onFrameChange = nil
        for subview in nsView.subviews {
            subview.removeFromSuperview()
        }
    }
}
