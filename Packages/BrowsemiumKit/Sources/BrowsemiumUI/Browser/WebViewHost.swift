import BrowsemiumCore
import BrowsemiumEngine
import AppKit
import SwiftUI

struct WebViewHost: NSViewRepresentable {
    let runtime: BrowserRuntimeController
    let tabID: TabID
    let isPrivate: Bool

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        runtime.attach(tabID: tabID, to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        for subview in nsView.subviews {
            subview.removeFromSuperview()
        }
    }
}
