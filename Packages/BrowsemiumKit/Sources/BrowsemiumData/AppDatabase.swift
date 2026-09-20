import BrowsemiumCore
import Foundation
import GRDB

/// One SQLite database. Two shapes exist:
///
/// - the **root** database (`browsemium.sqlite`), which holds the profile
///   registry and schema metadata, and
/// - a **profile** database (`profiles/<uuid>.sqlite`), which holds every
///   per-profile table: tabs, history, bookmarks, downloads, permissions,
///   saved credentials, AI conversations, and settings.
///
/// Before profiles existed, everything lived in the root database. The
/// `ProfileStore.splitIfNeeded()` step moves that legacy data into a
/// "Personal" profile exactly once.
public final class AppDatabase: @unchecked Sendable {
    public let databaseQueue: DatabaseQueue

    public init(path: String) throws {
        databaseQueue = try DatabaseQueue(path: path, configuration: Self.configuration())
        try Self.rootMigrator.migrate(databaseQueue)
    }

    public init(profilePath: String) throws {
        databaseQueue = try DatabaseQueue(path: profilePath, configuration: Self.configuration())
        try Self.profileMigrator.migrate(databaseQueue)
    }

    public static func inMemory() throws -> AppDatabase {
        let queue = try DatabaseQueue(configuration: configuration())
        return try AppDatabase(databaseQueue: queue)
    }

    public static func inMemoryProfile() throws -> AppDatabase {
        let queue = try DatabaseQueue(configuration: configuration())
        let database = AppDatabase(unmigratedQueue: queue)
        try Self.profileMigrator.migrate(queue)
        return database
    }

    private init(databaseQueue: DatabaseQueue) throws {
        self.databaseQueue = databaseQueue
        try Self.rootMigrator.migrate(databaseQueue)
    }

    private init(unmigratedQueue: DatabaseQueue) {
        databaseQueue = unmigratedQueue
    }

