import BrowsemiumCore
import BrowsemiumData
import BrowsemiumExtensions
import BrowsemiumUI
import Foundation
import Testing
import WebKit
import BrowsemiumEngineKit

@MainActor
private func makeSiteControlEnvironment(
    engine: (any BrowserEngine)? = nil
) throws -> BrowserEnvironment {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-site-ctl-\(UUID().uuidString)", isDirectory: true)
    let store = ExtensionStore(rootDirectory: root)
    return BrowserEnvironment.inMemory(engine: engine, extensionStore: store)
}

private func makeSiteControlExtension(named name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-site-ext-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let manifest = """
        {"manifest_version":3,"name":"\(name)","version":"1.0",\
        "host_permissions":["https://example.test/*","https://sibling.test/*"],\
        "content_scripts":[{"matches":["https://example.test/*","https://sibling.test/*"],\
        "js":["content.js"],"run_at":"document_end"}]}
        """
    try manifest.data(using: .utf8)!.write(to: directory.appendingPathComponent("manifest.json"))
    try "document.documentElement.setAttribute('data-site-ctl','1');"
        .data(using: .utf8)!.write(to: directory.appendingPathComponent("content.js"))
    return directory
}

// MARK: - Pure model behaviour (no WebKit needed)

@Test @MainActor
func settingASiteModePersistsAndReadsBack() throws {
    let environment = try makeSiteControlEnvironment(engine: StubEngine())
    let model = BrowserWindowModel(environment: environment)

    model.setExtensionSiteMode(.deny, for: "ext-demo", host: "Example.COM")
    #expect(model.extensionSiteMode(for: "ext-demo", host: "example.com") == .deny)
    #expect(model.extensionSitePolicies(for: "ext-demo").count == 1)

    model.setExtensionSiteMode(.allow, for: "ext-demo", host: "example.com")
    #expect(model.extensionSiteMode(for: "ext-demo", host: "example.com") == .allow)

    model.clearExtensionSiteMode(for: "ext-demo", host: "example.com")
    #expect(model.extensionSiteMode(for: "ext-demo", host: "example.com") == nil)
}

@Test @MainActor
func siteChoicesArePerExtensionAndPerProfile() throws {
    let environment = try makeSiteControlEnvironment(engine: StubEngine())
    let model = BrowserWindowModel(environment: environment)

    model.setExtensionSiteMode(.deny, for: "ext-a", host: "example.com")
    #expect(model.extensionSiteMode(for: "ext-b", host: "example.com") == nil)

    let second = try environment.createProfile(name: "Second")
    try environment.activate(second)
    #expect(model.extensionSiteMode(for: "ext-a", host: "example.com") == nil)
}

@Test @MainActor
func privateWindowsNeitherOfferNorRememberSiteChoices() throws {
    let environment = try makeSiteControlEnvironment(engine: StubEngine())
    let model = BrowserWindowModel(environment: environment)
    model.newTab(url: URL(string: "https://example.com/page"))
    model.enterPrivateMode()

    // The shield has nothing to offer in a private window.
    #expect(model.extensionSiteModeForActivePage("ext-demo") == nil)

    model.setExtensionSiteMode(.deny, for: "ext-demo", host: "example.com")
    #expect(model.statusMessage == "A private window does not remember site exceptions.")
    #expect(model.extensionSitePolicies(for: "ext-demo").isEmpty)
}

@Test @MainActor
func removingAnExtensionClearsItsSiteChoices() throws {
    let environment = try makeSiteControlEnvironment(engine: StubEngine())
    let model = BrowserWindowModel(environment: environment)
    let source = try makeSiteControlExtension(named: "Removable Sites")
    model.installExtension(from: source)
    let id = try #require(model.installedExtensions.first?.id)

    model.setExtensionSiteMode(.deny, for: id, host: "example.com")
    #expect(model.extensionSitePolicies(for: id).count == 1)

    model.removeExtension(id)
    #expect(model.extensionSitePolicies(for: id).isEmpty)
}

