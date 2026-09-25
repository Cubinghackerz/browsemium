import BrowsemiumCore
import BrowsemiumData
import BrowsemiumExtensions
import Foundation
import Testing
import WebKit
import BrowsemiumEngineKit
@testable import BrowsemiumUI

@MainActor
private func makeActionEnvironment() throws -> BrowserEnvironment {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-action-store-\(UUID().uuidString)", isDirectory: true)
    return BrowserEnvironment.inMemory(extensionStore: ExtensionStore(rootDirectory: root))
}

private func makeExtensionFolder(name: String, manifest: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-action-ext-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try manifest.data(using: .utf8)!.write(to: directory.appendingPathComponent("manifest.json"))
    return directory
}

@MainActor
private func loadExtension(
    named name: String,
    manifest: String,
    into environment: BrowserEnvironment,
    model: BrowserWindowModel
) async throws -> String {
    let source = try makeExtensionFolder(name: name, manifest: manifest)
    model.installExtension(from: source)
    let id = try #require(model.installedExtensions.first { $0.name == name || $0.id.hasPrefix(name.lowercased()) }?.id)
    model.setExtensionEnabled(id, isEnabled: true)
    await environment.loadEnabledExtensions()
    model.refreshExtensions()
    model.refreshExtensionActions()
    return id
}

@Test @MainActor
func anExtensionWithAnActionGetsAToolbarButton() async throws {
    guard #available(macOS 15.4, *) else { return }
    let environment = try makeActionEnvironment()
    let model = BrowserWindowModel(environment: environment)

    let id = try await loadExtension(
        named: "Toolbar Demo",
        manifest: """
            {"manifest_version":3,"name":"Toolbar Demo","version":"1.0",
             "action":{"default_title":"Do the Thing"},
             "options_page":"options.html"}
            """,
        into: environment,
        model: model
    )

    let button = try #require(model.extensionActions.first { $0.id == id })
    #expect(button.label == "Do the Thing")
    #expect(button.isEnabled)
    #expect(button.presentsPopup == false)
    #expect(model.extensionActions.count == 1)
}

@Test @MainActor
func hidingAnExtensionActionRemovesItsToolbarButton() async throws {
    guard #available(macOS 15.4, *) else { return }
    let environment = try makeActionEnvironment()
    let model = BrowserWindowModel(environment: environment)

    let id = try await loadExtension(
        named: "Hidable",
        manifest: """
            {"manifest_version":3,"name":"Hidable","version":"1.0",
             "action":{"default_title":"Hide me"}}
            """,
        into: environment,
        model: model
    )
    #expect(model.isExtensionActionVisible(id))
    #expect(model.extensionActions.contains { $0.id == id })

    model.setExtensionActionVisible(id, isVisible: false)
    #expect(!model.isExtensionActionVisible(id))
    #expect(!model.extensionActions.contains { $0.id == id })
    // Hiding is a chrome preference; the extension keeps running.
    #expect(model.installedExtensions.first { $0.id == id }?.isEnabled == true)

    model.setExtensionActionVisible(id, isVisible: true)
    #expect(model.extensionActions.contains { $0.id == id })
}

@Test @MainActor
func anExtensionWithoutAnActionGetsNoButton() async throws {
    guard #available(macOS 15.4, *) else { return }
    let environment = try makeActionEnvironment()
    let model = BrowserWindowModel(environment: environment)

    _ = try await loadExtension(
        named: "No Action",
        manifest: #"{"manifest_version":3,"name":"No Action","version":"1.0"}"#,
        into: environment,
        model: model
    )

    #expect(model.extensionActions.isEmpty)
}

@Test @MainActor
func performingAnActionIsSafeWithoutAToolbar() async throws {
    guard #available(macOS 15.4, *) else { return }
    let environment = try makeActionEnvironment()
    let model = BrowserWindowModel(environment: environment)
    let id = try await loadExtension(
        named: "Clickable",
        manifest: """
            {"manifest_version":3,"name":"Clickable","version":"1.0",
             "action":{"default_title":"Click me"}}
            """,
        into: environment,
        model: model
    )

    // No toolbar exists in the test process: the action must run (or no-op
    // for extensions with no background page), never crash.
    model.performExtensionAction(id)
    model.performExtensionAction("does-not-exist")
    #expect(model.extensionActions.count == 1)
}

