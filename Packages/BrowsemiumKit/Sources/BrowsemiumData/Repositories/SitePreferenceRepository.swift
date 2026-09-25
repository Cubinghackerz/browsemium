import BrowsemiumCore
import Foundation
import GRDB

/// Per-site preferences, such as "always open this site in Reader".
public final class SitePreferenceRepository: @unchecked Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func value(origin: String, preference: String) throws -> String? {
        do {
            return try database.databaseQueue.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT value FROM site_preferences WHERE origin = ? AND preference = ?",
                    arguments: [origin, preference]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func set(origin: String, preference: String, value: String, now: Date = Date()) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO site_preferences (origin, preference, value, updated_at)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(origin, preference) DO UPDATE SET
                            value = excluded.value,
                            updated_at = excluded.updated_at
                        """,
                    arguments: [origin, preference, value, now]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func origins(preference: String, value: String) throws -> Set<String> {
        do {
            return try database.databaseQueue.read { db in
                let rows = try String.fetchAll(
                    db,
                    sql: "SELECT origin FROM site_preferences WHERE preference = ? AND value = ?",
                    arguments: [preference, value]
                )
                return Set(rows)
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func remove(origin: String, preference: String) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM site_preferences WHERE origin = ? AND preference = ?",
                    arguments: [origin, preference]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }
}
