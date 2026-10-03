import BrowsemiumCore
import BrowsemiumEngineKit
@testable import BrowsemiumUI
import Testing
import AppKit
import Foundation
import SwiftUI

@Suite @MainActor struct SiteShieldListSizeTests {
    private let counts = RuleListHostCounts(bundledHostCount: 71, additionalUserHostCount: 1_204, userListCount: 1)

    @Test func pauseExplanationIncludesUserListsWithoutChangingPrivateAndOffCopy() {
        let active = SiteShieldRuleSummary.pauseNote(level: .standard, isPrivate: false)
        #expect(active.contains("rule lists"))
        #expect(!active.contains("bundled"))
        #expect(SiteShieldRuleSummary.pauseNote(level: .off, isPrivate: false) == "Blocking is already off.")
        #expect(SiteShieldRuleSummary.pauseNote(level: .standard, isPrivate: true) == "A private window does not remember site exceptions.")
    }

    @Test func activeCopyNamesListSizeWithoutClaimingRequestsWereStopped() {
        let text = SiteShieldRuleSummary.text(level: .standard, state: .active(ruleCount: 999),
            counts: counts, paused: false, isPrivate: false)
        #expect(text.contains("Rule list: 71 hosts"))
        #expect(text.contains("plus 1,204 from your lists"))
        for forbidden in ["blocked", "kept out", "stopped", "protected from"] {
            #expect(!text.lowercased().contains(forbidden))
        }
        #expect(!text.contains("999"))
    }

    @Test func offAndPausedStatesNeverRenderListSize() {
        for (level, paused) in [(ProtectionLevel.off, false), (ProtectionLevel.standard, true)] {
            let text = SiteShieldRuleSummary.text(level: level, state: .active(ruleCount: 999),
                counts: counts, paused: paused, isPrivate: false)
            #expect(text.contains("Rules off on this site"))
            #expect(!text.contains(where: { $0.isNumber }))
        }
    }

    @Test func pendingFailedAndUnknownStatesDoNotInventNumbersOrClaimRulesAreOn() {
        for state in [BlockingState.inactive, .compiling, .failed("untrusted internal detail 123")] {
            let text = SiteShieldRuleSummary.text(level: .standard, state: state, counts: counts, paused: false, isPrivate: false)
            #expect(!text.contains(where: { $0.isNumber }))
            #expect(!text.contains("rules are on"))
            #expect(!text.contains("untrusted internal detail"))
        }
        let unknown = SiteShieldRuleSummary.text(level: .standard, state: .active(ruleCount: 999),
            counts: nil, paused: false, isPrivate: false)
        #expect(unknown.contains("Host count unavailable"))
        #expect(!unknown.contains(where: { $0.isNumber }))
    }

    @Test func privateOffStateStaysOffAndExplainsEphemerality() {
        let text = SiteShieldRuleSummary.text(level: .off, state: .active(ruleCount: 999),
            counts: counts, paused: false, isPrivate: true)
        #expect(text.contains("Rules off on this site"))
        #expect(text.contains("A private window does not remember site exceptions"))
        #expect(!text.contains(where: { $0.isNumber }))
    }

    @Test func windowModelUsesTheEngineReceiptAndSitePause() {
        let engine = StubEngine()
        engine.blocking = .active(ruleCount: 999)
        engine.blockingHostCounts = counts
        let model = BrowserWindowModel(environment: .inMemory(engine: engine))
        model.addressText = "https://fixture.example"
        model.submitAddress()
        #expect(model.siteShieldStatus.contains("Rule list: 71 hosts"))
        model.setBlockingPaused(true)
        #expect(model.siteShieldStatus.contains("Rules off on this site"))
        #expect(!model.siteShieldStatus.contains(where: { $0.isNumber }))
    }

    @Test func shieldRendersActiveAndPausedFixturesInBothAppearances() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("browsemium-shield-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let engine = StubEngine()
        engine.blocking = .active(ruleCount: 999)
        engine.blockingHostCounts = counts
        let model = BrowserWindowModel(environment: .inMemory(engine: engine))
        model.addressText = "https://fixture.example"
        model.submitAddress()
        for paused in [false, true] {
            model.setBlockingPaused(paused)
            for dark in [false, true] {
                let host = NSHostingView(rootView: SiteShieldPanel(model: model).environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = host.fittingSize
                #expect(abs(size.width - 300) < 1 && size.height > 0 && size.height < 650)
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                let url = directory.appendingPathComponent("shield-\(paused ? "paused" : "active")-\(dark ? "dark" : "light").png")
                try data.write(to: url)
                print("Shield fixture: \(url.path)")
            }
        }
    }
}
