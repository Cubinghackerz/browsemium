import BrowsemiumCore
import Foundation
import Testing
import WebKit
@testable import BrowsemiumEngine

@MainActor
private final class Recorder: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var bodies: [Any] = []
    var loaded = false

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { bodies.append(message.body) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { loaded = true }
    }
}

@MainActor
private func loadLogin(_ html: String, server: FixtureServer) async throws -> (WKWebView, Recorder) {
    server.page("/login", html)
    server.page("/session", "<html><body>ok</body></html>")
    let recorder = Recorder()
    let view = WebViewFactory().makeWebView(store: .ephemeral)
    let controller = view.configuration.userContentController
    controller.add(recorder, contentWorld: SignInFormMonitor.world, name: SignInFormMonitor.messageHandlerName)
    controller.addUserScript(SignInFormMonitor.makeUserScript())
    view.navigationDelegate = recorder
    view.load(URLRequest(url: URL(string: server.base + "/login")!))
    _ = try await waitFor { recorder.loaded }
    return (view, recorder)
}

private let secureLogin = URL(string: "https://app.example.com/login")

@Test @MainActor
func aSubmittedSignInIsReportedWithFieldTypes() async throws {
    let server = try await FixtureServer.start()
    let (view, recorder) = try await loadLogin("""
        <html><body><form id="f" method="post" action="/session">
          <input name="email" type="email" value="ann@example.com">
          <input name="pw" type="password" value="correct horse" autocomplete="current-password">
          <input name="csrf" type="hidden" value="secret-token">
          <input type="checkbox" name="remember" checked>
        </form></body></html>
        """, server: server)

    _ = try? await view.evaluateJavaScript("document.getElementById('f').requestSubmit()")
    _ = try await waitFor { !recorder.bodies.isEmpty }

    let body = try #require(recorder.bodies.first)
    // The fixture is served over http on loopback; the form's action as the
    // page reported it is an absolute URL on that origin.
    var payload = try #require(body as? [String: Any])
    #expect((payload["action"] as? String)?.hasSuffix("/session") == true)
    payload["action"] = "https://app.example.com/session"
    let candidate = try #require(SignInFormMonitor.candidate(from: payload, pageURL: secureLogin))
    #expect(candidate.username == "ann@example.com")
    #expect(candidate.password == "correct horse")
    #expect(candidate.host == "app.example.com")
    // Hidden inputs and checkboxes are never reported.
    let fields = ((body as? [String: Any])?["fields"] as? [[String: Any]]) ?? []
    #expect(fields.map { $0["type"] as? String } == ["email", "password"])
}

@Test @MainActor
func formsWithoutExactlyOnePasswordFieldAreNeverReported() async throws {
    let server = try await FixtureServer.start()
    let (view, recorder) = try await loadLogin("""
        <html><body>
        <form id="search" action="/session"><input name="q" value="swift"></form>
        <form id="signup" action="/session"><input name="email" value="a@x.test">
          <input type="password" name="a" value="x"><input type="password" name="b" value="x"></form>
        </body></html>
        """, server: server)

    _ = try? await view.evaluateJavaScript("document.getElementById('search').requestSubmit()")
    _ = try? await view.evaluateJavaScript("document.getElementById('signup').requestSubmit()")
    try await Task.sleep(for: .milliseconds(500))

    #expect(recorder.bodies.isEmpty)
}

@Test @MainActor
func thePageItselfCannotReachTheSignInHandler() async throws {
    let server = try await FixtureServer.start()
    let (view, recorder) = try await loadLogin("<html><body>hostile page</body></html>", server: server)

    // From the page's own world the handler does not exist, so a script
    // cannot forge an offer.
    let reachable = try await view.evaluateJavaScript(
        "typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.browsemiumSignIn)"
    ) as? String
    #expect(reachable == "undefined")
    _ = try? await view.evaluateJavaScript(
        "window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.browsemiumSignIn && window.webkit.messageHandlers.browsemiumSignIn.postMessage({fields:[]})"
    )
    try await Task.sleep(for: .milliseconds(300))
    #expect(recorder.bodies.isEmpty)
}

@Test
func malformedReportsAreIgnored() {
    #expect(SignInFormMonitor.candidate(from: "not a dictionary", pageURL: secureLogin) == nil)
    #expect(SignInFormMonitor.candidate(from: ["fields": "nope"], pageURL: secureLogin) == nil)
    #expect(SignInFormMonitor.candidate(from: ["fields": [[String: Any]](), "action": "https://evil.test/x"], pageURL: secureLogin) == nil)
    let tooMany = (0..<60).map { ["name": "f\($0)", "type": "text", "value": "v"] }
    #expect(SignInFormMonitor.candidate(from: ["fields": tooMany], pageURL: secureLogin) == nil)
}
