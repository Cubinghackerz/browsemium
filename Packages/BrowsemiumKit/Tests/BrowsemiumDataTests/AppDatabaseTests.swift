import BrowsemiumCore
import BrowsemiumData
import Foundation
import GRDB
import Testing

@Test
func v1MigrationCreatesRequiredTables() throws {
    let appDatabase = try AppDatabase.inMemory()
    let names = try appDatabase.databaseQueue.read { database in
        try String.fetchAll(database, sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'view')")
    }
    let required = [
        "spaces",
        "tabs",
        "closed_tabs",
        "history_visits",
        "history_visits_fts",
        "bookmarks",
        "downloads",
        "site_permissions",
        "site_preferences",
        "ai_provider_settings",
        "ai_conversations",
        "ai_messages",
        "schema_metadata",
        "saved_credentials"
    ]
    #expect(Set(required).isSubset(of: Set(names)))
}

@Test
func foreignKeysAreEnabledAndDeclared() throws {
    let appDatabase = try AppDatabase.inMemory()
    let enabled = try appDatabase.databaseQueue.read { database in
        try Int.fetchOne(database, sql: "PRAGMA foreign_keys")
    }
    #expect(enabled == 1)

    let references = try appDatabase.databaseQueue.read { database in
        try Row.fetchAll(database, sql: "PRAGMA foreign_key_list(tabs)")
    }
    #expect(references.count == 1)
    #expect((references.first?["table"] as String?) == "spaces")
}

@Test
func privateSessionPersistenceIsRejected() throws {
    let appDatabase = try AppDatabase.inMemoryProfile()
    let repository = BrowserSessionRepository(database: appDatabase)
    let space = BrowserSpace(name: "Private")
    let tab = BrowserTab(spaceID: space.id, title: "New Tab")
    let session = BrowserSessionState(
        spaces: [space],
        tabs: [tab],
        activeSpaceID: space.id,
        activeTabID: tab.id,
        isPrivate: true
    )

    do {
        try repository.save(session)
        Issue.record("Expected private session persistence to fail")
    } catch let error as BrowsemiumError {
        #expect(error == .privateSessionPersistenceUnsupported)
    } catch {
        Issue.record(error)
    }

    let spaceCount = try appDatabase.databaseQueue.read { database in
        try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM spaces")
    }
    #expect(spaceCount == 0)
}

@Test
func savedSessionRestoresTabsAndPinnedState() throws {
    let appDatabase = try AppDatabase.inMemoryProfile()
    let repository = BrowserSessionRepository(database: appDatabase)
    let space = BrowserSpace(name: "Personal")
    let tab = BrowserTab(
        spaceID: space.id,
        title: "Example",
        lastCommittedURL: URL(string: "https://example.com"),
        isPinned: true
    )
    try repository.save(BrowserSessionState(
        spaces: [space],
        tabs: [tab],
        activeSpaceID: space.id,
        activeTabID: tab.id
    ))

    let restored = try repository.load()
    #expect(restored?.tabs.count == 1)
    #expect(restored?.tabs.first?.title == "Example")
    #expect(restored?.tabs.first?.isPinned == true)
    #expect(restored?.tabs.first?.lastCommittedURL == URL(string: "https://example.com"))
}

@Test
func savedCredentialMetadataRoundTripsWithoutPassword() throws {
    let appDatabase = try AppDatabase.inMemory()
    let repository = SavedCredentialRepository(database: appDatabase)
    let credential = try repository.save(host: "Example.COM", username: "person@example.com")

    let stored = try repository.credentials(for: "example.com")
    #expect(stored.count == 1)
    #expect(stored.first?.id == credential.id)
    #expect(stored.first?.host == "example.com")
    #expect(stored.first?.username == "person@example.com")
}

@Test
func tabsSchemaContainsNoPrivatePersistenceColumn() throws {
    let appDatabase = try AppDatabase.inMemory()
    let columns = try appDatabase.databaseQueue.read { database in
        try Row.fetchAll(database, sql: "PRAGMA table_info(tabs)").compactMap { row in
            row["name"] as String?
        }
    }
    #expect(!columns.contains { $0.localizedCaseInsensitiveContains("private") })
}
