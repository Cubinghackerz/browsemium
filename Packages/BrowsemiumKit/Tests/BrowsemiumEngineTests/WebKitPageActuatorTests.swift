import AppKit
import BrowsemiumCore
import BrowsemiumEngineKit
import Foundation
import Testing
import WebKit
@testable import BrowsemiumEngine

private let fixturePage = """
<!doctype html><html><head><title>Fixture</title></head><body>
<h1>Hello fixture</h1>
<a id="next" href="/next">Next page</a>
<button id="act" onclick="window.__clicks=(window.__clicks||0)+1">Do thing</button>
<label for="q">Search</label><input id="q" type="text">
<input id="pw" type="password" name="password" aria-label="Password">
<input id="card" type="text" name="cardnumber" placeholder="Card number">
<input id="otp" type="text" autocomplete="one-time-code" aria-label="Code">
<input id="file" type="file" aria-label="Upload">
<form action="/submit" method="post"><input type="text" id="note" name="note" aria-label="Note"><button id="send" type="submit">Send</button></form>
<button id="hidden" style="display:none">Hidden</button>
<button id="off" disabled>Disabled</button>
<script>
  window.__events = [];
  document.getElementById('q').addEventListener('input', function () { window.__events.push('input'); });
  document.getElementById('q').addEventListener('change', function () { window.__events.push('change'); });
</script>
</body></html>
"""

/// A real WKWebView task page served from a loopback fixture server.
@MainActor
private final class ActuatorHarness {
    let server: FixtureServer
    let actuator = WebKitPageActuator()
    let dataStoreID = UUID()
    let tab = TabID()
    var allowed: Set<AgentOrigin>
    private(set) var authorizeCalls: [URL] = []

    var base: URL { URL(string: server.base)! }
    var baseOrigin: AgentOrigin { try! AgentOrigin(base) }
    var webView: WKWebView { actuator.webViewForTesting(tab)! }

    init(access: Bool = true) async throws {
        server = try await FixtureServer.start()
        allowed = []
        allowed = [try AgentOrigin(string: server.base)]
        actuator.setAgentAccess(access)
        try actuator.createTab(tab, dataStoreID: dataStoreID) { [unowned self] url in
            self.authorizeCalls.append(url)
            guard let origin = try? AgentOrigin(url) else { return false }
            return self.allowed.contains(origin)
        }
        server.page("/", fixturePage)
    }

    func load(_ path: String = "/") async throws {
        try await actuator.navigate(tab, to: URL(string: server.base + path)!)
    }

    func js(_ source: String) async throws -> Any? {
        try await webView.evaluateJavaScript(source)
    }

    func clicks() async throws -> Int {
        ((try await js("window.__clicks")) as? Int) ?? 0
    }

    /// The snapshot element whose accessible name is `name`.
    func snapshotElement(named name: String) async throws -> AgentElement {
        let snapshot = try await actuator.snapshot(tab)
        return try #require(snapshot.elements.first { $0.name == name }, "No element named \(name)")
    }

    func shutdown() async {
        actuator.closeTab(tab)
        server.stop()
        try? await WKWebsiteDataStore.remove(forIdentifier: dataStoreID)
    }
}

// MARK: - Navigation

@Suite("WebKit actuator: navigation", .serialized) @MainActor
struct WebKitActuatorNavigationTests {
    @Test func aGrantedNavigationLoadsAndReportsTheOrigin() async throws {
        let h = try await ActuatorHarness()
        try await h.load("/")
        #expect(h.actuator.currentOrigin(h.tab) == h.baseOrigin)
        #expect(h.server.seenPaths.contains("/"))
        await h.shutdown()
    }

    @Test func anUngrantedOriginIsRefusedAndNeverRequested() async throws {
        let h = try await ActuatorHarness()
        h.server.page("/landing", "<html><body>other</body></html>")
        let other = URL(string: h.server.other + "/landing")!
        await expectAgentError(.denied) { try await h.actuator.navigate(h.tab, to: other) }
        #expect(!h.server.seen.contains { $0.host.hasPrefix("localhost") })
        #expect(h.actuator.currentOrigin(h.tab) == nil)
        await h.shutdown()
    }

