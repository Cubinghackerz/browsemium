import BrowsemiumCore
import BrowsemiumEngine
import BrowsemiumEngineKit
import Foundation
import Testing
import WebKit

// MARK: - Helpers

private let pickerPage = """
<!doctype html><html><head><title>Picker test</title></head><body>
<div id="ad-slot">Sponsored</div>
<p id="content">Real content</p>
</body></html>
"""

/// Loads the fixture and waits until the document-end scripts have run.
/// Offscreen WKWebViews still execute scripts; the poll exists because the
/// load itself is asynchronous and the main actor can be queued for seconds
/// under the full suite.
@MainActor
private func loadPickerPage(
    _ controller: BrowserRuntimeController,
    tabID: TabID,
    timeout: Duration = .seconds(20)
) async throws {
    let runtime = controller.runtime(for: tabID)
    let webView = runtime.ensureWebView()
    webView.loadHTMLString(pickerPage, baseURL: URL(string: "https://picker.test/"))
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        let ready = try? await webView.evaluateJavaScript(
            "document.readyState === 'complete' && !!window.__browsemiumElementPicker"
        )
        if (ready as? Bool) == true { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    Issue.record("The picker page never finished loading")
}

/// Collects events from the moment it is created, so a report that lands
/// between "trigger" and "assert" is never missed.
@MainActor
private final class EventCollector {
    var events: [TabRuntimeEvent] = []
    var token: UUID?
}

@MainActor
private func collectEvents(_ controller: BrowserRuntimeController) -> EventCollector {
    let collector = EventCollector()
    collector.token = controller.addEventObserver { _, event in
        collector.events.append(event)
    }
    return collector
}

@MainActor
private func waitForEvent(
    in collector: EventCollector,
    predicate: (TabRuntimeEvent) -> Bool,
    timeout: Duration = .seconds(15)
) async -> TabRuntimeEvent? {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let match = collector.events.first(where: predicate) { return match }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return collector.events.first(where: predicate)
}

// MARK: - Picking

@Test @MainActor
func pickingAnElementReportsItsVerifiedSelector() async throws {
    let controller = BrowserRuntimeController()
    let tabID = TabID()
    try await loadPickerPage(controller, tabID: tabID)

    let collector = collectEvents(controller)
    defer { if let token = collector.token { controller.removeEventObserver(token) } }

    let webView = controller.runtime(for: tabID).currentWebView
    controller.beginElementPicking(tabID: tabID)
    try await Task.sleep(for: .milliseconds(300))

    try await webView?.evaluateJavaScript("""
        document.getElementById('ad-slot').dispatchEvent(
            new MouseEvent('click', { bubbles: true, cancelable: true })
        )
    """)

    let event = await waitForEvent(in: collector) {
        if case .elementPicked = $0 { return true }
        return false
    }
    guard case .elementPicked(let pick)? = event else {
        Issue.record("No elementPicked event arrived")
        return
    }
    #expect(pick.selector == "#ad-slot")
    #expect(pick.label == "div#ad-slot")
    #expect(pick.matchCount == 1)
}

@Test @MainActor
func escapeCancelsPickingWithoutSaving() async throws {
    let controller = BrowserRuntimeController()
    let tabID = TabID()
    try await loadPickerPage(controller, tabID: tabID)

    let collector = collectEvents(controller)
    defer { if let token = collector.token { controller.removeEventObserver(token) } }

    let webView = controller.runtime(for: tabID).currentWebView
    controller.beginElementPicking(tabID: tabID)
    try await Task.sleep(for: .milliseconds(300))

    try await webView?.evaluateJavaScript("""
        document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    """)

    let event = await waitForEvent(in: collector) {
        if case .elementPickCancelled = $0 { return true }
        return false
    }
    if case .elementPickCancelled? = event {
        // The overlay is removed with the mode.
        let overlayCount = try await webView?.evaluateJavaScript(
            "document.querySelectorAll('[data-browsemium-picker]').length"
        )
        #expect((overlayCount as? Int) == 0)
    } else {
        Issue.record("No elementPickCancelled event arrived")
    }
}

// MARK: - Saved rules

@Test @MainActor
func savedRulesApplyAtDocumentStartForTheirHost() async throws {
    let controller = BrowserRuntimeController()
    controller.replaceCosmeticRules(["picker.test": "#ad-slot { display: none !important; }"])
    let tabID = TabID()
    try await loadPickerPage(controller, tabID: tabID)

    let webView = controller.runtime(for: tabID).currentWebView
    let hidden = try await webView?.evaluateJavaScript(
        "getComputedStyle(document.getElementById('ad-slot')).display"
    )
    let visible = try await webView?.evaluateJavaScript(
        "getComputedStyle(document.getElementById('content')).display"
    )
    #expect((hidden as? String) == "none")
    #expect((visible as? String) != "none")
}

@Test @MainActor
func rulesForAnotherHostLeaveThePageAlone() async throws {
    let controller = BrowserRuntimeController()
    controller.replaceCosmeticRules(["elsewhere.test": "#ad-slot { display: none !important; }"])
    let tabID = TabID()
    try await loadPickerPage(controller, tabID: tabID)

    let webView = controller.runtime(for: tabID).currentWebView
    let display = try await webView?.evaluateJavaScript(
        "getComputedStyle(document.getElementById('ad-slot')).display"
    )
    #expect((display as? String) != "none")
}

@Test @MainActor
func changingRulesUpdatesTheOpenPageWithoutReloading() async throws {
    let controller = BrowserRuntimeController()
    let tabID = TabID()
    try await loadPickerPage(controller, tabID: tabID)

    let webView = controller.runtime(for: tabID).currentWebView
    // A marker that would not survive a reload proves the page stayed put.
    try await webView?.evaluateJavaScript("window.__bmNoReload = true")

    controller.replaceCosmeticRules(["picker.test": "#ad-slot { display: none !important; }"])
    try await Task.sleep(for: .milliseconds(300))

    let hidden = try await webView?.evaluateJavaScript(
        "getComputedStyle(document.getElementById('ad-slot')).display"
    )
    let marker = try await webView?.evaluateJavaScript("window.__bmNoReload === true")
    #expect((hidden as? String) == "none")
    #expect((marker as? Bool) == true)
}
