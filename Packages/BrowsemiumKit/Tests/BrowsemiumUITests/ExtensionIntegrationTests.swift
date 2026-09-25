import BrowsemiumCore
import BrowsemiumData
import BrowsemiumExtensions
import BrowsemiumUI
import Foundation
import Testing
import BrowsemiumEngineKit

/// A throwaway extension store per test, so nothing touches the user's real
/// extension folder.
@MainActor
private func makeEnvironment(
    engine: (any BrowserEngine)? = nil
) throws -> (BrowserEnvironment, ExtensionStore) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-ui-store-\(UUID().uuidString)", isDirectory: true)
    let store = ExtensionStore(rootDirectory: root)
    let environment = BrowserEnvironment.inMemory(engine: engine, extensionStore: store)
    return (environment, store)
}

private func makeExtensionFolder(named name: String, manifestVersion: Int = 3) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-ui-ext-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let manifest = """
        {"manifest_version":\(manifestVersion),"name":"\(name)","version":"1.0"}
        """
    try manifest.data(using: .utf8)!.write(to: directory.appendingPathComponent("manifest.json"))
    return directory
}

@Test @MainActor
func installingAnExtensionRegistersItDisabled() throws {
    let (environment, _) = try makeEnvironment()
    let model = BrowserWindowModel(environment: environment)
    let source = try makeExtensionFolder(named: "Test Extension")

    model.installExtension(from: source)

    #expect(model.installedExtensions.count == 1)
    #expect(model.installedExtensions.first?.name == "Test Extension")
    #expect(model.installedExtensions.first?.isEnabled == false)
    #expect(model.statusMessage?.contains("enable it to run it") == true)
}

@Test @MainActor
func enablingAndDisablingAnExtensionFlipsItsRecord() throws {
    let (environment, _) = try makeEnvironment()
    let model = BrowserWindowModel(environment: environment)
    let source = try makeExtensionFolder(named: "Toggle Me")
    model.installExtension(from: source)
    let id = try #require(model.installedExtensions.first?.id)

    model.setExtensionEnabled(id, isEnabled: true)
    #expect(model.installedExtensions.first?.isEnabled == true)

    model.setExtensionEnabled(id, isEnabled: false)
    #expect(model.installedExtensions.first?.isEnabled == false)
}

@Test @MainActor
func removingAnExtensionDeletesFilesAndRecord() throws {
    let (environment, store) = try makeEnvironment()
    let model = BrowserWindowModel(environment: environment)
    let source = try makeExtensionFolder(named: "Removable")
    model.installExtension(from: source)
    let id = try #require(model.installedExtensions.first?.id)

    model.removeExtension(id)

    #expect(model.installedExtensions.isEmpty)
    #expect(try store.installed().isEmpty)
    #expect(try environment.extensionRepository.all().isEmpty)
}

@Test @MainActor
func extensionEnablementIsPerProfile() throws {
    let (environment, _) = try makeEnvironment()
    let model = BrowserWindowModel(environment: environment)
    let source = try makeExtensionFolder(named: "Shared Files")
    model.installExtension(from: source)
    let id = try #require(model.installedExtensions.first?.id)
    model.setExtensionEnabled(id, isEnabled: true)
    #expect(model.installedExtensions.first?.isEnabled == true)

    // A second profile sees the same files but its own enablement — disabled.
    let second = try environment.createProfile(name: "Second")
    try environment.activate(second)
    model.refreshExtensions()

    #expect(model.installedExtensions.count == 1)
    #expect(model.installedExtensions.first?.id == id)
    #expect(model.installedExtensions.first?.isEnabled == false)
}

@Test @MainActor
func extensionsAreAvailableOnThisSystem() {
    let model = BrowserWindowModel()
    if #available(macOS 15.4, *) {
        #expect(model.extensionsUnavailableReason == nil)
    } else {
        #expect(model.extensionsUnavailableReason != nil)
    }
}

@Test @MainActor
func aLoadedExtensionRoundTripsThroughWebKit() async throws {
    guard #available(macOS 15.4, *) else { return }
    let (environment, _) = try makeEnvironment()
    let model = BrowserWindowModel(environment: environment)
    let source = try makeExtensionFolder(named: "Loadable")
    model.installExtension(from: source)
    let id = try #require(model.installedExtensions.first?.id)

    model.setExtensionEnabled(id, isEnabled: true)
    await environment.loadEnabledExtensions()
    model.refreshExtensions()

    let record = try #require(model.installedExtensions.first { $0.id == id })
    #expect(record.lastError == nil)
    // WebKit reported the display name it parsed from the manifest.
    #expect(record.name == "Loadable")
    #expect(environment.extensionHost?.contexts[id] != nil)
}

