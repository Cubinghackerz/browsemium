import BrowsemiumCore
import Foundation
import Testing
import WebKit
@testable import BrowsemiumEngine

@MainActor
private func withDeveloperTools<T>(_ enabled: Bool, _ body: () -> T) -> T {
    let previous = WebViewFactory.developerToolsEnabled
    WebViewFactory.developerToolsEnabled = enabled
    defer { WebViewFactory.developerToolsEnabled = previous }
    return body()
}

@Test @MainActor
func developerToolsAreOffByDefaultSoNothingIsInspectable() {
    #expect(BrowserSettings().developerToolsEnabled == false)
    let view = withDeveloperTools(false) { WebViewFactory().makeWebView(store: .ephemeral) }
    #expect(view.isInspectable == false)
    #expect(view.configuration.preferences.value(forKey: "developerExtrasEnabled") as? Bool != true)
}

@Test @MainActor
func turningDeveloperToolsOnMakesNewViewsInspectable() {
    let view = withDeveloperTools(true) { WebViewFactory().makeWebView(store: .ephemeral) }
    #expect(view.isInspectable)
    #expect(view.configuration.preferences.value(forKey: "developerExtrasEnabled") as? Bool == true)
}

@Test @MainActor
func theSettingCanBeFlippedOnALiveView() {
    let view = withDeveloperTools(false) { WebViewFactory().makeWebView(store: .ephemeral) }
    WebInspectorBridge.apply(true, to: view)
    #expect(view.isInspectable)
    #expect(view.configuration.preferences.value(forKey: "developerExtrasEnabled") as? Bool == true)
    WebInspectorBridge.apply(false, to: view)
    #expect(view.isInspectable == false)
}

@Test @MainActor
func theInspectorRefusesAViewThatIsNotInspectable() {
    let view = withDeveloperTools(false) { WebViewFactory().makeWebView(store: .ephemeral) }
    #expect(WebInspectorBridge.show(on: view) == false)
}

@Test @MainActor
func theInternalInspectorStillExistsOnThisWebKit() {
    // If a WebKit update removes these, the bridge degrades to the Develop
    // menu route. This test is the early warning.
    #expect(WebInspectorBridge.isInspectorAvailable)
}

@Test
func olderSavedSettingsDecodeWithDeveloperToolsOff() throws {
    let json = #"{"searchEngineTemplate":"https://example.com/?q=%s","appearance":"system"}"#.data(using: .utf8)!
    let settings = try JSONDecoder().decode(BrowserSettings.self, from: json)
    #expect(settings.developerToolsEnabled == false)
    var changed = settings
    changed.developerToolsEnabled = true
    let round = try JSONDecoder().decode(BrowserSettings.self, from: JSONEncoder().encode(changed))
    #expect(round.developerToolsEnabled)
}
