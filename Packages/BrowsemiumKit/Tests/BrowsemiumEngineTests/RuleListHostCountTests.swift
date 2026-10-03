import BrowsemiumCore
@testable import BrowsemiumEngine
import BrowsemiumEngineKit
import Foundation
import Observation
import Testing
import WebKit

@Suite @MainActor struct RuleListHostCountTests {
    @Test func bundledSizeCountsNamedHostsNotPathAndScriptRules() throws {
        let source = try #require(ContentRuleListManager.bundledRulesJSON())
        #expect(ContentRuleListManager.countRules(in: source) == 87)
        #expect(ContentRuleListHostnames.namedHosts(in: source)?.count == 71)
    }

    @Test func qualifiedRulesAndExceptionsNameOneHostOnly() throws {
        let converted = try FilterListConverter.convert(Data("||ads.example^$image\n||ads.example^$script\n@@||ads.example^\n||other.example^".utf8))
        #expect(converted.acceptedCount == 4)
        #expect(ContentRuleListHostnames.namedHosts(in: converted.rulesJSON) == ["ads.example", "other.example"])
    }

    @Test func unknownFiltersDoNotInventAHostCount() {
        let source = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
        #expect(ContentRuleListHostnames.namedHosts(in: source) == nil)
        #expect(ContentRuleListHostnames.namedHosts(in: "not JSON") == nil)
    }

    @Test func installedSetDeduplicatesAndRemovesDisabledAndOldProfileHosts() async throws {
        let manager = ContentRuleListManager()
        manager.beginUserProfile(UUID())
        #expect(manager.hostCounts == nil)
        manager.activate()
        defer { manager.deactivate() }
        #expect(try await waitFor { manager.state == .active })
        #expect(manager.hostCounts == .init(bundledHostCount: 71, additionalUserHostCount: 0, userListCount: 0))
        let firstID = "BrowsemiumHostFixture-" + UUID().uuidString
        let secondID = "BrowsemiumHostFixture-" + UUID().uuidString
        defer {
            for id in [firstID, secondID] { WKContentRuleListStore.default()?.removeContentRuleList(forIdentifier: id) { _ in } }
        }
        let first = try await manager.compileUserRules(identifier: firstID, rulesJSON: FilterListConverter.convert(
            Data("||doubleclick.net^\n||ads.example^$image\n||ads.example^$script".utf8)).rulesJSON)
        let second = try await manager.compileUserRules(identifier: secondID, rulesJSON: FilterListConverter.convert(
            Data("||ads.example^\n@@||other.example^".utf8)).rulesJSON)
        // Compiling alone cannot change the installed list-size receipt.
        #expect(manager.hostCounts?.additionalUserHostCount == 0)
        try manager.installUserRules([first, second])
        #expect(manager.hostCounts == .init(bundledHostCount: 71, additionalUserHostCount: 2, userListCount: 2))
        await #expect(throws: ContentRuleListManager.UserRuleError.self) {
            _ = try await manager.compileUserRules(identifier: firstID + "-bad", rulesJSON: "not JSON")
        }
        #expect(manager.hostCounts?.additionalUserHostCount == 2)
        try manager.installUserRules([first])
        #expect(manager.hostCounts?.additionalUserHostCount == 1)
        manager.beginUserProfile(UUID())
        #expect(manager.hostCounts?.additionalUserHostCount == 0)
        #expect(manager.hostCounts?.userListCount == 0)
        manager.deactivate()
        #expect(manager.hostCounts == nil)
    }

    @Test func activationAndRemovalInvalidateObservedShieldMetadata() async throws {
        let manager = ContentRuleListManager()
        manager.activate()
        defer { manager.deactivate() }
        #expect(try await waitFor { manager.state == .active })
        let changed = ObservedHostChange()
        withObservationTracking { _ = manager.hostCounts } onChange: { changed.mark() }
        manager.deactivate()
        #expect(changed.wasMarked)
    }
}

private final class ObservedHostChange: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    var wasMarked: Bool { lock.lock(); defer { lock.unlock() }; return marked }
    func mark() { lock.lock(); marked = true; lock.unlock() }
}
