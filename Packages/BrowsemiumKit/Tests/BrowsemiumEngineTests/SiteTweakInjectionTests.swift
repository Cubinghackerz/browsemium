import BrowsemiumCore
import BrowsemiumEngineKit
import Foundation
import Testing
@testable import BrowsemiumEngine

@Test @MainActor
func aTweakRestylesARealPageAndStopsWhenRemoved() async throws {
    let server = try await FixtureServer.start()
    server.page("/", "<html><body><h1 id=\"t\">Title</h1></body></html>")
    let runtime = TabRuntime(
        tabID: TabID(), isPrivate: true, factory: WebViewFactory(),
        captureService: ContentCaptureService(), downloadCoordinator: DownloadCoordinator()
    )
    var finished = false
    runtime.onEvent = { if case .finished = $0 { finished = true } }
    runtime.applyCosmeticRules(["127.0.0.1": "#t { color: rgb(1, 2, 3) !important }"])
    runtime.load(URL(string: server.base + "/")!)
    _ = try await waitFor { finished }

    let color = try await runtime.ensureWebView().evaluateJavaScript(
        "getComputedStyle(document.getElementById('t')).color"
    ) as? String
    #expect(color == "rgb(1, 2, 3)")

    // Removing the rule updates the open page in place, without a reload.
    runtime.applyCosmeticRules([:])
    _ = try await waitFor {
        let current = try await runtime.ensureWebView().evaluateJavaScript(
            "getComputedStyle(document.getElementById('t')).color"
        ) as? String
        return current != "rgb(1, 2, 3)"
    }
}

@Test @MainActor
func theOutlineScriptDescribesStructureWithoutAnyText() async throws {
    let server = try await FixtureServer.start()
    server.page("/", """
        <html><body><main id="app" class="content wide"><h1>Secret headline 12345</h1>
        <aside class="sidebar" role="complementary"><a href="/x">Private link text</a></aside>
        <input id="pw" value="hunter2"><script>var token="abc"</script></main></body></html>
        """)
    let runtime = TabRuntime(
        tabID: TabID(), isPrivate: true, factory: WebViewFactory(),
        captureService: ContentCaptureService(), downloadCoordinator: DownloadCoordinator()
    )
    var finished = false
    runtime.onEvent = { if case .finished = $0 { finished = true } }
    runtime.load(URL(string: server.base + "/")!)
    _ = try await waitFor { finished }

    let outline = try await runtime.ensureWebView().evaluateJavaScript(TweakAssistant.outlineScript) as? String ?? ""
    #expect(outline.contains("main#app.content.wide"))
    #expect(outline.contains("aside.sidebar[role=complementary]"))
    #expect(outline.contains("h1"))
    for secret in ["Secret headline", "12345", "Private link text", "hunter2", "token", "abc", "/x"] {
        #expect(!outline.contains(secret), Comment(rawValue: secret))
    }
}
