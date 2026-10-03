import AppKit
import BrowsemiumCore
import Foundation
import SwiftUI
import Testing
@testable import BrowsemiumUI

import BrowsemiumEngineKit

/// Kept in its own process so synchronous native rendering cannot starve
/// the UI-model suite's unchanged hover/debounce deadlines.
@Suite @MainActor struct AIDockRenderingTests {
    @Test func dockRendersRepresentativeSizesAndStatesWithoutSending() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("browsemium-ai-design-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let scenarios: [(String, CGFloat, CGFloat)] = [
            ("setup-minimum", 360, 720), ("setup-default", 420, 800),
            ("conversation", 560, 800), ("error-short", 360, 560),
            ("private", 420, 800), ("streaming", 420, 800)
        ]
        for (scenario, width, height) in scenarios {
            for dark in [false, true] {
                let engine = DockRenderingEngine()
                let model = BrowserWindowModel(environment: .inMemory(engine: engine))
                if scenario == "private" { model.enterPrivateMode() }
                let tab = model.newTab(url: URL(string: "https://fixture.invalid/article")!)
                engine.emit(.committed(URL(string: "https://fixture.invalid/article")!), for: tab)
                let ai = AIDockViewModel(windowModel: model)
                ai.mode = .api
                if scenario == "conversation" || scenario == "streaming" {
                    ai.hasStoredCredential = true
                    ai.models = [.init(id: "fixture-model", name: "Fixture model", providerID: .openAI)]
                    ai.selectedModelID = "fixture-model"
                    ai.messages = [
                        .init(role: .user, content: "What should I take away from this article?"),
                        .init(role: .assistant, content: "## The short version\nA clear interface makes its next action obvious.\n\n- Group related tools.\n- Keep context deliberate.\n- Show the review before sending.")
                    ]
                    ai.draft = "Explain the trade-offs in more detail."
                    ai.isStreaming = scenario == "streaming"
                }
                if scenario == "error-short" {
                    ai.errorMessage = "Could not connect. Check your API key and try again."
                    ai.draft = "Summarize this article and compare the main arguments with the notes in my attachment."
                    ai.attachments = [.readablePage(.init(title: "Fixture article", text: "Synthetic page context"))]
                }
                let host = NSHostingView(rootView: AIDockView(model: model, ai: ai)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .frame(width: width, height: height)
                    .background(Color.browsemiumSurface))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: width, height: height)
                host.layoutSubtreeIfNeeded()
                if scenario == "conversation" || scenario == "streaming" {
                    // Let the normal attribute-only startup check finish, then
                    // supply the connected fixture without writing a real key.
                    let startupFinished = try await waitForStartup { !ai.hasStoredCredential }
                    try #require(startupFinished)
                    ai.hasStoredCredential = true
                }
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.width == width)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                let url = directory.appendingPathComponent("\(scenario)-\(dark ? "dark" : "light").png")
                try data.write(to: url)
                #expect(!ai.isReviewPresented)
                #expect(engine.capturedTabs.isEmpty)
                print("AI dock fixture: \(url.path)")
            }
        }
    }
}

@MainActor
private func waitForStartup(_ condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(20)
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(20))
    }
    return true
}