    @Test func aCrossOriginServerRedirectIsRefusedBeforeItIsFetched() async throws {
        let h = try await ActuatorHarness()
        h.server.page("/landing", "<html><body>other origin</body></html>")
        h.server.route("/go", .init(status: 302, headers: ["Location": "http://localhost:{{PORT}}/landing"]))
        await expectAgentError(.denied) { try await h.load("/go") }
        // The first hop was fetched (it is in the grant); the redirect target never was.
        #expect(h.server.seenPaths.contains("/go"))
        #expect(!h.server.seen.contains { $0.path == "/landing" })
        #expect(h.actuator.currentOrigin(h.tab) != (try AgentOrigin(string: h.server.other)))
        await h.shutdown()
    }

    @Test func aSameOriginRedirectIsAllowed() async throws {
        let h = try await ActuatorHarness()
        h.server.route("/hop", .init(status: 302, headers: ["Location": "/"]))
        try await h.load("/hop")
        #expect(h.actuator.currentOrigin(h.tab) == h.baseOrigin)
        await h.shutdown()
    }

    @Test func aPageThatNavigatesItselfOffScopeIsStopped() async throws {
        let h = try await ActuatorHarness()
        h.server.page("/landing", "<html><body>other origin</body></html>")
        h.server.page("/jump", "<html><body><script>setTimeout(function(){ location.href='http://localhost:\(h.server.port)/landing'; }, 50);</script></body></html>")
        try await h.load("/jump")
        try await Task.sleep(for: .milliseconds(1_000))
        #expect(h.actuator.currentOrigin(h.tab) == h.baseOrigin)
        #expect(!h.server.seen.contains { $0.path == "/landing" })
        await h.shutdown()
    }

    @Test func nonWebSchemesNeverLoad() async throws {
        let h = try await ActuatorHarness()
        try await h.load("/")
        _ = try? await h.js("location.href = 'file:///etc/hosts'")
        _ = try? await h.js("location.href = 'data:text/html,<p>x</p>'")
        try await Task.sleep(for: .milliseconds(600))
        #expect(h.actuator.currentOrigin(h.tab) == h.baseOrigin)
        await h.shutdown()
    }

    @Test func popupsAreBlockedAndDialogsDoNotHangTheLoad() async throws {
        let h = try await ActuatorHarness()
        h.server.page("/noisy", """
        <html><body><script>
          window.__popup = window.open('/') === null;
          alert('hi'); window.__confirm = confirm('sure'); window.__prompt = prompt('name');
        </script></body></html>
        """)
        try await h.load("/noisy")
        #expect((try await h.js("window.__popup")) as? Bool == true)
        #expect((try await h.js("window.__confirm")) as? Bool == false)
        #expect((try await h.js("window.__prompt === null")) as? Bool == true)
        await h.shutdown()
    }

    @Test func aHangingLoadEndsAtTheDeadline() async throws {
        let h = try await ActuatorHarness()
        h.actuator.navigationTimeout = .milliseconds(400)
        h.server.route("/hang", .init(body: "late", delay: 8))
        await expectAgentError(.unavailable) { try await h.load("/hang") }
        await h.shutdown()
    }

    @Test func aScriptOnABlockedPageEndsAtTheDeadline() async throws {
        let h = try await ActuatorHarness()
        h.actuator.scriptTimeout = .milliseconds(600)
        h.server.page("/spin", "<html><body><script>setTimeout(function(){ while (true) {} }, 50);</script></body></html>")
        try await h.load("/spin")
        try await Task.sleep(for: .milliseconds(300))
        await expectAgentError(.unavailable) { _ = try await h.actuator.readText(h.tab) }
        await h.shutdown()
    }
}

// MARK: - Takeover and access

@Suite("WebKit actuator: access and takeover", .serialized) @MainActor
struct WebKitActuatorAccessTests {
    @Test func withAccessOffEveryOperationIsDenied() async throws {
        let h = try await ActuatorHarness(access: false)
        let element = AgentElement(id: "e1", role: "button", name: "x", origin: h.baseOrigin, fingerprint: "f", isEditable: false, isSensitive: false)
        await expectAgentError(.denied) { try await h.load("/") }
        await expectAgentError(.denied) { _ = try await h.actuator.snapshot(h.tab) }
        await expectAgentError(.denied) { _ = try await h.actuator.readText(h.tab) }
        await expectAgentError(.denied) { _ = try await h.actuator.screenshot(h.tab) }
        await expectAgentError(.denied) { _ = try await h.actuator.resolve("e1", in: h.tab) }
        await expectAgentError(.denied) { try await h.actuator.perform(.click(element), in: h.tab) }
        #expect(h.server.seen.isEmpty)
        await h.shutdown()
    }

