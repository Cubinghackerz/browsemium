import BrowsemiumCore
import BrowsemiumEngine
import Foundation
import Testing
import WebKit

@MainActor private final class SuspendedRuleCompiler: ContentRuleListCompiling {
    var continuation: CheckedContinuation<WKContentRuleList, Error>?
    func compile(identifier: String, rulesJSON: String) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

@MainActor private final class RecordingRuleController: WKUserContentController {
    var identifiers: [String] = []
    override func add(_ contentRuleList: WKContentRuleList) {
        identifiers.append(contentRuleList.identifier)
        super.add(contentRuleList)
    }
}

@Suite @MainActor struct UserContentRuleManagerTests {
    private func fixture(_ host: String = "ads.example") throws -> String {
        try FilterListConverter.convert(Data("||\(host)^".utf8)).rulesJSON
    }

    @Test(arguments: ["[not JSON]", "[{\"trigger\":{\"url-filter\":\"(\"},\"action\":{\"type\":\"block\"}}]"])
    func invalidReplacementRetainsTheLastGoodRules(invalid: String) async throws {
        let manager = ContentRuleListManager()
        let profile = UUID()
        manager.beginUserProfile(profile)
        let identifier = "BrowsemiumRuntimeFixture-" + UUID().uuidString
        let good = try await manager.compileUserRules(identifier: identifier, rulesJSON: fixture())
        defer { WKContentRuleListStore.default()?.removeContentRuleList(forIdentifier: identifier) { _ in } }
        try manager.installUserRules([good])
        await #expect(throws: ContentRuleListManager.UserRuleError.self) {
            _ = try await manager.compileUserRules(identifier: identifier + "-bad", rulesJSON: invalid)
        }
        #expect(manager.installedUserRuleIdentifiers == [identifier])
    }

    @Test func listsRespectTheGlobalBlockingToggle() async throws {
        let manager = ContentRuleListManager()
        manager.beginUserProfile(UUID())
        let identifier = "BrowsemiumRuntimeFixture-" + UUID().uuidString
        let good = try await manager.compileUserRules(identifier: identifier, rulesJSON: fixture())
        defer { WKContentRuleListStore.default()?.removeContentRuleList(forIdentifier: identifier) { _ in } }
        try manager.installUserRules([good])
        #expect(manager.compiledRuleLists.isEmpty)
        manager.activate()
        #expect(try await waitFor { manager.state == .active })
        #expect(manager.compiledRuleLists.map(\.identifier).contains(identifier))
        #expect(manager.ruleCount == ContentRuleListManager.countRules(in: ContentRuleListManager.bundledRulesJSON()!) + 1)
        let configuration = WKWebViewConfiguration()
        let recording = RecordingRuleController()
        configuration.userContentController = recording
        manager.apply(to: configuration)
        #expect(recording.identifiers == manager.compiledRuleLists.map(\.identifier))
        #expect(recording.identifiers.count == 2)
        manager.deactivate()
        #expect(manager.compiledRuleLists.isEmpty)
        #expect(manager.ruleCount == 0)
        #expect(manager.installedUserRuleIdentifiers == [identifier])
        recording.identifiers = []
        manager.apply(to: configuration)
        #expect(recording.identifiers.isEmpty)
    }

    @Test func profileSwitchRejectsLateCompilationAndClearsOldRules() async throws {
        let compiler = SuspendedRuleCompiler()
        let manager = ContentRuleListManager(compiler: compiler)
        manager.beginUserProfile(UUID())
        let identifier = "BrowsemiumRuntimeFixture-" + UUID().uuidString
        let compiled = try await WebKitContentRuleListCompiler().compile(identifier: identifier, rulesJSON: fixture())
        defer { WKContentRuleListStore.default()?.removeContentRuleList(forIdentifier: identifier) { _ in } }
        let pending = Task { try await manager.compileUserRules(identifier: identifier, rulesJSON: fixture()) }
        #expect(try await waitFor { compiler.continuation != nil })
        manager.beginUserProfile(UUID())
        compiler.continuation?.resume(returning: compiled)
        await #expect(throws: ContentRuleListManager.UserRuleError.staleCompilation) { _ = try await pending.value }
        #expect(manager.installedUserRuleIdentifiers.isEmpty)
    }

    @Test func cancellationCannotInstallALateResult() async throws {
        let compiler = SuspendedRuleCompiler()
        let manager = ContentRuleListManager(compiler: compiler)
        manager.beginUserProfile(UUID())
        let identifier = "BrowsemiumRuntimeFixture-" + UUID().uuidString
        let compiled = try await WebKitContentRuleListCompiler().compile(identifier: identifier, rulesJSON: fixture())
        defer { WKContentRuleListStore.default()?.removeContentRuleList(forIdentifier: identifier) { _ in } }
        let pending = Task { try await manager.compileUserRules(identifier: identifier, rulesJSON: fixture()) }
        #expect(try await waitFor { compiler.continuation != nil })
        pending.cancel()
        compiler.continuation?.resume(returning: compiled)
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
        #expect(manager.installedUserRuleIdentifiers.isEmpty)
    }

    @Test func compiledRulesCannotCrossManagersOrProfileGenerations() async throws {
        let manager = ContentRuleListManager()
        manager.beginUserProfile(UUID())
        let identifier = "BrowsemiumRuntimeFixture-" + UUID().uuidString
        let compiled = try await manager.compileUserRules(identifier: identifier, rulesJSON: fixture())
        defer { WKContentRuleListStore.default()?.removeContentRuleList(forIdentifier: identifier) { _ in } }
        let another = ContentRuleListManager()
        another.beginUserProfile(UUID())
        #expect(throws: ContentRuleListManager.UserRuleError.staleCompilation) { try another.installUserRules([compiled]) }
        manager.beginUserProfile(UUID())
        #expect(throws: ContentRuleListManager.UserRuleError.staleCompilation) { try manager.installUserRules([compiled]) }
        #expect(manager.installedUserRuleIdentifiers.isEmpty && another.installedUserRuleIdentifiers.isEmpty)
    }

    @Test func wrongCompilerReceiptCannotBeInstalled() async throws {
        let compiler = SuspendedRuleCompiler()
        let manager = ContentRuleListManager(compiler: compiler)
        manager.beginUserProfile(UUID())
        let identifier = "BrowsemiumRuntimeFixture-" + UUID().uuidString
        let wrong = try await WebKitContentRuleListCompiler().compile(identifier: identifier + "-wrong", rulesJSON: fixture())
        defer { WKContentRuleListStore.default()?.removeContentRuleList(forIdentifier: wrong.identifier) { _ in } }
        let pending = Task { try await manager.compileUserRules(identifier: identifier, rulesJSON: fixture()) }
        #expect(try await waitFor { compiler.continuation != nil })
        compiler.continuation?.resume(returning: wrong)
        await #expect(throws: ContentRuleListManager.UserRuleError.compilationFailed) { _ = try await pending.value }
        #expect(manager.installedUserRuleIdentifiers.isEmpty)
    }
}