@Test @MainActor
func aFailedSiteChoiceWriteIsReported() throws {
    let environment = try makeSiteControlEnvironment(engine: StubEngine())
    let model = BrowserWindowModel(environment: environment)
    try environment.database.databaseQueue.write { db in
        try db.execute(sql: """
            CREATE TRIGGER reject_site_policy_writes BEFORE INSERT ON extension_site_policies
            BEGIN SELECT RAISE(ABORT, 'Fixture write rejected'); END
            """)
    }

    model.setExtensionSiteMode(.deny, for: "ext-demo", host: "example.com")

    #expect(model.statusMessage == "Couldn't save site choice")
    #expect(model.extensionSitePolicies(for: "ext-demo").isEmpty)
}

// MARK: - WebKit enforcement (permission state, macOS 15.4+)

@Test @MainActor
func denyingASiteMarksItDeniedAndSiblingStaysClean() async throws {
    guard #available(macOS 15.4, *) else { return }
    let environment = try makeSiteControlEnvironment()
    let model = BrowserWindowModel(environment: environment)
    let source = try makeSiteControlExtension(named: "Site Deny Fixture")
    model.installExtension(from: source)
    let id = try #require(model.installedExtensions.first?.id)
    model.setExtensionEnabled(id, isEnabled: true)
    await environment.loadEnabledExtensions()
    let host = try #require(environment.extensionHost)
    let context = try #require(host.contexts[id])
    let denied = URL(string: "https://example.test/")!
    let sibling = URL(string: "https://sibling.test/")!

    model.setExtensionSiteMode(.deny, for: id, host: "example.test")
    #expect(context.permissionStatus(for: denied) == .deniedExplicitly)
    // Sibling hosts are isolated: no spillover.
    #expect(context.permissionStatus(for: sibling) != .deniedExplicitly)

    // Regrant restores access.
    model.setExtensionSiteMode(.allow, for: id, host: "example.test")
    #expect(context.permissionStatus(for: denied) == .grantedExplicitly)

    // Back to asking clears the explicit state: no longer denied or granted.
    // (The fixture manifest still requests the host, so WebKit reports it as
    // requested — the point is our override is gone.)
    model.clearExtensionSiteMode(for: id, host: "example.test")
    let cleared = context.permissionStatus(for: denied)
    #expect(cleared != .deniedExplicitly)
    #expect(cleared != .grantedExplicitly)
}

@Test @MainActor
func storedDenyIsEnforcedOnLoadAndSurvivesReload() async throws {
    guard #available(macOS 15.4, *) else { return }
    let environment = try makeSiteControlEnvironment()
    let model = BrowserWindowModel(environment: environment)
    let source = try makeSiteControlExtension(named: "Reload Deny Fixture")
    model.installExtension(from: source)
    let id = try #require(model.installedExtensions.first?.id)
    model.setExtensionEnabled(id, isEnabled: true)

    // Stored before the context exists: the load path must enforce it.
    model.setExtensionSiteMode(.deny, for: id, host: "example.test")
    await environment.loadEnabledExtensions()
    let host = try #require(environment.extensionHost)
    let context = try #require(host.contexts[id])
    let url = URL(string: "https://example.test/")!
    #expect(context.permissionStatus(for: url) == .deniedExplicitly)

    // A second load (the "reload retains deny" leg) keeps the denial.
    await environment.loadEnabledExtensions()
    let reloaded = try #require(environment.extensionHost?.contexts[id])
    #expect(reloaded.permissionStatus(for: url) == .deniedExplicitly)
}

