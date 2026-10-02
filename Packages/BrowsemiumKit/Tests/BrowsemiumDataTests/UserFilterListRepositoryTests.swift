import BrowsemiumCore
import BrowsemiumData
import Foundation
import GRDB
import Testing

@Suite struct UserFilterListRepositoryTests {
    @Test func togglesAndRemovalRejectStaleDisplayedRevisions() throws {
        let repository = UserFilterListRepository(database: try .inMemoryProfile(), profileID: UUID())
        let candidate = try repository.prepare(conversion(), name: "Fixture", source: .localFile)
        let saved = try repository.commit(candidate, compiledIdentifier: candidate.compiledIdentifier)
        try repository.setEnabled(false, id: saved.id, expectedRevision: saved.revision)
        #expect(throws: UserFilterListRepository.RepositoryError.staleCandidate) {
            try repository.setEnabled(true, id: saved.id, expectedRevision: saved.revision)
        }
        #expect(throws: UserFilterListRepository.RepositoryError.staleCandidate) {
            try repository.remove(id: saved.id, expectedRevision: saved.revision)
        }
        #expect(try repository.all().first?.isEnabled == false)
    }

    private func conversion(_ host: String = "fixture.example") throws -> FilterListConversion {
        try FilterListConverter.convert(Data("||\(host)^\n||unsupported.example^$third-party".utf8))
    }

    @Test func candidatesDoNotWriteUntilTheirExactCompilationSucceeds() throws {
        let repository = UserFilterListRepository(database: try .inMemoryProfile(), profileID: UUID())
        let candidate = try repository.prepare(conversion(), name: "Fixture", source: .localFile)
        #expect(try repository.all().isEmpty)
        #expect(throws: UserFilterListRepository.RepositoryError.notCompiled) {
            try repository.commit(candidate, compiledIdentifier: "wrong")
        }
        #expect(try repository.all().isEmpty)
        let saved = try repository.commit(candidate, compiledIdentifier: candidate.compiledIdentifier)
        #expect(saved.acceptedCount == 1 && saved.skippedCount == 1)
        #expect(saved.revision == 1 && saved.contentHash.count == 64)
        #expect(try repository.all() == [saved])
    }

    @Test func staleCompilationsCannotOverwriteUpdatesTogglesOrDeletion() throws {
        let repository = UserFilterListRepository(database: try .inMemoryProfile(), profileID: UUID())
        let first = try repository.prepare(conversion(), name: "Fixture", source: .localFile)
        let saved = try repository.commit(first, compiledIdentifier: first.compiledIdentifier)
        let slow = try repository.prepare(conversion("slow.example"), name: "Slow", source: .https, replacing: saved.id)
        let fast = try repository.prepare(conversion("fast.example"), name: "Fast", source: .https, replacing: saved.id)
        let newest = try repository.commit(fast, compiledIdentifier: fast.compiledIdentifier)
        #expect(throws: UserFilterListRepository.RepositoryError.staleCandidate) {
            try repository.commit(slow, compiledIdentifier: slow.compiledIdentifier)
        }
        #expect(try repository.all() == [newest])
        let beforeToggle = try repository.prepare(conversion(), name: "Toggle race", source: .localFile, replacing: saved.id)
        try repository.setEnabled(false, id: saved.id)
        #expect(throws: UserFilterListRepository.RepositoryError.staleCandidate) {
            try repository.commit(beforeToggle, compiledIdentifier: beforeToggle.compiledIdentifier)
        }
        #expect(try repository.all().first?.isEnabled == false)
        let beforeDelete = try repository.prepare(conversion(), name: "Delete race", source: .localFile, replacing: saved.id)
        try repository.remove(id: saved.id)
        #expect(throws: UserFilterListRepository.RepositoryError.staleCandidate) {
            try repository.commit(beforeDelete, compiledIdentifier: beforeDelete.compiledIdentifier)
        }
        #expect(try repository.all().isEmpty)
    }

    @Test func failedTransactionKeepsLastGoodAndOmitsSQLDetails() throws {
        let database = try AppDatabase.inMemoryProfile()
        let repository = UserFilterListRepository(database: database, profileID: UUID())
        let first = try repository.prepare(conversion(), name: "Fixture", source: .localFile)
        let saved = try repository.commit(first, compiledIdentifier: first.compiledIdentifier)
        let update = try repository.prepare(conversion("new.example"), name: "Update", source: .https, replacing: saved.id)
        try database.databaseQueue.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_filter_update BEFORE UPDATE ON user_filter_lists BEGIN SELECT RAISE(ABORT, 'private-sql-fixture'); END")
        }
        do {
            try repository.commit(update, compiledIdentifier: update.compiledIdentifier)
            Issue.record("Expected the generated SQL trigger to reject the update")
        } catch {
            #expect(error as? UserFilterListRepository.RepositoryError == .storageFailure)
            #expect(!error.localizedDescription.contains("private-sql-fixture"))
        }
        #expect(try repository.all() == [saved])
        try database.databaseQueue.write { db in try db.execute(sql: "DROP TRIGGER fail_filter_update") }
        let retried = try repository.commit(update, compiledIdentifier: update.compiledIdentifier)
        #expect(retried.revision == 2) // The failed transaction also rolled back its revision ledger.
    }

    @Test func profilesAndReadOnlyClientsCannotPersistEachOthersCandidates() throws {
        let databaseA = try AppDatabase.inMemoryProfile()
        let databaseB = try AppDatabase.inMemoryProfile()
        let profileA = UUID()
        let repositoryA = UserFilterListRepository(database: databaseA, profileID: profileA)
        let repositoryB = UserFilterListRepository(database: databaseB, profileID: UUID())
        let candidate = try repositoryA.prepare(conversion(), name: "Only A", source: .localFile)
        #expect(throws: UserFilterListRepository.RepositoryError.wrongProfile) {
            try repositoryB.commit(candidate, compiledIdentifier: candidate.compiledIdentifier)
        }
        let readOnly = UserFilterListRepository(database: databaseA, profileID: profileA, allowsWrites: false)
        #expect(throws: UserFilterListRepository.RepositoryError.readOnly) {
            try readOnly.prepare(conversion(), name: "Private", source: .https)
        }
        #expect(throws: UserFilterListRepository.RepositoryError.readOnly) {
            try readOnly.commit(candidate, compiledIdentifier: candidate.compiledIdentifier)
        }
        _ = try repositoryA.commit(candidate, compiledIdentifier: candidate.compiledIdentifier)
        #expect(throws: UserFilterListRepository.RepositoryError.readOnly) { try readOnly.setEnabled(false, id: candidate.id) }
        #expect(throws: UserFilterListRepository.RepositoryError.readOnly) { try readOnly.remove(id: candidate.id) }
        #expect(try repositoryA.all().count == 1 && repositoryB.all().isEmpty)
    }

    @Test func profileLimitsAndMissingIDsFailWithoutMutatingStoredLists() throws {
        let repository = UserFilterListRepository(database: try .inMemoryProfile(), profileID: UUID())
        #expect(throws: UserFilterListRepository.RepositoryError.invalidName) {
            try repository.prepare(conversion(), name: "  ", source: .localFile)
        }
        #expect(throws: UserFilterListRepository.RepositoryError.notFound) {
            try repository.prepare(conversion(), name: "Missing", source: .localFile, replacing: UUID())
        }
        for index in 0..<10 {
            let candidate = try repository.prepare(conversion(), name: "Fixture \(index)", source: .localFile)
            _ = try repository.commit(candidate, compiledIdentifier: candidate.compiledIdentifier)
        }
        let extra = try repository.prepare(conversion(), name: "Too many", source: .localFile)
        #expect(throws: UserFilterListRepository.RepositoryError.limitExceeded) {
            try repository.commit(extra, compiledIdentifier: extra.compiledIdentifier)
        }
        #expect(try repository.all().count == 10)
    }

    @Test func deletedListsCannotBeResurrectedByReplayingTheirOriginalCandidate() throws {
        let repository = UserFilterListRepository(database: try .inMemoryProfile(), profileID: UUID())
        let candidate = try repository.prepare(conversion(), name: "Deleted", source: .localFile)
        _ = try repository.commit(candidate, compiledIdentifier: candidate.compiledIdentifier)
        try repository.remove(id: candidate.id)
        #expect(throws: UserFilterListRepository.RepositoryError.staleCandidate) {
            try repository.commit(candidate, compiledIdentifier: candidate.compiledIdentifier)
        }
        #expect(try repository.all().isEmpty)
    }

    @Test func aggregateRuleLimitIncludesDisabledListsAndRetainsLastGood() throws {
        let fixture = (0..<25_001).map { "||host\($0).example^" }.joined(separator: "\n")
        let rules = try FilterListConverter.convert(Data(fixture.utf8))
        let repository = UserFilterListRepository(database: try .inMemoryProfile(), profileID: UUID())
        let first = try repository.prepare(rules, name: "First", source: .localFile)
        _ = try repository.commit(first, compiledIdentifier: first.compiledIdentifier)
        try repository.setEnabled(false, id: first.id)
        let lastGood = try repository.all()
        let second = try repository.prepare(rules, name: "Second", source: .https)
        #expect(throws: UserFilterListRepository.RepositoryError.limitExceeded) {
            try repository.commit(second, compiledIdentifier: second.compiledIdentifier)
        }
        #expect(try repository.all() == lastGood)
    }

    @Test func aggregateByteLimitRejectsOtherwiseValidCandidates() throws {
        let label = String(repeating: "a", count: 60)
        let fixture = (0..<16_000).map { "||f\($0).\(label).\(label).\(label).example^$image,script,stylesheet,font,media" }.joined(separator: "\n")
        let rules = try FilterListConverter.convert(Data(fixture.utf8))
        #expect(rules.acceptedCount * 3 < 50_000)
        #expect(rules.rulesJSON.utf8.count * 3 > 16 * 1024 * 1024)
        let repository = UserFilterListRepository(database: try .inMemoryProfile(), profileID: UUID())
        for index in 0..<2 {
            let candidate = try repository.prepare(rules, name: "First \(index)", source: .localFile)
            _ = try repository.commit(candidate, compiledIdentifier: candidate.compiledIdentifier)
        }
        let lastGood = try repository.all()
        let third = try repository.prepare(rules, name: "Too large", source: .localFile)
        #expect(throws: UserFilterListRepository.RepositoryError.limitExceeded) {
            try repository.commit(third, compiledIdentifier: third.compiledIdentifier)
        }
        #expect(try repository.all() == lastGood)
    }
}
