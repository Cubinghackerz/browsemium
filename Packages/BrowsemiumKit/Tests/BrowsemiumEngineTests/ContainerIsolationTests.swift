import BrowsemiumCore
import BrowsemiumEngineKit
import Foundation
import Testing
import WebKit
@testable import BrowsemiumEngine

@MainActor
private func runtime(container: UUID?, isPrivate: Bool = false) -> TabRuntime {
    let runtime = TabRuntime(
        tabID: TabID(), isPrivate: isPrivate, factory: WebViewFactory(),
        captureService: ContentCaptureService(), downloadCoordinator: DownloadCoordinator()
    )
    runtime.containerID = container
    return runtime
}

@MainActor
private func load(_ runtime: TabRuntime, _ url: String) async throws {
    var finished = false
    runtime.onEvent = { if case .finished = $0 { finished = true } }
    runtime.load(URL(string: url)!)
    _ = try await waitFor { finished }
}

@MainActor
private func cookies(in runtime: TabRuntime) async throws -> String {
    try await runtime.ensureWebView().evaluateJavaScript("document.cookie") as? String ?? ""
}

@Test @MainActor
func twoContainersOnTheSameSiteDoNotShareLogins() async throws {
    let server = try await FixtureServer.start()
    server.route("/login", .init(headers: ["Set-Cookie": "session=alpha; Path=/"], body: "<html><body>in</body></html>"))
    server.page("/home", "<html><body>home</body></html>")
    let storeA = UUID()
    let storeB = UUID()
    defer {
        WKWebsiteDataStore.remove(forIdentifier: storeA) { _ in }
        WKWebsiteDataStore.remove(forIdentifier: storeB) { _ in }
    }

    let first = runtime(container: storeA)
    try await load(first, server.base + "/login")
    try await load(first, server.base + "/home")
    #expect(try await cookies(in: first).contains("session=alpha"))

    // Same site, different container: no cookie.
    let second = runtime(container: storeB)
    try await load(second, server.base + "/home")
    #expect(try await cookies(in: second).isEmpty)

    // Same container again (a new tab in the same group): the login is there.
    let sibling = runtime(container: storeA)
    try await load(sibling, server.base + "/home")
    #expect(try await cookies(in: sibling).contains("session=alpha"))
}

@Test @MainActor
func aContainerDoesNotSeeTheProfileStore() async throws {
    let server = try await FixtureServer.start()
    server.route("/login", .init(headers: ["Set-Cookie": "profile-session=1; Path=/"], body: "<html><body>in</body></html>"))
    server.page("/home", "<html><body>home</body></html>")
    let store = UUID()
    defer { WKWebsiteDataStore.remove(forIdentifier: store) { _ in } }

    // A tab with no container uses the profile's store (here, the shared
    // default, since no profile identifier is configured in tests).
    let profileTab = runtime(container: nil)
    try await load(profileTab, server.base + "/login")
    try await load(profileTab, server.base + "/home")
    #expect(try await cookies(in: profileTab).contains("profile-session=1"))

    let contained = runtime(container: store)
    try await load(contained, server.base + "/home")
    #expect(!(try await cookies(in: contained)).contains("profile-session"))
}

@Test @MainActor
func privateBrowsingBeatsAContainer() {
    let privateTab = runtime(container: UUID(), isPrivate: true)
    let view = privateTab.ensureWebView()
    #expect(view.configuration.websiteDataStore.isPersistent == false)
}

@Test @MainActor
func containerViewsCarryNoExtensions() throws {
    let configuration = WebViewFactory().makeConfiguration(store: .container(UUID()))
    #expect(configuration.websiteDataStore.isPersistent)
    if #available(macOS 15.4, *) {
        #expect(configuration.webExtensionController == nil)
    }
}

@Test @MainActor
func theControllerAsksEveryResolverAndPrivateTabsAreNeverResolved() throws {
    let controller = BrowserRuntimeController()
    let container = UUID()
    let token = controller.addDataStoreResolver { _ in nil }
    _ = controller.addDataStoreResolver { _ in container }

    let tab = TabID()
    #expect(controller.runtime(for: tab).containerID == container)

    controller.setPrivateBrowsing(true)
    let privateTab = TabID()
    #expect(controller.runtime(for: privateTab).containerID == nil)
    controller.removeDataStoreResolver(token)
}
