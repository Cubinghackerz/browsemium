import AppKit
import BrowsemiumCore
import BrowsemiumData
import BrowsemiumExtensions
import BrowsemiumEngineKit
import Foundation
import SwiftUI
import Testing
@testable import BrowsemiumUI

/// Offscreen renders of the extension site controls, in both appearances.
/// Generated fixtures only; evidence, not pixel baselines or native QA.
@Suite @MainActor struct ExtensionSiteControlsRenderingTests {
    private func makeModel() throws -> (BrowserWindowModel, String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("browsemium-site-render-\(UUID().uuidString)", isDirectory: true)
        let environment = BrowserEnvironment.inMemory(
            engine: StubEngine(), extensionStore: ExtensionStore(rootDirectory: root)
        )
        let model = BrowserWindowModel(environment: environment)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browsemium-site-render-ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
            {"manifest_version":3,"name":"Render Fixture","version":"1.0",\
            "host_permissions":["https://example.com/*"]}
            """.data(using: .utf8)!.write(to: directory.appendingPathComponent("manifest.json"))
        model.installExtension(from: directory)
        let id = try #require(model.installedExtensions.first?.id)
        model.setExtensionEnabled(id, isEnabled: true)
        model.setExtensionSiteMode(.deny, for: id, host: "example.com")
        model.setExtensionSiteMode(.allow, for: id, host: "other.com")
        _ = model.newTab(url: URL(string: "https://example.com/article"))
        return (model, id)
    }

    @Test func siteControlsRenderInBothAppearances() throws {
        let (model, id) = try makeModel()
        let directory = try outputDirectory()
        for dark in [false, true] {
            // Wrapped as production wraps them: the settings card surface and
            // the shield's floating surface. Bare views render on transparency,
            // which a viewer shows as black and hides light-mode text.
            let settings = ExtensionSitePolicySection(
                model: model, extensionID: id, extensionName: "Render Fixture"
            ).padding(12).frame(width: 560).background(Color.browsemiumSurface)
            try render(settings, name: "extension-site-settings", dark: dark, directory: directory)
            let shield = ExtensionSiteShieldSection(model: model)
                .padding(12).frame(width: 300, alignment: .leading)
                .browsemiumOverlaySurface()
            try render(shield, name: "extension-site-shield", dark: dark, directory: directory)
        }
    }

    private func outputDirectory() throws -> URL {
        let directory: URL
        if ProcessInfo.processInfo.environment["BROWSEMIUM_WRITE_UI_SNAPSHOTS"] == "1" {
            var root = URL(fileURLWithPath: #filePath)
            for _ in 0..<5 { root.deleteLastPathComponent() }
            directory = root.appendingPathComponent(".impeccable/review/app", isDirectory: true)
        } else {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("browsemium-site-ui-" + UUID().uuidString, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func render<V: View>(_ view: V, name: String, dark: Bool, directory: URL) throws {
        // Flat overlays, like the whole-window suite: Liquid Glass needs a
        // real window and renders black offscreen. The content is identical.
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.browsemiumFlatOverlays, true))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        #expect(size.width > 0 && size.height > 0 && size.height < 800)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }
}