@Test @MainActor
func aBrokenExtensionSurfacesItsLoadError() async throws {
    guard #available(macOS 15.4, *) else { return }
    let (environment, store) = try makeEnvironment()
    let model = BrowserWindowModel(environment: environment)
    let source = try makeExtensionFolder(named: "Broken")
    model.installExtension(from: source)
    let id = try #require(model.installedExtensions.first?.id)
    model.setExtensionEnabled(id, isEnabled: true)

    // Corrupt the manifest after install: the files exist, WebKit refuses them.
    let unpacked = try store.extensionDirectory(id: id).appendingPathComponent("unpacked/manifest.json")
    try "{ this is not json".data(using: .utf8)!.write(to: unpacked)

    await environment.loadEnabledExtensions()
    model.refreshExtensions()

    let record = try #require(model.installedExtensions.first { $0.id == id })
    #expect(record.lastError != nil)
}

@Test @MainActor
func permissionPromptsSuspendUntilAnswered() async throws {
    let model = BrowserWindowModel()
    let request = ExtensionPermissionRequest(
        extensionID: "demo",
        extensionName: "Demo",
        kind: .hostAccess(["https://*/*"])
    )

    async let answer = model.promptForExtensionPermissions(request)
    // Let the continuation land.
    try? await Task.sleep(for: .milliseconds(20))
    #expect(model.pendingExtensionPermission?.extensionID == "demo")

    model.answerExtensionPermission(granted: true)
    #expect(await answer == true)
    #expect(model.pendingExtensionPermission == nil)
}

@Test @MainActor
func aSecondPermissionPromptDeniesTheFirst() async throws {
    let model = BrowserWindowModel()
    let first = ExtensionPermissionRequest(
        extensionID: "first", extensionName: "First", kind: .apiPermissions(["storage"])
    )
    let second = ExtensionPermissionRequest(
        extensionID: "second", extensionName: "Second", kind: .apiPermissions(["alarms"])
    )

    async let firstAnswer = model.promptForExtensionPermissions(first)
    try? await Task.sleep(for: .milliseconds(20))
    async let secondAnswer = model.promptForExtensionPermissions(second)
    try? await Task.sleep(for: .milliseconds(20))

    // The first request is denied rather than left hanging forever.
    #expect(await firstAnswer == false)
    #expect(model.pendingExtensionPermission?.extensionID == "second")

    model.answerExtensionPermission(granted: true)
    #expect(await secondAnswer == true)
}

@Test @MainActor
func theBridgeSnapshotsAndDrivesTheStrip() throws {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://one.example"))
    model.newTab(url: URL(string: "https://two.example"))

    let snapshots = model.extensionTabSnapshots()
    #expect(snapshots.count == model.visibleTabs.count)
    #expect(snapshots.filter(\.isActive).count == 1)
    #expect(snapshots.map(\.index) == Array(0..<snapshots.count))

    // Activate a background tab.
    let background = try #require(snapshots.first { !$0.isActive })
    #expect(model.extensionActivateTab(background.id))
    #expect(model.session.activeTabID == background.id)

    // Load a URL into it through the bridge.
    let url = URL(string: "https://bridge.example/page")!
    #expect(model.extensionLoadURL(url, in: background.id))
    #expect(model.session.tabs.first { $0.id == background.id }?.lastCommittedURL == url)

    // Open a background tab and close it again.
    let created = try #require(model.extensionCreateTab(url: URL(string: "https://created.example"), active: false))
    #expect(model.session.activeTabID == background.id)
    #expect(model.extensionCloseTab(created))
    #expect(!model.session.tabs.contains { $0.id == created })

    // Unknown tabs are refused, not crashed on.
    #expect(model.extensionActivateTab(TabID()) == false)
    #expect(model.extensionCloseTab(TabID()) == false)
}

// MARK: - Chrome Web Store (beta)

private struct StubWebStore: ChromeWebStoreDownloading {
    let package: URL
    func downloadPackage(for extensionID: String) async throws -> URL { package }
}

