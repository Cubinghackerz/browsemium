import BrowsemiumCore
import BrowsemiumData
import Foundation
import GRDB
import Testing

/// Builds a legacy-shaped root database on disk: the pre-profiles schema with
/// all tables in the root file. This is exactly what an upgraded 1.0.x install
/// looks like.
private func makeLegacyRoot(at directory: URL) throws -> AppDatabase {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try AppDatabase(path: directory.appendingPathComponent("browsemium.sqlite").path)
    try database.databaseQueue.write { db in
        try db.execute(
            sql: "INSERT INTO spaces (id, name, created_at) VALUES (?, ?, ?)",
            arguments: [UUID().uuidString, "Personal", Date()]
        )
        let spaceID = try String.fetchOne(db, sql: "SELECT id FROM spaces LIMIT 1")!
        try db.execute(
            sql: """
                INSERT INTO tabs (id, space_id, title, url, position, is_pinned, lifecycle, created_at, last_accessed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [UUID().uuidString, spaceID, "Example", "https://example.com", 0, false, "active", Date(), Date()]
        )
        try db.execute(
            sql: "INSERT INTO bookmarks (id, url, title, folder, sort_order, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            arguments: [UUID().uuidString, "https://example.com", "Example", "Legacy", 0, Date()]
        )
        try db.execute(
            sql: "INSERT INTO history_visits (url, title, visited_at) VALUES (?, ?, ?)",
            arguments: ["https://example.com/one", "One", Date()]
        )
        try db.execute(
            sql: "INSERT INTO history_visits (url, title, visited_at) VALUES (?, ?, ?)",
            arguments: ["https://example.com/two", "Two", Date()]
        )
        try db.execute(
            sql: "INSERT INTO saved_credentials (id, host, username, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
            arguments: [UUID().uuidString, "example.com", "user@example.com", Date(), Date()]
        )
        try db.execute(
            sql: "INSERT INTO settings (key, value) VALUES (?, ?)",
            arguments: ["homepage", "https://example.com"]
        )
    }
    return database
}

@Test
func profileSplitMovesLegacyDataIntoPersonalProfile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-split-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let root = try makeLegacyRoot(at: directory)
    let store = ProfileStore(root: root, directory: directory.appendingPathComponent("profiles"))
    try store.splitIfNeeded()

    let profiles = try store.profiles()
    #expect(profiles.count == 1)
    #expect(profiles.first?.name == ProfileStore.personalProfileName)

    let profile = try #require(profiles.first)
    let profileDatabase = try store.database(for: profile)
    let bookmarks = try profileDatabase.databaseQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmarks")
    }
    let history = try profileDatabase.databaseQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM history_visits")
    }
    let tabs = try profileDatabase.databaseQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tabs")
    }
    let credentials = try profileDatabase.databaseQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM saved_credentials")
    }
    #expect(bookmarks == 1)
    #expect(history == 2)
    #expect(tabs == 1)
    #expect(credentials == 1)

    // Legacy tables are gone from the root, and a backup survives.
    let legacyGone = try root.databaseQueue.read { db in
        try (Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'tabs')") ?? true) == false
    }
    #expect(legacyGone)
    let backupExists = FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("browsemium-pre2.sqlite").path
    )
    #expect(backupExists)
}

@Test
func profileSplitIsIdempotent() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-split-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let root = try makeLegacyRoot(at: directory)
    let store = ProfileStore(root: root, directory: directory.appendingPathComponent("profiles"))
    try store.splitIfNeeded()
    try store.splitIfNeeded()

    let profiles = try store.profiles()
    #expect(profiles.count == 1)
    let profile = try #require(profiles.first)
    let profileDatabase = try store.database(for: profile)
    let history = try profileDatabase.databaseQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM history_visits")
    }
    #expect(history == 2)
}

@Test
func profileDatabasesAreIsolated() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-profiles-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let root = try AppDatabase(path: directory.appendingPathComponent("root.sqlite").path)
    let store = ProfileStore(root: root, directory: directory.appendingPathComponent("profiles"))
    try store.splitIfNeeded()

    let work = try store.create(name: "Work")
    let personal = try #require(try store.profiles().first { $0.name == ProfileStore.personalProfileName })

    let workDatabase = try store.database(for: work)
    try workDatabase.databaseQueue.write { db in
        try db.execute(
            sql: "INSERT INTO bookmarks (id, url, title, folder, sort_order, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            arguments: [UUID().uuidString, "https://work.example", "Work", nil, 0, Date()]
        )
    }

    let personalDatabase = try store.database(for: personal)
    let personalBookmarks = try personalDatabase.databaseQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmarks")
    }
    #expect(personalBookmarks == 0)

    let workBookmarks = try workDatabase.databaseQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmarks")
    }
    #expect(workBookmarks == 1)
    #expect(work.id != personal.id)
    #expect(work.dataStoreUUID != personal.dataStoreUUID)
}

@Test
func deletingAProfileRemovesItsDatabase() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-delete-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let root = try AppDatabase(path: directory.appendingPathComponent("root.sqlite").path)
    let store = ProfileStore(root: root, directory: directory.appendingPathComponent("profiles"))
    try store.splitIfNeeded()

    let extra = try store.create(name: "Scratch")
    _ = try store.database(for: extra)
    let fileURL = store.profileDatabaseURL(id: extra.id)
    #expect(FileManager.default.fileExists(atPath: fileURL.path))

    try store.delete(id: extra.id)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    #expect(try store.profiles().count == 1)
    #expect(try store.profile(id: extra.id) == nil)
}

@Test
func freshInstallCreatesOnlyThePersonalProfile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-fresh-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let root = try AppDatabase(path: directory.appendingPathComponent("root.sqlite").path)
    let store = ProfileStore(root: root, directory: directory.appendingPathComponent("profiles"))
    try store.splitIfNeeded()

    let profiles = try store.profiles()
    #expect(profiles.count == 1)
    #expect(profiles.first?.name == ProfileStore.personalProfileName)
    let legacyGone = try root.databaseQueue.read { db in
        try (Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'bookmarks')") ?? true) == false
    }
    #expect(legacyGone)
}
