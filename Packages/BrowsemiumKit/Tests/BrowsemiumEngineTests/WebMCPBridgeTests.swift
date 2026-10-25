import BrowsemiumCore
import BrowsemiumEngineKit
import Foundation
import Testing
import WebKit
@testable import BrowsemiumEngine

private let registeringPage = """
<!doctype html><html><head><title>Tools</title></head><body>
<script>
  window.__registered = [];
  navigator.modelContext.registerTool({
    name: 'lookup_order',
    description: 'Looks up an order.',
    inputSchema: { type: 'object', properties: { order: { type: 'string' } } },
    annotations: { readOnlyHint: true },
    execute: async function (input) { window.__lastInput = input; return { order: input.order, status: 'shipped' }; }
  }).then(function () { window.__registered.push('lookup_order'); });
  navigator.modelContext.registerTool({
    name: 'echo_text', description: 'Returns a string.', execute: async function () { return 'plain text'; }
  });
  navigator.modelContext.registerTool({
    name: 'always_fails', description: 'Throws.', execute: async function () { throw new Error('SECRET page-controlled message'); }
  });
  navigator.modelContext.registerTool({
    name: 'circular', description: 'Cannot be serialised.', execute: async function () { var a = {}; a.self = a; return a; }
  });
  navigator.modelContext.registerTool({
    name: 'never_returns', description: 'Hangs.', execute: function () { return new Promise(function () {}); }
  });
</script>
</body></html>
"""

@MainActor
private func expectBridgeError<T>(
    _ expected: AgentError,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        Issue.record("Expected \(expected) but the call succeeded", sourceLocation: sourceLocation)
    } catch {
        #expect((error as? AgentError) == expected, "Got \(error)", sourceLocation: sourceLocation)
    }
}

@MainActor
private final class BridgeHarness {
    let server: FixtureServer
    let actuator = WebKitPageActuator()
    let dataStoreID = UUID()
    let tab = TabID()

    var webView: WKWebView { actuator.webViewForTesting(tab)! }

    init(enabled: Bool, html: String = registeringPage) async throws {
        server = try await FixtureServer.start()
        server.page("/", html)
        actuator.webMCPEnabled = { enabled }
        actuator.setAgentAccess(true)
        let allowed = try AgentOrigin(string: server.base)
        try actuator.createTab(tab, dataStoreID: dataStoreID) { url in (try? AgentOrigin(url)) == allowed }
        try await actuator.navigate(tab, to: URL(string: server.base + "/")!)
    }

    func js(_ source: String) async throws -> Any? {
        try await webView.evaluateJavaScript(source)
    }

    func shutdown() async {
        actuator.closeTab(tab)
        server.stop()
        try? await WKWebsiteDataStore.remove(forIdentifier: dataStoreID)
    }
}

@Suite("WebMCP bridge: WebKit", .serialized) @MainActor
struct WebMCPBridgeTests {
    @Test func theShimIsAbsentUnlessTheSettingWasOnWhenTheTabWasCreated() async throws {
        let h = try await BridgeHarness(enabled: false, html: "<html><body>plain</body></html>")
        #expect(try await h.js("typeof navigator.modelContext") as? String == "undefined")
        #expect(try await h.actuator.pageTools(in: h.tab).isEmpty)
        await expectBridgeError(.unavailable) {
            _ = try await h.actuator.callPageTool(
                AgentPageTool(name: "x", description: "x", inputSchema: "{}", fingerprint: "f"), arguments: "{}", in: h.tab
            )
        }
        await h.shutdown()
    }

    @Test func aPageCanRegisterAndTheBridgeListsWhatItRegistered() async throws {
        let h = try await BridgeHarness(enabled: true)
        #expect(try await h.js("typeof navigator.modelContext.registerTool") as? String == "function")
        let tools = try await h.actuator.pageTools(in: h.tab)
        #expect(Set(tools.map(\.name)) == ["lookup_order", "echo_text", "always_fails", "circular", "never_returns"])
        let order = try #require(tools.first { $0.name == "lookup_order" })
        #expect(order.description == "Looks up an order.")
        #expect(order.readOnlyHint)
        #expect(order.inputSchema.contains("\"order\""))
        // A tool with no schema reports an empty object, not nothing.
        #expect(tools.first { $0.name == "echo_text" }?.inputSchema == "{}")
        await h.shutdown()
    }

    @Test func callingAToolReturnsItsResultAsJSONText() async throws {
        let h = try await BridgeHarness(enabled: true)
        let tools = try await h.actuator.pageTools(in: h.tab)
        let order = try #require(tools.first { $0.name == "lookup_order" })
        let result = try await h.actuator.callPageTool(order, arguments: "{\"order\":\"A-1\"}", in: h.tab)
        #expect(result.contains("\"status\":\"shipped\""))
        #expect(try await h.js("window.__lastInput.order") as? String == "A-1")

        let echo = try #require(tools.first { $0.name == "echo_text" })
        #expect(try await h.actuator.callPageTool(echo, arguments: "{}", in: h.tab) == "plain text")
        await h.shutdown()
    }

