import BrowsemiumCore
import BrowsemiumData
import BrowsemiumEngine
@testable import BrowsemiumUI
import Foundation
import Testing
import WebKit

@MainActor private final class FixtureListCompiler: ContentRuleListCompiling {
    var fails = false
    var suspends = false
    var continuation: CheckedContinuation<Void, Never>?
    var identifiers: [String] = []
    func compile(identifier: String, rulesJSON: String) async throws -> WKContentRuleList {
        identifiers.append(identifier)
        if suspends { await withCheckedContinuation { continuation = $0 } }
        if fails { throw NSError(domain: "fixture-private-source-query", code: 1) }
        return try await WebKitContentRuleListCompiler().compile(identifier: identifier, rulesJSON: rulesJSON)
    }
    func cleanUp() {
        for id in identifiers { WKContentRuleListStore.default()?.removeContentRuleList(forIdentifier: id) { _ in } }
    }
}

@Suite @MainActor struct UserFilterListControllerTests {
    @Test func successfulImportPersistsExactCompilationAndFailureKeepsLastGood() async throws {
        let repository = UserFilterListRepository(database: try .inMemoryProfile(), profileID: UUID())
        let compiler = FixtureListCompiler()
        defer { compiler.cleanUp() }
        let manager = ContentRuleListManager(compiler: compiler)
        let controller = UserFilterListController(repository: repository, manager: manager)
        await controller.restore()
        await controller.importData(Data("||first.example^\n||skip.example^$third-party".utf8), name: "Fixture", source: .localFile)
        let saved = try #require(repository.all().first)
        #expect(saved.acceptedCount == 1 && saved.skippedCount == 1)
        #expect(manager.installedUserRuleIdentifiers == compiler.identifiers)
        compiler.fails = true
        await controller.importData(Data("||second.example^".utf8), name: "Changed", source: .https, replacing: saved.id)
        #expect(try repository.all() == [saved])
        #expect(manager.installedUserRuleIdentifiers == [compiler.identifiers[0]])
        if case .failed(let message, let usesLastGood) = controller.state {
            #expect(usesLastGood && !message.contains("fixture-private-source-query"))
        } else { Issue.record("Expected a sanitized last-good failure state") }
    }

    @Test func profileSwitchDiscardsLateCompletionWithoutAnyOldProfileWrites() async throws {
        let first = UserFilterListRepository(database: try .inMemoryProfile(), profileID: UUID())
        let second = UserFilterListRepository(database: try .inMemoryProfile(), profileID: UUID())
        let compiler = FixtureListCompiler()
        defer { compiler.cleanUp() }
        let manager = ContentRuleListManager(compiler: compiler)
        let controller = UserFilterListController(repository: first, manager: manager)
        await controller.restore()
        compiler.suspends = true
        let pending = Task { await controller.importData(Data("||old.example^".utf8), name: "Old", source: .localFile) }
        #expect(try await waitFor { compiler.continuation != nil })
        controller.bind(second)
        compiler.continuation?.resume()
        await pending.value
        #expect(try await waitFor { !controller.isBusy })
        #expect(try first.all().isEmpty && second.all().isEmpty)
        #expect(manager.installedUserRuleIdentifiers.isEmpty)
    }

    @Test func privateModeAppliesExistingListsButCannotPersistEdits() async throws {
        let repository = UserFilterListRepository(database: try .inMemoryProfile(), profileID: UUID())
        let candidate = try repository.prepare(FilterListConverter.convert(Data("||existing.example^".utf8)), name: "Existing", source: .localFile)
        let saved = try repository.commit(candidate, compiledIdentifier: candidate.compiledIdentifier)
        let compiler = FixtureListCompiler()
        defer { compiler.cleanUp() }
        let manager = ContentRuleListManager(compiler: compiler)
        let controller = UserFilterListController(repository: repository, manager: manager, allowsChanges: { false })
        await controller.restore()
        #expect(manager.installedUserRuleIdentifiers == [candidate.compiledIdentifier])
        await controller.importData(Data("||new.example^".utf8), name: "Private edit", source: .localFile)
        #expect(try repository.all() == [saved])
        #expect(compiler.identifiers.count == 1)
    }

    @Test func cancelledImportDoesNotCommitAfterCompilationCompletes() async throws {
        let repository = UserFilterListRepository(database: try .inMemoryProfile(), profileID: UUID())
        let compiler = FixtureListCompiler()
        defer { compiler.cleanUp() }
        let manager = ContentRuleListManager(compiler: compiler)
        let controller = UserFilterListController(repository: repository, manager: manager)
        await controller.restore()
        compiler.suspends = true
        let pending = Task { await controller.importData(Data("||cancel.example^".utf8), name: "Cancelled", source: .localFile) }
        #expect(try await waitFor { compiler.continuation != nil })
        pending.cancel()
        compiler.continuation?.resume()
        await pending.value
        #expect(try repository.all().isEmpty && manager.installedUserRuleIdentifiers.isEmpty)
    }

    @Test func changesAreReauthorizedAfterSuspendedCompilation() async throws {
        let repository = UserFilterListRepository(database: try .inMemoryProfile(), profileID: UUID())
        let compiler = FixtureListCompiler()
        defer { compiler.cleanUp() }
        let manager = ContentRuleListManager(compiler: compiler)
        var isPrivate = false
        let controller = UserFilterListController(repository: repository, manager: manager, allowsChanges: { !isPrivate })
        await controller.restore()
        compiler.suspends = true
        let pending = Task { await controller.importData(Data("||pending.example^".utf8), name: "Pending", source: .localFile) }
        #expect(try await waitFor { compiler.continuation != nil })
        isPrivate = true
        compiler.continuation?.resume()
        await pending.value
        #expect(try repository.all().isEmpty && manager.installedUserRuleIdentifiers.isEmpty)
    }

    @Test func importRequiresSuccessfulRestorationBeforeItCanWrite() async throws {
        let repository = UserFilterListRepository(database: try .inMemoryProfile(), profileID: UUID())
        let compiler = FixtureListCompiler()
        defer { compiler.cleanUp() }
        let manager = ContentRuleListManager(compiler: compiler)
        let controller = UserFilterListController(repository: repository, manager: manager)
        await controller.importData(Data("||premature.example^".utf8), name: "Premature", source: .localFile)
        #expect(try repository.all().isEmpty && compiler.identifiers.isEmpty)
    }

    @Test func revisionChangedDuringCompilationCannotBeOverwritten() async throws {
        let repository = UserFilterListRepository(database: try .inMemoryProfile(), profileID: UUID())
        let compiler = FixtureListCompiler()
        defer { compiler.cleanUp() }
        let manager = ContentRuleListManager(compiler: compiler)
        let controller = UserFilterListController(repository: repository, manager: manager)
        await controller.restore()
        await controller.importData(Data("||initial.example^".utf8), name: "Initial", source: .localFile)
        let saved = try #require(repository.all().first)
        compiler.suspends = true
        let pending = Task { await controller.importData(Data("||pending.example^".utf8), name: "Pending", source: .localFile, replacing: saved.id) }
        #expect(try await waitFor { compiler.continuation != nil })
        try repository.setEnabled(false, id: saved.id)
        compiler.continuation?.resume()
        await pending.value
        let current = try #require(repository.all().first)
        #expect(current.name == saved.name && current.rulesJSON == saved.rulesJSON)
        #expect(!current.isEnabled && current.revision == saved.revision + 1)
        #expect(manager.installedUserRuleIdentifiers == [compiler.identifiers[0]])
    }
}
