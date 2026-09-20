import BrowsemiumCore
import Foundation
import GRDB

/// Owns the profile registry and the per-profile databases.
///
/// The root database holds the `profiles` table. Each profile's data lives in
/// its own SQLite file under `profiles/`. Before profiles existed, every table
/// lived in the root database; `splitIfNeeded()` moves that legacy data into a
/// "Personal" profile exactly once, leaving `browsemium-pre2.sqlite` behind as
/// a backup.
public final class ProfileStore: @unchecked Sendable {
    public static let personalProfileName = "Personal"

    /// Tables that live in a profile database, in foreign-key-safe order.
    private static let profileTables = [
        "spaces",
        "tabs",
        "closed_tabs",
        "history_visits",
        "bookmarks",
        "downloads",
        "site_permissions",
        "site_preferences",
        "ai_provider_settings",
        "ai_conversations",
        "ai_messages",
        "saved_credentials",
        "settings"
    ]

    /// Virtual tables are rebuilt by the profile database's own triggers when
    /// the content table is copied, so they are never copied directly.
    private static let derivedTables = ["history_visits_fts"]

    private let root: AppDatabase
    private let directory: URL
    private let isMemory: Bool
    private var openDatabases: [UUID: AppDatabase] = [:]

    public init(root: AppDatabase, directory: URL, isMemory: Bool = false) {
        self.root = root
        self.directory = directory
        self.isMemory = isMemory
    }

    // MARK: - Registry