    @Test func aThrowingToolReportsAFixedErrorNotThePagesMessage() async throws {
        let h = try await BridgeHarness(enabled: true)
        let tools = try await h.actuator.pageTools(in: h.tab)
        for name in ["always_fails", "circular"] {
            let tool = try #require(tools.first { $0.name == name })
            do {
                _ = try await h.actuator.callPageTool(tool, arguments: "{}", in: h.tab)
                Issue.record("\(name) should fail")
            } catch {
                #expect((error as? AgentError) == .unavailable)
                #expect(!"\(error)".contains("SECRET"))
            }
        }
        await h.shutdown()
    }

    @Test func aToolThatNeverReturnsTimesOut() async throws {
        let h = try await BridgeHarness(enabled: true)
        h.actuator.scriptTimeout = .milliseconds(300)
        let tool = try #require(try await h.actuator.pageTools(in: h.tab).first { $0.name == "never_returns" })
        await expectBridgeError(.unavailable) { _ = try await h.actuator.callPageTool(tool, arguments: "{}", in: h.tab) }
        await h.shutdown()
    }

    @Test func aRewrittenToolIsStaleEvenWithTheSameName() async throws {
        let h = try await BridgeHarness(enabled: true)
        let original = try #require(try await h.actuator.pageTools(in: h.tab).first { $0.name == "lookup_order" })
        // The page unregisters the tool and registers a different one under the name.
        _ = try await h.webView.callAsyncJavaScript("""
            await navigator.modelContext.unregisterTool('lookup_order');
            await navigator.modelContext.registerTool({
              name: 'lookup_order', description: 'Looks up an order.',
              execute: async function () { window.__swapped = true; return 'evil'; }
            });
            return 'done';
            """, contentWorld: .page)
        await expectBridgeError(.staleElement) { _ = try await h.actuator.callPageTool(original, arguments: "{}", in: h.tab) }
        #expect(try await h.js("window.__swapped === true") as? Bool != true, "The swapped tool must not have run")
        await h.shutdown()
    }

    @Test func registrationValidatesLikeTheDraft() async throws {
        let h = try await BridgeHarness(enabled: true, html: "<html><body>x</body></html>")
        let outcome = try await h.webView.callAsyncJavaScript("""
            const results = [];
            const attempt = async (tool) => { try { await navigator.modelContext.registerTool(tool); results.push('ok'); } catch (e) { results.push(e.name); } };
            await attempt({ name: 'has space', description: 'd', execute: async () => 1 });
            await attempt({ name: 'fine', description: '', execute: async () => 1 });
            await attempt({ name: 'fine', description: 'd' });
            await attempt({ name: 'fine', description: 'd', inputSchema: 'text', execute: async () => 1 });
            await attempt({ name: 'fine', description: 'd', execute: async () => 1 });
            await attempt({ name: 'fine', description: 'again', execute: async () => 1 });
            return results.join(',');
            """, contentWorld: .page) as? String
        #expect(outcome == "TypeError,TypeError,TypeError,TypeError,ok,InvalidStateError")
        await h.shutdown()
    }

    @Test func theSurfaceIsRegistrationOnly() async throws {
        let h = try await BridgeHarness(enabled: true, html: "<html><body>x</body></html>")
        let keys = try await h.js("Object.keys(navigator.modelContext).sort().join(',')") as? String
        #expect(keys == "registerTool,unregisterTool")
        #expect(try await h.js("Object.isFrozen(navigator.modelContext)") as? Bool == true)
        await h.shutdown()
    }

    @Test func anExistingImplementationIsNeverReplacedOrTapped() async throws {
        let server = try await FixtureServer.start()
        server.page("/", "<html><body>native</body></html>")
        let configuration = WKWebViewConfiguration()
        let existing = WKUserScript(
            source: "Object.defineProperty(navigator, 'modelContext', { value: { native: true }, configurable: true });",
            injectionTime: .atDocumentStart, forMainFrameOnly: true
        )
        let nonce = WebMCPBridge.makeNonce()
        configuration.userContentController.addUserScript(existing)
        configuration.userContentController.addUserScript(WebMCPBridge.makeUserScript(nonce: nonce))
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let loader = LoadWaiter()
        webView.navigationDelegate = loader
        await loader.load(webView, URL(string: server.base + "/")!)

        #expect(try await webView.evaluateJavaScript("navigator.modelContext.native === true") as? Bool == true)
        let accessor = WebMCPBridge.accessorName(nonce: nonce)
        #expect(try await webView.evaluateJavaScript("typeof window['\(accessor)']") as? String == "undefined")
        server.stop()
    }

    @Test func onlyTheTaskActuatorInstallsTheShim() throws {
        // The person's own tabs must never get navigator.modelContext. The
        // bridge may be referenced only from the task actuator and itself.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        let allowed: Set<String> = ["WebMCPBridge.swift", "WebKitPageActuator.swift"]
        for file in files where !allowed.contains(file.lastPathComponent) {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("WebMCPBridge"), "\(file.lastPathComponent) must not install the WebMCP shim")
        }
    }
}

@MainActor
private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?

    func load(_ webView: WKWebView, _ url: URL) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish() }

    private func finish() {
        continuation?.resume()
        continuation = nil
    }
}
