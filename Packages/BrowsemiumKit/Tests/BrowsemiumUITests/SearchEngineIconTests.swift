import AppKit
import Testing
@testable import BrowsemiumUI

/// Menu labels rasterise their content at intrinsic size, so the engine marks
/// must already be 12×12 images. A 96px asset dropped in raw renders as a 96pt
/// glyph overflowing the address bar — which is exactly what happened.
@Test @MainActor
func engineIconsArePresizedTemplates() throws {
    for name in ["Google", "DuckDuckGo", "Bing", "Brave"] {
        let icon = try #require(
            BrowserToolbar.engineIcon(for: name),
            "no icon for \(name)"
        )
        #expect(icon.size.width == 12)
        #expect(icon.size.height == 12)
        #expect(icon.isTemplate, "\(name) must tint with the theme")
    }
}

@Test @MainActor
func customEngineFallsBackToTheLetterMark() {
    #expect(BrowserToolbar.engineIcon(for: "Custom") == nil)
    #expect(BrowserToolbar.engineIconName(for: "Custom") == nil)
}
