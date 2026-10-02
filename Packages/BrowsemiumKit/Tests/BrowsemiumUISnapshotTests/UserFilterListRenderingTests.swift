import AppKit
import BrowsemiumCore
import BrowsemiumData
import BrowsemiumEngine
@testable import BrowsemiumUI
import SwiftUI
import Testing
import WebKit

/// Generated fixtures and rendering smoke checks, not native interaction QA or
/// pixel-diff baselines. No source browser or remote filter source is accessed.
@Suite @MainActor struct UserFilterListRenderingTests {
    @Test func importSheetRendersIdleBusyAndFailureInBothAppearances() throws {
        let directory = try outputDirectory()
        for dark in [false, true] {
            for (name, source, state) in [
                ("file", UserFilterList.Source.localFile, UserFilterListController.State.idle),
                ("busy", .https, .compiling),
                ("failed", .https, .failed("The source returned HTTP 503. Choose another address or try again later.", usesLastGood: true))
            ] {
                let view = UserFilterListImportSheet(name: "Generated list", source: source,
                    destinationName: "Fixture profile", state: state, onCancel: {}, onImport: { _, _, _ in })
                try render(view, name: "import-" + name, dark: dark, width: 440, directory: directory)
            }
        }
    }

    @Test func settingsCardRendersGeneratedCountsInBothAppearances() async throws {
        let directory = try outputDirectory()
        let repository = UserFilterListRepository(database: try .inMemoryProfile(), profileID: UUID())
        let manager = ContentRuleListManager()
        let controller = UserFilterListController(repository: repository, manager: manager)
        await controller.restore()
        await controller.importData(Data("||fixture.example^\n||unsupported.example^$third-party".utf8),
                                    name: "Generated list", source: .localFile)
        let identifier = try #require(manager.installedUserRuleIdentifiers.first)
        defer { WKContentRuleListStore.default()?.removeContentRuleList(forIdentifier: identifier) { _ in } }
        #expect(controller.lists.first?.acceptedCount == 1 && controller.lists.first?.skippedCount == 1)
        let model = BrowserWindowModel(environment: .inMemory())
        for dark in [false, true] {
            let view = UserFilterListSettingsView(model: model, controller: controller, settings: BrowserSettings())
                .padding(20).frame(width: 600).background(Color.browsemiumSurface)
            try render(view, name: "settings", dark: dark, width: 600, directory: directory)
        }
    }

    private func outputDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("browsemium-filter-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func render<V: View>(_ view: V, name: String, dark: Bool, width: CGFloat, directory: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        #expect(abs(size.width - width) < 1 && size.height > 0 && size.height < 650)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
        try data.write(to: url)
        print("Filter UI fixture: \(url.path)")
    }
}