    @Test func takeoverKeepsThePageAndLetsThePersonNavigate() async throws {
        let h = try await ActuatorHarness()
        h.server.page("/landing", "<html><body>the person went here</body></html>")
        try await h.load("/")
        h.actuator.setAgentAccess(false)
        // The page is still there, and the person is not bound by the grant.
        #expect(h.actuator.currentOrigin(h.tab) == h.baseOrigin)
        #expect(h.actuator.tabs[h.tab] != nil)
        let before = h.authorizeCalls.count
        _ = try await h.js("location.href = 'http://localhost:\(h.server.port)/landing'")
        #expect(try await waitFor { h.actuator.currentOrigin(h.tab) == (try AgentOrigin(string: h.server.other)) })
        #expect(h.authorizeCalls.count == before)
        await h.shutdown()
    }

    @Test func turningAccessOffCancelsALoadInFlightAndFailsItsCall() async throws {
        let h = try await ActuatorHarness()
        h.server.route("/slow", .init(body: "slow", delay: 5))
        let started = ContinuousClock.now
        let navigation = Task { try await h.load("/slow") }
        #expect(try await waitFor { h.server.seenPaths.contains("/slow") })
        h.actuator.setAgentAccess(false)
        let result = await navigation.result
        #expect((result.failureValue as? AgentError) == .denied)
        #expect(ContinuousClock.now - started < .seconds(4))
        #expect(h.actuator.tabs[h.tab] != nil)
        await h.shutdown()
    }

    @Test func tabsAreBoundedAndIdsAreUnique() throws {
        let actuator = WebKitPageActuator()
        let store = UUID()
        let ids = (0..<4).map { _ in TabID() }
        for id in ids { try actuator.createTab(id, dataStoreID: store) { _ in false } }
        #expect(throws: AgentError.tabLimit) { try actuator.createTab(TabID(), dataStoreID: store) { _ in false } }
        #expect(throws: AgentError.denied) { try actuator.createTab(ids[0], dataStoreID: store) { _ in false } }
        for id in ids { actuator.closeTab(id) }
    }

    @Test func aTabUsesExactlyTheGrantedPersistentStore() async throws {
        let h = try await ActuatorHarness()
        let store = h.webView.configuration.websiteDataStore
        #expect(store.isPersistent)
        #expect(store.identifier == h.dataStoreID)
        await h.shutdown()
    }

    @Test func attachingAndDetachingMovesOnlyTheTaskView() async throws {
        let h = try await ActuatorHarness()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        h.actuator.attach(h.tab, to: host)
        #expect(h.webView.superview === host)
        h.actuator.detach(h.tab)
        #expect(h.webView.superview == nil)
        await h.shutdown()
    }

    @Test func closingATabReleasesItAndFailsPendingWork() async throws {
        let h = try await ActuatorHarness()
        h.server.route("/slow", .init(body: "slow", delay: 5))
        let navigation = Task { try await h.load("/slow") }
        #expect(try await waitFor { h.server.seenPaths.contains("/slow") })
        h.actuator.closeTab(h.tab)
        let result = await navigation.result
        #expect(result.failureValue != nil)
        #expect(h.actuator.tabs.isEmpty)
        h.server.stop()
        try? await WKWebsiteDataStore.remove(forIdentifier: h.dataStoreID)
    }
}

// MARK: - Reading and acting

@Suite("WebKit actuator: page operations", .serialized) @MainActor
struct WebKitActuatorOperationTests {
    @Test func aSnapshotListsVisibleEnabledControlsWithOpaqueReferences() async throws {
        let h = try await ActuatorHarness()
        try await h.load("/")
        let snapshot = try await h.actuator.snapshot(h.tab)
        #expect(snapshot.origin == h.baseOrigin)
        #expect(snapshot.title == "Fixture")
        let names = snapshot.elements.map(\.name)
        #expect(names.contains("Next page"))
        #expect(names.contains("Do thing"))
        #expect(names.contains("Search"))
        #expect(!names.contains("Hidden"))
        #expect(!names.contains("Disabled"))
        let ids = snapshot.elements.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(snapshot.elements.allSatisfy { $0.origin == h.baseOrigin && !$0.fingerprint.isEmpty })
        await h.shutdown()
    }