    private static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA foreign_keys = ON")
            try database.execute(sql: "PRAGMA journal_mode = WAL")
        }
        return configuration
    }

    // MARK: - Root schema

    private static var rootMigrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in
            try createProfileSchema(database)
        }
        migrator.registerMigration("v2-saved-credentials") { database in
            try createSavedCredentialsTable(database)
        }
        migrator.registerMigration("v3-profiles") { database in
            try database.execute(sql: """
                CREATE TABLE profiles (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    created_at DATETIME NOT NULL,
                    last_used_at DATETIME NOT NULL,
                    data_store_uuid TEXT NOT NULL
                )
                """)
            try database.execute(
                sql: "UPDATE schema_metadata SET value = ? WHERE key = ?",
                arguments: ["3", "schema_version"]
            )
        }
        return migrator
    }

    // MARK: - Profile schema

    private static var profileMigrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("profile-v1") { database in
            try createProfileSchema(database)
        }
        migrator.registerMigration("profile-v2-saved-credentials") { database in
            try createSavedCredentialsTable(database)
        }
        return migrator
    }

    /// The complete per-profile table set. Shared by the legacy root schema
    /// (so old databases migrate without surprises) and new profile
    /// databases, so the two can never drift apart.
    private static func createProfileSchema(_ database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE spaces (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                created_at DATETIME NOT NULL
            )
            """)
        try database.execute(sql: """
            CREATE TABLE tabs (
                id TEXT PRIMARY KEY NOT NULL,
                space_id TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
                title TEXT NOT NULL,
                url TEXT,
                position INTEGER NOT NULL,
                is_pinned INTEGER NOT NULL,
                lifecycle TEXT NOT NULL,
                created_at DATETIME NOT NULL,
                last_accessed_at DATETIME NOT NULL
            )
            """)
        try database.execute(sql: """
            CREATE TABLE closed_tabs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                tab_id TEXT NOT NULL,
                space_id TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
                title TEXT NOT NULL,
                url TEXT,
                closed_at DATETIME NOT NULL
            )
            """)
        try database.execute(sql: """
            CREATE TABLE history_visits (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                tab_id TEXT REFERENCES tabs(id) ON DELETE SET NULL,
                url TEXT NOT NULL,
                title TEXT NOT NULL,
                visited_at DATETIME NOT NULL
            )
            """)
        try database.execute(sql: """
            CREATE VIRTUAL TABLE history_visits_fts USING fts5(
                title,
                url,
                content='history_visits',
                content_rowid='id'
            )
            """)
        try database.execute(sql: """
            CREATE TRIGGER history_visits_ai AFTER INSERT ON history_visits BEGIN
                INSERT INTO history_visits_fts(rowid, title, url) VALUES (new.id, new.title, new.url);
            END
            """)
        try database.execute(sql: """
            CREATE TRIGGER history_visits_ad AFTER DELETE ON history_visits BEGIN
                INSERT INTO history_visits_fts(history_visits_fts, rowid, title, url)
                VALUES ('delete', old.id, old.title, old.url);
            END
            """)
        try database.execute(sql: """
            CREATE TRIGGER history_visits_au AFTER UPDATE ON history_visits BEGIN
                INSERT INTO history_visits_fts(history_visits_fts, rowid, title, url)
                VALUES ('delete', old.id, old.title, old.url);
                INSERT INTO history_visits_fts(rowid, title, url) VALUES (new.id, new.title, new.url);
            END
            """)
        try database.execute(sql: """
            CREATE TABLE bookmarks (
                id TEXT PRIMARY KEY NOT NULL,
                url TEXT NOT NULL,
                title TEXT NOT NULL,
                folder TEXT,
                sort_order INTEGER NOT NULL,
                created_at DATETIME NOT NULL
            )
            """)
        try database.execute(sql: """
            CREATE TABLE downloads (
                id TEXT PRIMARY KEY NOT NULL,
                tab_id TEXT REFERENCES tabs(id) ON DELETE SET NULL,
                source_url TEXT NOT NULL,
                destination_path TEXT,
                suggested_filename TEXT NOT NULL,
                state TEXT NOT NULL,
                bytes_received INTEGER NOT NULL,
                total_bytes INTEGER NOT NULL,
                failure_message TEXT,
                created_at DATETIME NOT NULL,
                updated_at DATETIME NOT NULL
            )
            """)
        try database.execute(sql: """
            CREATE TABLE site_permissions (
                origin TEXT NOT NULL,
                permission TEXT NOT NULL,
                decision TEXT NOT NULL,
                updated_at DATETIME NOT NULL,
                PRIMARY KEY (origin, permission)
            )
            """)
        try database.execute(sql: """
            CREATE TABLE site_preferences (
                origin TEXT NOT NULL,
                preference TEXT NOT NULL,
                value TEXT NOT NULL,
                updated_at DATETIME NOT NULL,
                PRIMARY KEY (origin, preference)
            )
            """)
        try database.execute(sql: """
            CREATE TABLE ai_provider_settings (
                provider_id TEXT PRIMARY KEY NOT NULL,
                selected_model_id TEXT,
                is_enabled INTEGER NOT NULL DEFAULT 0,
                updated_at DATETIME NOT NULL
            )
            """)
        try database.execute(sql: """
            CREATE TABLE ai_conversations (
                id TEXT PRIMARY KEY NOT NULL,
                space_id TEXT REFERENCES spaces(id) ON DELETE SET NULL,
                title TEXT NOT NULL,
                created_at DATETIME NOT NULL,
                updated_at DATETIME NOT NULL
            )
            """)
        try database.execute(sql: """
            CREATE TABLE ai_messages (
                id TEXT PRIMARY KEY NOT NULL,
                conversation_id TEXT NOT NULL REFERENCES ai_conversations(id) ON DELETE CASCADE,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                created_at DATETIME NOT NULL
            )
            """)
        try database.execute(sql: """
            CREATE TABLE schema_metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            )
            """)
        try database.execute(sql: """
            CREATE TABLE settings (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            )
            """)
        try database.execute(
            sql: "INSERT INTO schema_metadata (key, value) VALUES (?, ?)",
            arguments: ["schema_version", "1"]
        )
    }

    private static func createSavedCredentialsTable(_ database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE saved_credentials (
                id TEXT PRIMARY KEY NOT NULL,
                host TEXT NOT NULL,
                username TEXT NOT NULL,
                created_at DATETIME NOT NULL,
                updated_at DATETIME NOT NULL,
                UNIQUE(host, username)
            )
            """)
        try database.execute(
            sql: "UPDATE schema_metadata SET value = ? WHERE key = ?",
            arguments: ["2", "schema_version"]
        )
    }
}