@Test @MainActor
func theOptionsPageOpensAsATab() async throws {
    guard #available(macOS 15.4, *) else { return }
    let environment = try makeActionEnvironment()
    let model = BrowserWindowModel(environment: environment)
    let id = try await loadExtension(
        named: "With Options",
        manifest: """
            {"manifest_version":3,"name":"With Options","version":"1.0",
             "action":{"default_title":"Options"},
             "options_page":"options.html"}
            """,
        into: environment,
        model: model
    )
    let tabsBefore = model.session.tabs.count

    model.openExtensionOptions(id)

    #expect(model.session.tabs.count == tabsBefore + 1)
    #expect(model.activeTab?.lastCommittedURL?.lastPathComponent == "options.html")
}

@Test @MainActor
func anExtensionWithoutAnOptionsPageSaysSo() async throws {
    guard #available(macOS 15.4, *) else { return }
    let environment = try makeActionEnvironment()
    let model = BrowserWindowModel(environment: environment)
    let id = try await loadExtension(
        named: "No Options",
        manifest: """
            {"manifest_version":3,"name":"No Options","version":"1.0",
             "action":{"default_title":"Hi"}}
            """,
        into: environment,
        model: model
    )

    model.openExtensionOptions(id)

    #expect(model.statusMessage == "This extension has no options page")
}

@Test @MainActor
func disablingAnExtensionRemovesItsButton() async throws {
    guard #available(macOS 15.4, *) else { return }
    let environment = try makeActionEnvironment()
    let model = BrowserWindowModel(environment: environment)
    let id = try await loadExtension(
        named: "Toggle Button",
        manifest: """
            {"manifest_version":3,"name":"Toggle Button","version":"1.0",
             "action":{"default_title":"Toggle"}}
            """,
        into: environment,
        model: model
    )
    #expect(model.extensionActions.count == 1)

    model.setExtensionEnabled(id, isEnabled: false)
    await environment.loadEnabledExtensions()
    model.refreshExtensionActions()

    #expect(model.extensionActions.isEmpty)
    #expect(environment.extensionHost?.contexts[id] == nil)
}

@Test @MainActor
func removingAnExtensionRemovesItsButtonAndContext() async throws {
    guard #available(macOS 15.4, *) else { return }
    let environment = try makeActionEnvironment()
    let model = BrowserWindowModel(environment: environment)
    let id = try await loadExtension(
        named: "Removable Button",
        manifest: """
            {"manifest_version":3,"name":"Removable Button","version":"1.0",
             "action":{"default_title":"Remove me"}}
            """,
        into: environment,
        model: model
    )
    #expect(model.extensionActions.count == 1)

    model.removeExtension(id)
    model.refreshExtensionActions()

    #expect(model.extensionActions.isEmpty)
    #expect(environment.extensionHost?.contexts[id] == nil)
}

@Test @MainActor
func theActionPresenterRoundTripsThroughRegistration() async throws {
    guard #available(macOS 15.4, *) else { return }
    let environment = try makeActionEnvironment()
    let model = BrowserWindowModel(environment: environment)
    let presenter = ExtensionActionPresenter(model: model)

    model.registerExtensionActionPresenter(presenter)
    #expect(environment.extensionHost?.actionPresenter === presenter)

    model.unregisterExtensionActionPresenter(presenter)
    #expect(environment.extensionHost?.actionPresenter == nil)
}

@Test @MainActor
func aPopupActionWithoutAButtonFailsCleanly() async throws {
    guard #available(macOS 15.4, *) else { return }
    let environment = try makeActionEnvironment()
    let model = BrowserWindowModel(environment: environment)
    let id = try await loadExtension(
        named: "Popup Demo",
        manifest: """
            {"manifest_version":3,"name":"Popup Demo","version":"1.0",
             "action":{"default_title":"Open popup","default_popup":"popup.html"}}
            """,
        into: environment,
        model: model
    )

    let button = try #require(model.extensionActions.first { $0.id == id })
    #expect(button.presentsPopup)

    // The delegate is asked to present the popup; with no toolbar on screen
    // the presenter is absent and WebKit must get an error, not a hang.
    let host = try #require(environment.extensionHost)
    let context = try #require(host.contexts[id])
    let action = try #require(host.action(for: id, tabID: model.session.activeTabID))
    var receivedError: (any Error)?
    host.webExtensionController(host.controller, presentActionPopup: action, for: context) { error in
        receivedError = error
    }
    #expect(receivedError != nil)
}
