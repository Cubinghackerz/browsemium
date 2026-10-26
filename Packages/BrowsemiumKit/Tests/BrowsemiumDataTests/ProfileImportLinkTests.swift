import BrowsemiumCore
@testable import BrowsemiumData
import Foundation
import GRDB
import Testing

private func makeStore() throws -> ProfileStore {
    let store = ProfileStore(root: try AppDatabase.inMemory(), directory: URL(fileURLWithPath: "/dev/null"), isMemory: true)
    try store.splitIfNeeded()
    return store
}

@Suite
struct ProfileImportLinkTests {
    @Test
    func aCandidateKeyNamesTheBrowserAndFolderButNeverTheHomePath() {
        let candidate = BrowserProfileCandidate(
            source: .chrome, label: "Chrome — Work",
            folder: URL(fileURLWithPath: "/Users/someone/Library/Application Support/Google/Chrome/Profile 1"),
            isReadable: true
        )
        #expect(candidate.linkKey == "chrome/Profile 1")
        #expect(!candidate.linkKey.contains("someone"))
    }

    @Test
    func aLinkedProfileIsFoundAgainByItsSource() throws {
        let store = try makeStore()
        let work = try store.create(name: "Work")
        try store.setImportSource("chrome/Profile 1", for: work.id)

        #expect(try store.linkedProfile(forImportSource: "chrome/Profile 1")?.id == work.id)
        #expect(try store.linkedProfile(forImportSource: "chrome/Default") == nil)
        #expect(try store.linkedProfile(forImportSource: "brave/Profile 1") == nil)
    }

    @Test
    func relinkingASourceMovesItInsteadOfDuplicatingIt() throws {
        let store = try makeStore()
        let first = try store.create(name: "First")
        let second = try store.create(name: "Second")
        try store.setImportSource("firefox/abc.default", for: first.id)
        try store.setImportSource("firefox/abc.default", for: second.id)

        #expect(try store.linkedProfile(forImportSource: "firefox/abc.default")?.id == second.id)
    }

    @Test
    func deletingAProfileDropsItsLink() throws {
        let store = try makeStore()
        let profile = try store.create(name: "Temp")
        try store.setImportSource("chrome/Default", for: profile.id)
        try store.delete(id: profile.id)
        #expect(try store.linkedProfile(forImportSource: "chrome/Default") == nil)
    }

    @Test
    func existingProfilesAreUnlinkedAfterTheMigration() throws {
        let root = try AppDatabase.inMemory()
        let store = ProfileStore(root: root, directory: URL(fileURLWithPath: "/dev/null"), isMemory: true)
        try store.splitIfNeeded()
        let profile = try store.create(name: "Plain")
        #expect(try store.importSource(for: profile.id) == nil)
        let columns = try root.databaseQueue.read { try $0.columns(in: "profiles").map(\.name) }
        #expect(columns.contains("import_source"))
    }
}
