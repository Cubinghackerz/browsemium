import BrowsemiumCore
import BrowsemiumData
import BrowsemiumEngine
@testable import BrowsemiumUI
import Foundation
import Testing
import WebKit

private actor FixtureFilterFetcher: UserFilterListFetching {
    private(set) var calls = 0
    func fetch(_ url: URL) async throws -> Data {
        calls += 1
        return Data("||generated.example^\n||unsupported.example^$third-party".utf8)
    }
}

@Suite @MainActor struct UserFilterListSettingsActionsTests {
    @Test func HTTPSImportThenToggleAndRemoveUsesTheSameLastGoodRepository() async throws {
        let repository = UserFilterListRepository(database: try .inMemoryProfile(), profileID: UUID())
        let manager = ContentRuleListManager()
        let fetcher = FixtureFilterFetcher()
        let controller = UserFilterListController(repository: repository, manager: manager, fetcher: fetcher)
        await controller.restore()
        await controller.importURL(URL(string: "https://generated.invalid/list?fixture-only")!, name: "Generated")
        let saved = try #require(repository.all().first)
        let identifier = try #require(manager.installedUserRuleIdentifiers.first)
        defer { WKContentRuleListStore.default()?.removeContentRuleList(forIdentifier: identifier) { _ in } }
        #expect(saved.source == .https && saved.acceptedCount == 1 && saved.skippedCount == 1)
        #expect(await fetcher.calls == 1)
        await controller.setEnabled(false, id: saved.id)
        #expect(try repository.all().first?.isEnabled == false)
        #expect(manager.installedUserRuleIdentifiers.isEmpty)
        await controller.setEnabled(true, id: saved.id)
        #expect(manager.installedUserRuleIdentifiers == [identifier])
        controller.remove(id: saved.id)
        #expect(try repository.all().isEmpty && manager.installedUserRuleIdentifiers.isEmpty)
    }

    @Test func privateActionsNeverFetchOrModifyPersistedLists() async throws {
        let repository = UserFilterListRepository(database: try .inMemoryProfile(), profileID: UUID())
        let candidate = try repository.prepare(FilterListConverter.convert(Data("||existing.example^".utf8)), name: "Existing", source: .localFile)
        let saved = try repository.commit(candidate, compiledIdentifier: candidate.compiledIdentifier)
        defer { WKContentRuleListStore.default()?.removeContentRuleList(forIdentifier: candidate.compiledIdentifier) { _ in } }
        let fetcher = FixtureFilterFetcher()
        let controller = UserFilterListController(repository: repository, manager: ContentRuleListManager(), fetcher: fetcher, allowsChanges: { false })
        await controller.restore()
        await controller.importURL(URL(string: "https://generated.invalid/list")!, name: "Private")
        await controller.importFile(URL(fileURLWithPath: "/nonexistent/generated-fixture"), name: "Private")
        await controller.setEnabled(false, id: saved.id)
        controller.remove(id: saved.id)
        #expect(await fetcher.calls == 0)
        #expect(try repository.all() == [saved])
    }

    @Test func fileImportUsesBoundedReaderAndPreservesTheName() async throws {
        let repository = UserFilterListRepository(database: try .inMemoryProfile(), profileID: UUID())
        let manager = ContentRuleListManager()
        let controller = UserFilterListController(repository: repository, manager: manager)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("||generated.example^".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await controller.restore()
        await controller.importFile(file, name: "Generated local list")
        let saved = try #require(repository.all().first)
        let identifier = try #require(manager.installedUserRuleIdentifiers.first)
        defer { WKContentRuleListStore.default()?.removeContentRuleList(forIdentifier: identifier) { _ in } }
        #expect(saved.name == "Generated local list" && saved.source == .localFile && saved.acceptedCount == 1)
    }
}
