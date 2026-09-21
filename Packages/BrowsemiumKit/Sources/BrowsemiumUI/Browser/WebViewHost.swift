import BrowsemiumCore
import BrowsemiumEngine
import AppKit
import SwiftUI
import BrowsemiumEngineKit

struct WebViewHost: NSViewRepresentable {
    let engine: any BrowserEngine
    let tabID: TabID
    let isPrivate: Bool

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        engine.attach(tabID: tabID, to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        for subview in nsView.subviews {
            subview.removeFromSuperview()
        }
    }
}