    public func profiles() throws -> [BrowserProfile] {
        do {
            return try root.databaseQueue.read { database in
                try Row.fetchAll(
                    database,
                    sql: "SELECT id, name, created_at, last_used_at, data_store_uuid FROM profiles ORDER BY created_at"
                ).compactMap(Self.profile(from:))
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func profile(id: UUID) throws -> BrowserProfile? {
        try profiles().first { $0.id == id }
    }

    public func create(name: String) throws -> BrowserProfile {
        let profile = BrowserProfile(name: name)
        try insert(profile)
        _ = try database(for: profile)
        return profile
    }

    public func rename(id: UUID, to name: String) throws {
        try root.databaseQueue.write { database in
            try database.execute(
                sql: "UPDATE profiles SET name = ? WHERE id = ?",
                arguments: [name, id.uuidString]
            )
        }
    }

    public func touch(id: UUID, at date: Date = Date()) throws {
        try root.databaseQueue.write { database in
            try database.execute(
                sql: "UPDATE profiles SET last_used_at = ? WHERE id = ?",
                arguments: [date, id.uuidString]
            )
        }
    }

    /// Removes the profile row and its database files. The caller is
    /// responsible for the profile's WebKit data store and for choosing a new
    /// active profile.
    public func delete(id: UUID) throws {
        openDatabases[id] = nil
        if !isMemory {
            for suffix in ["", "-wal", "-shm"] {
                let url = profileDatabaseURL(id: id)
                let path = url.path + suffix
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        try root.databaseQueue.write { database in
            try database.execute(sql: "DELETE FROM profiles WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: - Databases

    public func database(for profile: BrowserProfile) throws -> AppDatabase {
        if let existing = openDatabases[profile.id] {
            return existing
        }
        let database: AppDatabase
        if isMemory {
            database = try AppDatabase.inMemoryProfile()
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            database = try AppDatabase(profilePath: profileDatabaseURL(id: profile.id).path)
        }
        openDatabases[profile.id] = database
        return database
    }

    public func database(id: UUID) throws -> AppDatabase {
        guard let profile = try profile(id: id) else {
            throw BrowsemiumError.databaseFailure("Profile \(id.uuidString) does not exist.")
        }
        return try database(for: profile)
    }

    public func closeAll() {
        openDatabases.removeAll()
    }

    public func profileDatabaseURL(id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).sqlite")
    }

    // MARK: - Legacy split

    /// Ensures a "Personal" profile exists and, on first run after upgrading
    /// from a pre-profiles build, copies the legacy tables out of the root
    /// database into it. Idempotent: safe to re-run after a crash mid-split,
    /// because rows are copied with `INSERT OR REPLACE` and the legacy tables
    /// are only dropped after every row count is verified.
    public func splitIfNeeded() throws {
        let existing = try profiles()
        let personal: BrowserProfile
        if let first = existing.first {
            personal = first
        } else {
            personal = try create(name: Self.personalProfileName)
        }

        guard try hasLegacyTables() else { return }
        try backupRootIfNeeded()
        let destination = try database(for: personal)

        for table in Self.profileTables {
            let copied = try copyTable(table, into: destination)
            let source = try count(table, in: root)
            let target = try count(table, in: destination)
            guard copied == source, source == target else {
                throw BrowsemiumError.databaseFailure(
                    "Profile split verification failed for \(table): source \(source), copied \(copied), destination \(target)."
                )
            }
        }

        try dropLegacyTables()
    }

    private func insert(_ profile: BrowserProfile) throws {
        do {
            try root.databaseQueue.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO profiles (id, name, created_at, last_used_at, data_store_uuid)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        profile.id.uuidString,
                        profile.name,
                        profile.createdAt,
                        profile.lastUsedAt,
                        profile.dataStoreUUID.uuidString
                    ]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    private func hasLegacyTables() throws -> Bool {
        try root.databaseQueue.read { database in
            try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'tabs')"
            ) ?? false
        }
    }

    private func count(_ table: String, in database: AppDatabase) throws -> Int {
        try database.databaseQueue.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    private func backupRootIfNeeded() throws {
        guard !isMemory else { return }
        let backupURL = URL(fileURLWithPath: root.databaseQueue.path)
            .deletingLastPathComponent()
            .appendingPathComponent("browsemium-pre2.sqlite")
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
        try? FileManager.default.removeItem(at: backupURL)
        // VACUUM cannot run inside a transaction, so bypass GRDB's wrapper.
        try root.databaseQueue.writeWithoutTransaction { database in
            try database.execute(sql: "VACUUM INTO ?", arguments: [backupURL.path])
        }
    }

    /// Copies every row of `table` from the root database into the profile
    /// database. Returns the number of rows copied.
    private func copyTable(_ table: String, into destination: AppDatabase) throws -> Int {
        let rows = try root.databaseQueue.read { database -> [[DatabaseValue]] in
            let columns = try Row.fetchAll(database, sql: "PRAGMA table_info(\(table))")
                .compactMap { $0["name"] as String? }
            guard !columns.isEmpty else { return [] }
            return try Row.fetchAll(database, sql: "SELECT * FROM \(table)").map { row in
                columns.map { column in (row[column] as DatabaseValue?) ?? .null }
            }
        }
        guard !rows.isEmpty else { return 0 }

        let columns = try root.databaseQueue.read { database in
            try Row.fetchAll(database, sql: "PRAGMA table_info(\(table))")
                .compactMap { $0["name"] as String? }
        }
        let placeholders = columns.map { _ in "?" }.joined(separator: ", ")
        let sql = "INSERT OR REPLACE INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))"

        try destination.databaseQueue.write { database in
            for values in rows {
                try database.execute(sql: sql, arguments: StatementArguments(values))
            }
        }
        return rows.count
    }

    private func dropLegacyTables() throws {
        try root.databaseQueue.write { database in
            for table in Self.derivedTables {
                try database.execute(sql: "DROP TABLE IF EXISTS \(table)")
            }
            for table in Self.profileTables.reversed() {
                try database.execute(sql: "DROP TABLE IF EXISTS \(table)")
            }
        }
    }

    private static func profile(from row: Row) -> BrowserProfile? {
        guard let idString = row["id"] as String?,
              let id = UUID(uuidString: idString),
              let storeString = row["data_store_uuid"] as String?,
              let storeUUID = UUID(uuidString: storeString) else {
            return nil
        }
        return BrowserProfile(
            id: id,
            name: row["name"] ?? personalProfileName,
            createdAt: row["created_at"] ?? Date(),
            lastUsedAt: row["last_used_at"] ?? Date(),
            dataStoreUUID: storeUUID
        )
    }
}