public final class BrowserSessionRepository: @unchecked Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func save(_ session: BrowserSessionState) throws {
        guard !session.isPrivate else {
            throw BrowsemiumError.privateSessionPersistenceUnsupported
        }

        do {
            try database.databaseQueue.write { database in
                for space in session.spaces {
                        try database.execute(
                            sql: """
                                INSERT INTO spaces (id, name, created_at) VALUES (?, ?, ?)
                                ON CONFLICT(id) DO UPDATE SET name = excluded.name
                                """,
                            arguments: [space.id.rawValue.uuidString, space.name, space.createdAt]
                        )
                    }
                    try database.execute(sql: "DELETE FROM tabs")
                    for tab in session.tabs {
                        try database.execute(
                            sql: """
                                INSERT INTO tabs (
                                    id, space_id, title, url, position, is_pinned, lifecycle, created_at, last_accessed_at
                                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                                ON CONFLICT(id) DO UPDATE SET
                                    space_id = excluded.space_id,
                                    title = excluded.title,
                                    url = excluded.url,
                                    position = excluded.position,
                                    is_pinned = excluded.is_pinned,
                                    lifecycle = excluded.lifecycle,
                                    last_accessed_at = excluded.last_accessed_at
                                """,
                            arguments: [
                                tab.id.rawValue.uuidString,
                                tab.spaceID.rawValue.uuidString,
                                tab.title,
                                tab.lastCommittedURL?.absoluteString,
                                tab.position,
                                tab.isPinned,
                                tab.lifecycle.rawValue,
                                tab.createdAt,
                                tab.lastAccessedAt
                            ]
                        )
                }
            }
        } catch let error as BrowsemiumError {
            throw error
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func load() throws -> BrowserSessionState? {
        do {
            return try database.databaseQueue.read { database in
                let spaces: [BrowserSpace] = try Row.fetchAll(
                    database,
                    sql: "SELECT id, name, created_at FROM spaces ORDER BY created_at"
                ).compactMap { row in
                    guard let idString = row["id"] as String?, let id = UUID(uuidString: idString) else { return nil }
                    return BrowserSpace(
                        id: SpaceID(rawValue: id),
                        name: row["name"] ?? "Personal",
                        createdAt: row["created_at"] ?? Date()
                    )
                }
                guard let activeSpace = spaces.first else { return nil }

                let tabs: [BrowserTab] = try Row.fetchAll(
                    database,
                    sql: "SELECT * FROM tabs ORDER BY position, created_at"
                ).compactMap { row in
                    guard let idString = row["id"] as String?,
                          let id = UUID(uuidString: idString),
                          let spaceString = row["space_id"] as String?,
                          let spaceID = UUID(uuidString: spaceString) else {
                        return nil
                    }
                    let rawURL = row["url"] as String?
                    let lifecycleRaw = row["lifecycle"] as String? ?? TabLifecycle.metadataOnly.rawValue
                    return BrowserTab(
                        id: TabID(rawValue: id),
                        spaceID: SpaceID(rawValue: spaceID),
                        title: row["title"] ?? "New Tab",
                        lastCommittedURL: rawURL.flatMap(URL.init(string:)),
                        position: row["position"] ?? 0,
                        isPinned: row["is_pinned"] ?? false,
                        lifecycle: TabLifecycle(rawValue: lifecycleRaw) == .crashed ? .metadataOnly : .hibernated,
                        createdAt: row["created_at"] ?? Date(),
                        lastAccessedAt: row["last_accessed_at"] ?? Date()
                    )
                }
                guard !tabs.isEmpty else { return nil }
                let activeTab = tabs.max { $0.lastAccessedAt < $1.lastAccessedAt }?.id
                return BrowserSessionState(
                    spaces: spaces,
                    tabs: tabs,
                    activeSpaceID: activeSpace.id,
                    activeTabID: activeTab
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }
}