@Test @MainActor
func aChromeWebStoreInstallLandsLikeACRXInstall() async throws {
    let (environment, _) = try makeEnvironment()
    // A "downloaded" package that is really a folder the store can install.
    let package = try makeExtensionFolder(named: "Web Store Extension")
    environment.chromeWebStore = StubWebStore(package: package)
    let model = BrowserWindowModel(environment: environment)

    model.installExtensionFromChromeWebStore(
        "https://chromewebstore.google.com/detail/thing/abcdefghijklmnopabcdefghijklmnop"
    )
    while model.isInstallingFromWebStore { await Task.yield() }

    #expect(model.installedExtensions.count == 1)
    #expect(model.installedExtensions.first?.name == "Web Store Extension")
    #expect(model.installedExtensions.first?.isEnabled == false)
}

@Test @MainActor
func aBadChromeWebStoreLinkShowsAnError() {
    let (environment, _) = try! makeEnvironment()
    let model = BrowserWindowModel(environment: environment)

    model.installExtensionFromChromeWebStore("not a store link")

    #expect(model.installedExtensions.isEmpty)
    #expect(model.statusMessage != nil)
    #expect(model.isInstallingFromWebStore == false)
}

// MARK: - Chrome Web Store install offer

private let webStoreID = "abcdefghijklmnopabcdefghijklmnop"
private let webStoreURL = "https://chromewebstore.google.com/detail/adblock/\(webStoreID)"

@Test @MainActor
func openingAWebStoreListingOffersAnInstall() throws {
    let engine = StubEngine()
    let (environment, _) = try makeEnvironment(engine: engine)
    let model = BrowserWindowModel(environment: environment)
    let tab = model.session.activeTabID!

    engine.emit(.committed(URL(string: webStoreURL)!), for: tab)
    engine.emit(.finished(title: "AdBlock - Chrome Web Store", url: URL(string: webStoreURL)!), for: tab)

    let offer = try #require(model.webStoreOffer)
    #expect(offer.id == webStoreID)
    #expect(offer.name == "AdBlock")
}

@Test @MainActor
func leavingTheListingClearsTheOffer() throws {
    let engine = StubEngine()
    let (environment, _) = try makeEnvironment(engine: engine)
    let model = BrowserWindowModel(environment: environment)
    let tab = model.session.activeTabID!

    engine.emit(.committed(URL(string: webStoreURL)!), for: tab)
    #expect(model.webStoreOffer != nil)

    engine.emit(.committed(URL(string: "https://example.com/article")!), for: tab)
    #expect(model.webStoreOffer == nil)
}

@Test @MainActor
func dismissingAnOfferKeepsItDismissedForThatListing() throws {
    let engine = StubEngine()
    let (environment, _) = try makeEnvironment(engine: engine)
    let model = BrowserWindowModel(environment: environment)
    let tab = model.session.activeTabID!

    engine.emit(.committed(URL(string: webStoreURL)!), for: tab)
    #expect(model.webStoreOffer != nil)

    model.dismissWebStoreOffer()
    #expect(model.webStoreOffer == nil)

    engine.emit(.committed(URL(string: "https://example.com")!), for: tab)
    engine.emit(.committed(URL(string: webStoreURL)!), for: tab)
    #expect(model.webStoreOffer == nil)
}

@Test @MainActor
func theOfferCanBeTurnedOffInSettings() throws {
    let engine = StubEngine()
    let (environment, _) = try makeEnvironment(engine: engine)
    let model = BrowserWindowModel(environment: environment)
    model.updateSettings { $0.offerWebStoreInstalls = false }
    let tab = model.session.activeTabID!

    engine.emit(.committed(URL(string: webStoreURL)!), for: tab)
    #expect(model.webStoreOffer == nil)
}

@Test @MainActor
func theOfferIsNeverShownInAPrivateWindow() throws {
    let engine = StubEngine()
    let (environment, _) = try makeEnvironment(engine: engine)
    let model = BrowserWindowModel(environment: environment)
    model.enterPrivateMode()
    let tab = model.session.activeTabID!

    engine.emit(.committed(URL(string: webStoreURL)!), for: tab)
    #expect(model.webStoreOffer == nil)
}

@Test @MainActor
func installingFromTheOfferUsesTheStoreDownloader() async throws {
    let engine = StubEngine()
    let (environment, _) = try makeEnvironment(engine: engine)
    let package = try makeExtensionFolder(named: "Offered Extension")
    environment.chromeWebStore = StubWebStore(package: package)
    let model = BrowserWindowModel(environment: environment)
    let tab = model.session.activeTabID!

    engine.emit(.committed(URL(string: webStoreURL)!), for: tab)
    #expect(model.webStoreOffer != nil)

    model.installWebStoreOffer()
    #expect(model.webStoreOffer == nil)
    while model.isInstallingFromWebStore { await Task.yield() }

    #expect(model.installedExtensions.first?.name == "Offered Extension")
}
