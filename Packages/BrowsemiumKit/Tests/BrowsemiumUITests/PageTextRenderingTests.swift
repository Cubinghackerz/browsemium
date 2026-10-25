import AppKit
import BrowsemiumCore
import BrowsemiumData
import BrowsemiumExtensions
import BrowsemiumEngineKit
import Foundation
import SwiftUI
import Testing
@testable import BrowsemiumUI

/// Offscreen renders for the page-text index surfaces, in both appearances.
/// Behavioral assertions pin the content; the PNGs are smoke evidence, not
/// pixel baselines or native QA.
@Suite @MainActor struct PageTextRenderingTests {
    private func makeModel() throws -> (BrowserWindowModel, BrowserEnvironment) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("browsemium-topics-render-\(UUID().uuidString)", isDirectory: true)
        let environment = BrowserEnvironment.inMemory(
            engine: StubEngine(), extensionStore: ExtensionStore(rootDirectory: root))
        let model = BrowserWindowModel(environment: environment)
        model.updateSettings { $0.indexPageTextOnMac = true }
        return (model, environment)
    }

    private func seedTopics(in environment: BrowserEnvironment) throws {
        let pages = [
            ("https://a.example/swift-concurrency", "Swift concurrency explained", "swift actors tasks async"),
            ("https://b.example/swift-actors", "Swift actors guide", "swift actors state"),
            ("https://c.example/sourdough-starter", "Sourdough starter", "flour water ferment"),
            ("https://d.example/sourdough-baking", "Sourdough baking", "flour oven bread")
        ]
        for (rawURL, title, snippet) in pages {
            try environment.pageTextRepository.index(
                url: URL(string: rawURL)!, title: title, snippet: snippet)
        }
    }

    @Test func resumeTopicsRenderInBothAppearances() async throws {
        let (model, environment) = try makeModel()
        try seedTopics(in: environment)

        // Behavioral pin, path-independent: whichever clustering route runs
        // (embeddings or term overlap), topics are bounded, non-empty, and
        // drawn from the seeded pages. Exact groupings are pinned per path
        // in the Core builder tests.
        let topics = await model.resumeTopics()
        #expect(!topics.isEmpty && topics.count <= 3)
        #expect(topics.allSatisfy { !$0.label.isEmpty && $0.pages.count >= 2 })
        let seeded = Set([
            "https://a.example/swift-concurrency", "https://b.example/swift-actors",
            "https://c.example/sourdough-starter", "https://d.example/sourdough-baking"
        ])
        #expect(topics.allSatisfy { topic in
            topic.pages.allSatisfy { seeded.contains($0.url.absoluteString) }
        })

        let directory = try outputDirectory()
        for dark in [false, true] {
            let view = NewTabView(model: model)
            try await render(view, name: "newtab-topics", dark: dark,
                       width: 680, height: 800, directory: directory, settle: 4)
        }
    }

    @Test func siteShieldIndexToggleRendersInBothAppearances() async throws {
        let (model, _) = try makeModel()
        _ = model.newTab(url: URL(string: "https://shield.example/article"))

        let directory = try outputDirectory()
        for dark in [false, true] {
            let view = SiteShieldPanel(model: model)
                .frame(width: 300, alignment: .leading)
            try await render(view, name: "shield-page-index", dark: dark,
                       width: 300, height: 700, directory: directory, settle: 0)
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
                .appendingPathComponent("browsemium-topics-ui-" + UUID().uuidString, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func render<V: View>(_ view: V, name: String, dark: Bool,
                                 width: CGFloat, height: CGFloat, directory: URL,
                                 settle seconds: Double) async throws {
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.browsemiumFlatOverlays, true))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        // Topics resolve asynchronously on the main actor; suspend so the
        // executor runs them (a runloop pump would not), then capture
        // whatever settled. The behavioral assertions above pin the content —
        // this bitmap is smoke evidence.
        if seconds > 0 {
            try await Task.sleep(for: .seconds(seconds))
            host.layoutSubtreeIfNeeded()
        }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }
}