@Test @MainActor
func deniedHostsNeverPromptAndGrantedHostsSkipThePrompt() async throws {
    guard #available(macOS 15.4, *) else { return }
    let environment = try makeSiteControlEnvironment()
    let model = BrowserWindowModel(environment: environment)
    let source = try makeSiteControlExtension(named: "Prompt Fixture")
    model.installExtension(from: source)
    let id = try #require(model.installedExtensions.first?.id)
    model.setExtensionEnabled(id, isEnabled: true)
    await environment.loadEnabledExtensions()
    let host = try #require(environment.extensionHost)
    let context = try #require(host.contexts[id])

    model.setExtensionSiteMode(.deny, for: id, host: "example.test")
    model.setExtensionSiteMode(.allow, for: id, host: "sibling.test")

    let prompter = SiteControlPromptStub()
    prompter.cannedAnswer = false
    host.permissionPrompter = prompter

    // Denied host: answered deny without showing any card.
    var deniedResult: Set<URL>?
    host.webExtensionController(
        host.controller, promptForPermissionToAccess: [URL(string: "https://example.test/page")!],
        in: nil, for: context
    ) { urls, _ in deniedResult = urls }
    for _ in 0..<50 where deniedResult == nil { await Task.yield() }
    #expect(deniedResult?.isEmpty == true)
    #expect(prompter.requests.isEmpty)

    // Allowed host: granted without prompting.
    var allowedResult: Set<URL>?
    host.webExtensionController(
        host.controller, promptForPermissionToAccess: [URL(string: "https://sibling.test/page")!],
        in: nil, for: context
    ) { urls, _ in allowedResult = urls }
    for _ in 0..<50 where allowedResult == nil { await Task.yield() }
    #expect(allowedResult?.count == 1)
    #expect(prompter.requests.isEmpty)

    // Unknown host: the user is asked, and the answer is honoured.
    prompter.cannedAnswer = true
    var askedResult: Set<URL>?
    host.webExtensionController(
        host.controller, promptForPermissionToAccess: [URL(string: "https://third.test/page")!],
        in: nil, for: context
    ) { urls, _ in askedResult = urls }
    for _ in 0..<100 where askedResult == nil { await Task.yield() }
    #expect(askedResult?.count == 1)
    #expect(prompter.requests.count == 1)
}

@Test @MainActor
func aDenialStoredWhilePromptingWinsOverTheUsersTap() async throws {    guard #available(macOS 15.4, *) else { return }
    let environment = try makeSiteControlEnvironment()
    let model = BrowserWindowModel(environment: environment)
    let source = try makeSiteControlExtension(named: "Stale Prompt Fixture")
    model.installExtension(from: source)
    let id = try #require(model.installedExtensions.first?.id)
    model.setExtensionEnabled(id, isEnabled: true)
    await environment.loadEnabledExtensions()
    let host = try #require(environment.extensionHost)
    let context = try #require(host.contexts[id])

    let prompter = SiteControlPromptStub()
    host.permissionPrompter = prompter

    var result: Set<URL>?
    host.webExtensionController(
        host.controller, promptForPermissionToAccess: [URL(string: "https://stale.test/page")!],
        in: nil, for: context
    ) { urls, _ in result = urls }
    _ = await prompter.waitForPrompt()
    // The user opens Settings mid-prompt and denies the site; then taps Allow.
    model.setExtensionSiteMode(.deny, for: id, host: "stale.test")
    prompter.answer(true)
    for _ in 0..<100 where result == nil { await Task.yield() }
    #expect(result?.isEmpty == true)
}

@Test @MainActor
func aTabThatNavigatesAwayMidPromptCannotGrantTheSiteItLeft() async throws {
    guard #available(macOS 15.4, *) else { return }
    let environment = try makeSiteControlEnvironment()
    let model = BrowserWindowModel(environment: environment)
    let source = try makeSiteControlExtension(named: "Navigating Fixture")
    model.installExtension(from: source)
    let id = try #require(model.installedExtensions.first?.id)
    model.setExtensionEnabled(id, isEnabled: true)
    await environment.loadEnabledExtensions()
    let host = try #require(environment.extensionHost)
    let context = try #require(host.contexts[id])

    let prompter = SiteControlPromptStub()
    host.permissionPrompter = prompter

    let window = SiteControlWindow()
    let tab = SiteControlTab(url: URL(string: "https://departing.test/page"), window: window)
    window.tab = tab

    var result: Set<URL>?
    host.webExtensionController(
        host.controller, promptForPermissionToAccess: [URL(string: "https://departing.test/page")!],
        in: tab, for: context
    ) { urls, _ in result = urls }
    _ = await prompter.waitForPrompt()
    // The tab navigates elsewhere while the card is open; the user taps Allow.
    tab.pageURL = URL(string: "https://elsewhere.test/")
    prompter.answer(true)
    for _ in 0..<100 where result == nil { await Task.yield() }
    #expect(result?.isEmpty == true)
}

