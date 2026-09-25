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
        folders: [],
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
        folders: [],
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
func savedFoldersRoundTripWithMembershipAndCollapseState() throws {
    let appDatabase = try AppDatabase.inMemoryProfile()
    let repository = BrowserSessionRepository(database: appDatabase)
    let space = BrowserSpace(name: "Personal")
    let folder = TabFolder(spaceID: space.id, name: "Research", color: "#5B8DEF", isCollapsed: true)
    let member = BrowserTab(
        spaceID: space.id,
        title: "Paper",
        lastCommittedURL: URL(string: "https://paper.example"),
        folderID: folder.id
    )
    let loose = BrowserTab(spaceID: space.id, title: "Loose")
    try repository.save(BrowserSessionState(
        spaces: [space],
        tabs: [member, loose],
        folders: [folder],
        activeSpaceID: space.id,
        activeTabID: member.id
    ))

    let restored = try #require(try repository.load())
    let restoredFolder = try #require(restored.folders.first)
    #expect(restoredFolder.id == folder.id)
    #expect(restoredFolder.name == "Research")
    #expect(restoredFolder.color == "#5B8DEF")
    #expect(restoredFolder.isCollapsed == true)
    #expect(restoredFolder.spaceID == space.id)
    #expect(restored.tabs.first { $0.id == member.id }?.folderID == folder.id)
    #expect(restored.tabs.first { $0.id == loose.id }?.folderID == nil)
}

@Test
func foldersTableAndTabFolderColumnExist() throws {
    let appDatabase = try AppDatabase.inMemoryProfile()
    let (tables, tabColumns) = try appDatabase.databaseQueue.read { database in
        let tables = try String.fetchAll(database, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        let tabColumns = try Row.fetchAll(database, sql: "PRAGMA table_info(tabs)").compactMap { $0["name"] as String? }
        return (tables, tabColumns)
    }
    #expect(tables.contains("folders"))
    #expect(tabColumns.contains("folder_id"))
}

@Test
func aFolderDroppedFromTheSessionUngroupsItsTabsOnSave() throws {
    let appDatabase = try AppDatabase.inMemoryProfile()
    let repository = BrowserSessionRepository(database: appDatabase)
    let space = BrowserSpace(name: "Personal")
    let folder = TabFolder(spaceID: space.id, name: "Temporary")
    let member = BrowserTab(spaceID: space.id, title: "Member", folderID: folder.id)
    try repository.save(BrowserSessionState(
        spaces: [space],
        tabs: [member],
        folders: [folder],
        activeSpaceID: space.id,
        activeTabID: member.id
    ))

    // The next save no longer carries the folder; the tab must survive it,
    // ungrouped — deleting a folder never deletes tabs.
    try repository.save(BrowserSessionState(
        spaces: [space],
        tabs: [member.replaced(folderID: .some(nil))],
        folders: [],
        activeSpaceID: space.id,
        activeTabID: member.id
    ))

    let restored = try #require(try repository.load())
    #expect(restored.folders.isEmpty)
    #expect(restored.tabs.first { $0.id == member.id }?.folderID == nil)
}

@Test
func tabRowsWithoutAFolderLoadAsUngrouped() throws {
    // Pre-folder databases have no folder_id value; the migration adds the
    // column as NULL and loading must treat that as "not in a folder".
    let appDatabase = try AppDatabase.inMemoryProfile()
    let repository = BrowserSessionRepository(database: appDatabase)
    let space = BrowserSpace(name: "Personal")
    let legacyTab = BrowserTab(spaceID: space.id, title: "Legacy")
    try repository.save(BrowserSessionState(
        spaces: [space],
        tabs: [legacyTab],
        folders: [],
        activeSpaceID: space.id,
        activeTabID: legacyTab.id
    ))
    try appDatabase.databaseQueue.write { database in
        try database.execute(sql: "UPDATE tabs SET folder_id = NULL")
    }

    let restored = try #require(try repository.load())
    #expect(restored.tabs.first?.folderID == nil)
    #expect(restored.folders.isEmpty)
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

@Test
func theActiveSpaceSurvivesASessionRoundTrip() throws {
    let appDatabase = try AppDatabase.inMemoryProfile()
    let repository = BrowserSessionRepository(database: appDatabase)
    let personal = BrowserSpace(name: "Personal")
    let work = BrowserSpace(name: "Work")
    let personalTab = BrowserTab(
        spaceID: personal.id,
        title: "Home",
        lastAccessedAt: Date().addingTimeInterval(-60)
    )
    let workTab = BrowserTab(
        spaceID: work.id,
        title: "Report",
        lastCommittedURL: URL(string: "https://work.example"),
        lastAccessedAt: Date()
    )
    // Active in Work, with an older Personal tab that must not win.
    try repository.save(BrowserSessionState(
        spaces: [personal, work],
        tabs: [personalTab, workTab],
        folders: [],
        activeSpaceID: work.id,
        activeTabID: workTab.id
    ))

    let restored = try #require(try repository.load())

    // Before the session_meta migration the active space was not stored at
    // all, so a restore could land on the oldest space while the active tab
    // pointed into another — the strip and the page disagreed.
    #expect(restored.activeSpaceID == work.id)
    #expect(restored.activeTabID == workTab.id)
}

@Test
func aRestoredActiveTabBelongsToTheActiveSpace() throws {
    let appDatabase = try AppDatabase.inMemoryProfile()
    let repository = BrowserSessionRepository(database: appDatabase)
    let personal = BrowserSpace(name: "Personal")
    let work = BrowserSpace(name: "Work")
    // Corrupt-ish state: the freshest tab sits in a different space than the
    // recorded active space. The restored active tab must still be in the
    // space the window will show.
    let foreignTab = BrowserTab(
        spaceID: work.id,
        title: "Elsewhere",
        lastAccessedAt: Date().addingTimeInterval(3600)
    )
    let homeTab = BrowserTab(
        spaceID: personal.id,
        title: "Home",
        lastAccessedAt: Date().addingTimeInterval(-60)
    )
    try repository.save(BrowserSessionState(
        spaces: [personal, work],
        tabs: [homeTab, foreignTab],
        folders: [],
        activeSpaceID: personal.id,
        activeTabID: homeTab.id
    ))

    let restored = try #require(try repository.load())

    #expect(restored.activeSpaceID == personal.id)
    #expect(restored.activeTabID == homeTab.id)
    #expect(restored.tabs.contains { $0.id == restored.activeTabID && $0.spaceID == restored.activeSpaceID })
}
