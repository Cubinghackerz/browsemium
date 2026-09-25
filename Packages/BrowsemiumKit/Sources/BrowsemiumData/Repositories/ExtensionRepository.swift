import BrowsemiumCore
import Foundation
import GRDB

/// One installed extension's per-profile state: whether it is enabled, and
/// the last load error WebKit reported. The extension's files live in the
/// shared extension store; this row decides whether this profile loads it.
public struct ExtensionRecord: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var version: String
    public var isEnabled: Bool
    public var installedAt: Date
    public var lastError: String?

    public init(
        id: String,
        name: String,
        version: String,
        isEnabled: Bool,
        installedAt: Date,
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.isEnabled = isEnabled
        self.installedAt = installedAt
        self.lastError = lastError
    }
}

/// Per-profile extension registry. Enablement is deliberately profile-scoped:
/// the same extension can be on in one profile and off in another, matching
/// the WebKit data-store isolation the rest of the browser uses.
public final class ExtensionRepository: @unchecked Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func all() throws -> [ExtensionRecord] {
        do {
            return try database.databaseQueue.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM extensions ORDER BY name COLLATE NOCASE")
                    .map(Self.record(from:))
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func record(id: String) throws -> ExtensionRecord? {
        do {
            return try database.databaseQueue.read { db in
                try Row.fetchOne(db, sql: "SELECT * FROM extensions WHERE id = ?", arguments: [id])
                    .map(Self.record(from:))
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    /// Registers an installed extension. Reinstalling keeps the enablement
    /// the user chose and refreshes the name/version.
    @discardableResult
    public func upsert(
        id: String,
        name: String,
        version: String,
        enabledByDefault: Bool = false,
        installedAt: Date = Date()
    ) throws -> ExtensionRecord {
        do {
            try database.databaseQueue.write { db in
                let existing = try Row.fetchOne(
                    db,
                    sql: "SELECT is_enabled, installed_at FROM extensions WHERE id = ?",
                    arguments: [id]
                )
                let isEnabled: Bool = existing?["is_enabled"] ?? enabledByDefault
                let installed: Date = existing?["installed_at"] ?? installedAt
                try db.execute(
                    sql: """
                        INSERT INTO extensions (id, name, version, is_enabled, installed_at, last_error)
                        VALUES (?, ?, ?, ?, ?, NULL)
                        ON CONFLICT(id) DO UPDATE SET
                            name = excluded.name,
                            version = excluded.version
                        """,
                    arguments: [id, name, version, isEnabled, installed]
                )
            }
            return try record(id: id) ?? ExtensionRecord(
                id: id, name: name, version: version, isEnabled: enabledByDefault, installedAt: installedAt
            )
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func setEnabled(id: String, isEnabled: Bool) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: "UPDATE extensions SET is_enabled = ? WHERE id = ?",
                    arguments: [isEnabled, id]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func setLastError(id: String, message: String?) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: "UPDATE extensions SET last_error = ? WHERE id = ?",
                    arguments: [message, id]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func remove(id: String) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(sql: "DELETE FROM extensions WHERE id = ?", arguments: [id])
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    /// Drops rows whose files are gone from the store, and adds rows for
    /// extensions the store has that this profile has never seen.
    public func reconcile(with installed: [String: (name: String, version: String)]) throws {
        let known = Set(try all().map(\.id))
        for (id, metadata) in installed where !known.contains(id) {
            try upsert(id: id, name: metadata.name, version: metadata.version)
        }
    }

    private static func record(from row: Row) -> ExtensionRecord {
        ExtensionRecord(
            id: row["id"],
            name: row["name"],
            version: row["version"],
            isEnabled: row["is_enabled"],
            installedAt: row["installed_at"] ?? Date(),
            lastError: row["last_error"]
        )
    }
}
