import AppKit
import BrowsemiumCore
import BrowsemiumEngineKit
import Foundation
import SwiftUI
import Testing
@testable import BrowsemiumUI

/// Renders the whole browser window in representative states, in light and
/// dark, at the smallest and a typical size. These are the before/after
/// evidence for UI work; they are not pixel baselines.
///
/// By default the images go to a temporary folder. Set
/// `BROWSEMIUM_WRITE_UI_SNAPSHOTS=1` to write them to
/// `.impeccable/review/app/` in the repository instead.
@Suite @MainActor struct WholeWindowRenderingTests {
    private struct Scenario {
        let name: String
        let configure: @MainActor (BrowserWindowModel, DockRenderingEngine) -> Void
    }

    private static let sites: [(String, String)] = [
        ("Swift concurrency explained", "https://swift.org/blog"),
        ("Pull requests · browsemium", "https://github.com/pulls"),
        ("Inbox (3)", "https://mail.example.com/"),
        ("Design systems at scale", "https://design.example.org/post"),
        ("Docs — WebKit", "https://webkit.org/docs"),
        ("Hacker News", "https://news.example.com/"),
        ("Calendar", "https://calendar.example.com/"),
        ("A very long page title that has to be truncated somewhere sensible", "https://long.example.com/"),
        ("Notes", "https://notes.example.com/"),
        ("Dashboard", "https://app.example.com/dash")
    ]

    private static func openTabs(_ count: Int, model: BrowserWindowModel, engine: DockRenderingEngine) {
        for (title, address) in sites.prefix(count) {
            let url = URL(string: address)!
            let tab = model.newTab(url: url)
            engine.emit(.committed(url), for: tab)
            engine.emit(.finished(title: title, url: url), for: tab)
        }
    }

    /// History for the top-site tiles, and optionally closed and archived
    /// pages for the "Pick up where you left off" row.
    private static func seedStartPage(_ model: BrowserWindowModel, recents: Bool) {
        let environment = model.environment
        for (index, site) in sites.enumerated() {
            let url = URL(string: site.1)!
            for visit in 0...(sites.count - index) {
                _ = try? environment.historyRepository.record(
                    url: url, title: site.0, visitedAt: Date().addingTimeInterval(Double(-visit * 60))
                )
            }
        }
        guard recents else { return }
        let space = model.session.activeSpaceID
        for (index, site) in sites.prefix(3).enumerated() {
            let tab = BrowserTab(spaceID: space, title: site.0, lastCommittedURL: URL(string: site.1))
            try? environment.closedTabRepository.record(tab, closedAt: Date().addingTimeInterval(Double(-index * 30)))
        }
        let archived = BrowserTab(spaceID: space, title: sites[4].0, lastCommittedURL: URL(string: sites[4].1))
        try? environment.archivedTabRepository.record(
            archived, url: URL(string: sites[4].1)!, archivedAt: Date().addingTimeInterval(-200)
        )
    }

    private static let scenarios: [Scenario] = [
        Scenario(name: "new-tab") { _, _ in },
        Scenario(name: "new-tab-sites") { model, _ in seedStartPage(model, recents: false) },
        Scenario(name: "new-tab-recents") { model, _ in seedStartPage(model, recents: true) },
        Scenario(name: "ten-tabs") { model, engine in openTabs(10, model: model, engine: engine) },
        Scenario(name: "ten-tabs-selected") { model, engine in
            openTabs(10, model: model, engine: engine)
            if let third = model.visibleTabs.dropFirst(2).first?.id { model.selectTab(third) }
        },
        Scenario(name: "compact") { model, engine in
            openTabs(10, model: model, engine: engine)
            model.updateSettings { $0.chromeStyle = .compact }
        },
        Scenario(name: "sidebar") { model, engine in
            openTabs(10, model: model, engine: engine)
            model.updateSettings { $0.tabLayout = .sidebar }
        },
        Scenario(name: "sidebar-pinned-spaces") { model, engine in
            let home = model.session.activeSpaceID
            model.createGroup(named: "Work", separateData: true)
            model.createGroup(named: "Play")
            model.switchGroup(home)
            openTabs(8, model: model, engine: engine)
            for tab in model.visibleTabs.prefix(4) { model.togglePin(tab.id) }
            model.updateSettings { $0.tabLayout = .sidebar }
        },
        Scenario(name: "split") { model, engine in
            openTabs(3, model: model, engine: engine)
            if let other = model.visibleTabs.first?.id { model.openInSplitView(other) }
        },
        Scenario(name: "peek") { model, engine in
            openTabs(2, model: model, engine: engine)
            model.openPeek(url: URL(string: "https://preview.example.com/article")!)
        },
        Scenario(name: "palette") { model, engine in
            openTabs(5, model: model, engine: engine)
            model.isCommandPaletteVisible = true
        },
        Scenario(name: "private") { model, _ in model.enterPrivateMode() },
        Scenario(name: "settings") { model, _ in model.activePanel = .settings }
    ]

    private static func outputDirectory() throws -> URL {
        let directory: URL
        if ProcessInfo.processInfo.environment["BROWSEMIUM_WRITE_UI_SNAPSHOTS"] == "1" {
            // …/Packages/BrowsemiumKit/Tests/<target>/<file> → repository root.
            var root = URL(fileURLWithPath: #filePath)
            for _ in 0..<5 { root.deleteLastPathComponent() }
            directory = root.appendingPathComponent(".impeccable/review/app", isDirectory: true)
        } else {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("browsemium-window-" + UUID().uuidString, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func theWindowRendersInEveryRepresentativeState() async throws {
        let directory = try Self.outputDirectory()
        let sizes: [(String, CGFloat, CGFloat)] = [("min", 860, 560), ("typical", 1280, 800)]
        for scenario in Self.scenarios {
            for (sizeName, width, height) in sizes {
                for dark in [false, true] {
                    let engine = DockRenderingEngine()
                    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
                    scenario.configure(model, engine)
                    let host = NSHostingView(rootView: BrowsemiumAppView(model: model)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.browsemiumFlatOverlays, true))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(60))
                    host.layoutSubtreeIfNeeded()

                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    #expect(data.count > 4_000, Comment(rawValue: "\(scenario.name) rendered blank"))
                    let name = "\(scenario.name)-\(sizeName)-\(dark ? "dark" : "light").png"
                    try data.write(to: directory.appendingPathComponent(name))
                }
            }
        }
        print("Window fixtures: \(directory.path)")
    }
}
