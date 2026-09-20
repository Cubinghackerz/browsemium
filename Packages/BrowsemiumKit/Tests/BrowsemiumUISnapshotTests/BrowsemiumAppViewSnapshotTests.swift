import AppKit
import BrowsemiumUI
import SwiftUI
import Testing

/// A deterministic native rendering smoke test. It intentionally exercises
/// the two narrowest supported window sizes so clipped Settings notes and an
/// over-constrained AI dock fail in CI before a screenshot baseline is
/// promoted.
@Test @MainActor
func appViewRendersAtSupportedWindowSizes() {
    let sizes = [
        NSSize(width: 980, height: 620),
        NSSize(width: 1280, height: 800)
    ]

    for size in sizes {
        let model = BrowserWindowModel()
        model.activePanel = .settings
        let host = NSHostingView(rootView: BrowsemiumAppView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        #expect(host.bounds.width == size.width)
        #expect(host.bounds.height == size.height)
        #expect(host.bitmapImageRepForCachingDisplay(in: host.bounds) != nil)
    }
}