    @Test func sensitiveFieldsAreFlaggedFromWhatThePageDeclares() async throws {
        let h = try await ActuatorHarness()
        try await h.load("/")
        let snapshot = try await h.actuator.snapshot(h.tab)
        for name in ["Password", "Card number", "Code", "Upload"] {
            let element = try #require(snapshot.elements.first { $0.name == name }, "missing \(name)")
            #expect(element.isSensitive, "\(name) should be sensitive")
        }
        let search = try #require(snapshot.elements.first { $0.name == "Search" })
        #expect(!search.isSensitive)
        #expect(search.isEditable)
        let button = try #require(snapshot.elements.first { $0.name == "Do thing" })
        #expect(!button.isEditable && !button.isSensitive)
        await h.shutdown()
    }

    @Test func fingerprintsAreStableAcrossSnapshotsAndTypedTextNeverLeaksIn() async throws {
        let h = try await ActuatorHarness()
        try await h.load("/")
        let first = try await h.actuator.snapshot(h.tab)
        _ = try await h.js("document.getElementById('q').value = 'my-private-value-5521'")
        let second = try await h.actuator.snapshot(h.tab)
        #expect(first.elements == second.elements)
        let dump = second.elements.map { "\($0.name)|\($0.role)|\($0.fingerprint)" }.joined()
        #expect(!dump.contains("my-private-value-5521"))
        await h.shutdown()
    }

    @Test func readTextReturnsVisibleTextAndIsBounded() async throws {
        let h = try await ActuatorHarness()
        h.server.page("/long", "<html><body><p>\(String(repeating: "word ", count: 40_000))</p></body></html>")
        try await h.load("/")
        let text = try await h.actuator.readText(h.tab)
        #expect(text.contains("Hello fixture"))
        try await h.load("/long")
        let long = try await h.actuator.readText(h.tab)
        #expect(long.count <= AgentLimits.maxReadCharacters)
        await h.shutdown()
    }

    @Test func resolveReturnsTheLiveElementAndUnknownOrRemovedReferencesAreStale() async throws {
        let h = try await ActuatorHarness()
        try await h.load("/")
        let button = try await h.snapshotElement(named: "Do thing")
        let live = try await h.actuator.resolve(button.id, in: h.tab)
        #expect(live == button)
        await expectAgentError(.staleElement) { _ = try await h.actuator.resolve("e99999", in: h.tab) }
        _ = try await h.js("document.getElementById('act').remove()")
        await expectAgentError(.staleElement) { _ = try await h.actuator.resolve(button.id, in: h.tab) }
        await h.shutdown()
    }

    @Test func aClickRunsExactlyOnceOnTheApprovedElement() async throws {
        let h = try await ActuatorHarness()
        try await h.load("/")
        let button = try await h.snapshotElement(named: "Do thing")
        try await h.actuator.perform(.click(button), in: h.tab)
        #expect(try await h.clicks() == 1)
        await h.shutdown()
    }

    @Test func typingSetsTheValueAndFiresInputAndChange() async throws {
        let h = try await ActuatorHarness()
        try await h.load("/")
        let field = try await h.snapshotElement(named: "Search")
        try await h.actuator.perform(.type(field, "hello world"), in: h.tab)
        #expect((try await h.js("document.getElementById('q').value")) as? String == "hello world")
        #expect((try await h.js("window.__events.join(',')")) as? String == "input,change")
        await h.shutdown()
    }

    @Test func aChangedElementIsRejectedAsStaleAndNothingRuns() async throws {
        let h = try await ActuatorHarness()
        try await h.load("/")
        let button = try await h.snapshotElement(named: "Do thing")
        _ = try await h.js("document.getElementById('act').textContent = 'Pay now'")
        await expectAgentError(.staleElement) { try await h.actuator.perform(.click(button), in: h.tab) }
        #expect(try await h.clicks() == 0)
        await h.shutdown()
    }