@Test @MainActor
func anAllowedSiteStillCannotReachLockedSpaceTabs() throws {
    let environment = try makeSiteControlEnvironment(engine: StubEngine())
    let model = BrowserWindowModel(environment: environment)
    let personal = model.session.activeSpaceID
    let secret = model.createGroup(named: "Locked fixture")
    let url = URL(string: "https://allowed.test/")!
    let tabID = model.newTab(url: url)
    model.switchGroup(personal)
    model.setSpaceLocked(secret, locked: true)

    // Even an explicit Allow for the locked tab's host does not expose it:
    // the bridge excludes locked spaces before extensions see anything.
    model.setExtensionSiteMode(.allow, for: "ext-demo", host: "allowed.test")
    #expect(!model.extensionTabSnapshots().contains { $0.id == tabID })
    #expect(!model.extensionLoadURL(URL(string: "https://allowed.test/other")!, in: tabID))
}

@Test @MainActor
func activeTabGesturesCannotBypassADeniedSite() async throws {
    guard #available(macOS 15.4, *) else { return }
    let environment = try makeSiteControlEnvironment()
    let model = BrowserWindowModel(environment: environment)
    // activeTab permission plus a denied host: the denial must win over the
    // transient gesture grant (spike S8b).
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-active-tab-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try """
        {"manifest_version":3,"name":"ActiveTab Fixture","version":"1.0",\
        "permissions":["activeTab"],"action":{"default_title":"go"}}
        """.data(using: .utf8)!.write(to: directory.appendingPathComponent("manifest.json"))
    model.installExtension(from: directory)
    let id = try #require(model.installedExtensions.first?.id)
    model.setExtensionEnabled(id, isEnabled: true)
    await environment.loadEnabledExtensions()
    let host = try #require(environment.extensionHost)
    let context = try #require(host.contexts[id])
    let url = URL(string: "https://example.test/")!

    context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission.activeTab)
    model.setExtensionSiteMode(.deny, for: id, host: "example.test")
    #expect(context.permissionStatus(for: url) == .deniedExplicitly)

    // The activeTab grant path runs through a real tab: user gesture plus
    // action. The denied host must stay denied afterwards.
    let window = SiteControlWindow()
    let tab = SiteControlTab(url: url, window: window)
    window.tab = tab
    host.controller.didOpenWindow(window)
    host.controller.didOpenTab(tab)
    host.controller.didActivateTab(tab, previousActiveTab: nil)
    context.userGesturePerformed(in: tab)
    context.performAction(for: tab)
    try? await Task.sleep(for: .milliseconds(500))
    #expect(context.permissionStatus(for: url) == .deniedExplicitly)
    #expect(context.permissionStatus(for: url, in: tab) == .deniedExplicitly)
}

@available(macOS 15.4, *)
@MainActor
final class SiteControlTab: NSObject, WKWebExtensionTab {
    var pageURL: URL?
    weak var windowObject: SiteControlWindow?
    init(url: URL?, window: SiteControlWindow) {
        self.pageURL = url
        self.windowObject = window
    }
    func url(for context: WKWebExtensionContext) -> URL? { pageURL }
    func title(for context: WKWebExtensionContext) -> String? { "fixture" }
    func isSelected(for context: WKWebExtensionContext) -> Bool { true }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { windowObject }
}

@available(macOS 15.4, *)
@MainActor
final class SiteControlWindow: NSObject, WKWebExtensionWindow {
    var tab: SiteControlTab?
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tab.map { [$0] } ?? [] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { tab }
}

/// A permission prompter that records prompts. With `cannedAnswer` set it
/// answers immediately; otherwise it parks until the test calls `answer(_`,
/// so a policy change can land between the prompt and the answer.
@MainActor
final class SiteControlPromptStub: ExtensionPermissionPrompting {
    var cannedAnswer: Bool?
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var requests: [ExtensionPermissionRequest] = []
    private var pendingAnswer: CheckedContinuation<Bool, Never>?

    func promptForExtensionPermissions(_ request: ExtensionPermissionRequest) async -> Bool {
        requests.append(request)
        for waiter in waiting { waiter.resume() }
        waiting = []
        if let cannedAnswer { return cannedAnswer }
        // Park until the test answers, so a policy change can land first.
        return await withCheckedContinuation { continuation in
            pendingAnswer = continuation
        }
    }

    func answer(_ granted: Bool) {
        pendingAnswer?.resume(returning: granted)
        pendingAnswer = nil
    }

    func waitForPrompt() async -> Bool {
        if !requests.isEmpty { return true }
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
        return true
    }
}