    @Test func aSwappedLinkTargetIsRejectedAsStale() async throws {
        let h = try await ActuatorHarness()
        try await h.load("/")
        let link = try await h.snapshotElement(named: "Next page")
        _ = try await h.js("document.getElementById('next').setAttribute('href', 'http://localhost:\(h.server.port)/landing')")
        await expectAgentError(.staleElement) { try await h.actuator.perform(.click(link), in: h.tab) }
        #expect(!h.server.seen.contains { $0.path == "/landing" })
        await h.shutdown()
    }

    @Test func theScriptRefusesSensitiveFieldsEvenIfTheCallerClaimsOtherwise() async throws {
        let h = try await ActuatorHarness()
        try await h.load("/")
        let password = try await h.snapshotElement(named: "Password")
        // A caller (or a bug) that lies about sensitivity is still stopped in the page.
        let lie = AgentElement(id: password.id, role: password.role, name: password.name, origin: password.origin,
                               fingerprint: password.fingerprint, isEditable: true, isSensitive: false)
        await expectAgentError(.sensitiveField) { try await h.actuator.perform(.type(lie, "hunter2"), in: h.tab) }
        #expect((try await h.js("document.getElementById('pw').value")) as? String == "")
        await h.shutdown()
    }

    @Test func typingIntoANonEditableElementAndWrongOriginAreDenied() async throws {
        let h = try await ActuatorHarness()
        try await h.load("/")
        let button = try await h.snapshotElement(named: "Do thing")
        await expectAgentError(.denied) { try await h.actuator.perform(.type(button, "x"), in: h.tab) }
        let wrong = AgentElement(id: button.id, role: button.role, name: button.name,
                                 origin: try AgentOrigin(string: "https://elsewhere.test"),
                                 fingerprint: button.fingerprint, isEditable: false, isSensitive: false)
        await expectAgentError(.denied) { try await h.actuator.perform(.click(wrong), in: h.tab) }
        #expect(try await h.clicks() == 0)
        await h.shutdown()
    }

    @Test func browserScriptsLiveInAnIsolatedWorld() async throws {
        let h = try await ActuatorHarness()
        try await h.load("/")
        _ = try await h.actuator.snapshot(h.tab)
        #expect((try await h.js("typeof window.__bmAgentState")) as? String == "undefined")
        await h.shutdown()
    }

    @Test func aHostilePageCannotBlindTheBrowsersOwnChecks() async throws {
        let h = try await ActuatorHarness()
        h.server.page("/hostile", """
        <html><head><title>Hostile</title></head><body>
        <input id="pw" type="password" aria-label="Secret thing">
        <button id="go" onclick="window.__clicks=(window.__clicks||0)+1">Go</button>
        <script>
          Element.prototype.getAttribute = function () { return 'text'; };
          Object.getOwnPropertyDescriptor = function () { return { set: function () {} }; };
          window.Event = function () {};
          HTMLInputElement.prototype.focus = function () {};
        </script></body></html>
        """)
        try await h.load("/hostile")
        let snapshot = try await h.actuator.snapshot(h.tab)
        let pw = try #require(snapshot.elements.first { $0.name == "Secret thing" })
        #expect(pw.isSensitive)
        await h.shutdown()
    }

    @Test func untrustedArgumentsCannotBreakOutOfTheScripts() async throws {
        let h = try await ActuatorHarness()
        try await h.load("/")
        let hostile = "\"; window.__pwn = 1; //"
        await expectAgentError(.staleElement) { _ = try await h.actuator.resolve(hostile, in: h.tab) }
        let field = try await h.snapshotElement(named: "Search")
        let payload = "`${window.__pwn=2}`</script><script>window.__pwn=3</script>'\"\\"
        try await h.actuator.perform(.type(field, payload), in: h.tab)
        #expect((try await h.js("document.getElementById('q').value")) as? String == payload)
        #expect((try await h.js("typeof window.__pwn")) as? String == "undefined")
        await h.shutdown()
    }

    @Test func aScreenshotIsEncodedAndBounded() async throws {
        let h = try await ActuatorHarness()
        try await h.load("/")
        let data = try await h.actuator.screenshot(h.tab)
        #expect(!data.isEmpty)
        #expect(data.count <= 3_000_000)
        let magic = [UInt8](data.prefix(4))
        #expect(magic == [0x89, 0x50, 0x4E, 0x47] || magic.prefix(2) == [0xFF, 0xD8])
        await h.shutdown()
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

@MainActor
private func expectAgentError<T>(
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
