import BrowsemiumCore
import Foundation
import GRDB

public final class SettingsRepository: @unchecked Sendable {
    private static let key = "browser_settings"

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func load() throws -> BrowserSettings {
        do {
            let json = try database.databaseQueue.read { db in
                try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [Self.key])
            }
            guard let json, let data = json.data(using: .utf8) else {
                return BrowserSettings()
            }
            return try JSONDecoder().decode(BrowserSettings.self, from: data)
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func save(_ settings: BrowserSettings) throws {
        do {
            let data = try JSONEncoder().encode(settings)
            let json = String(decoding: data, as: UTF8.self)
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO settings (key, value) VALUES (?, ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value
                        """,
                    arguments: [Self.key, json]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func sitePreference(origin: String, preference: String) throws -> String? {
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

    public func setSitePreference(origin: String, preference: String, value: String, now: Date = Date()) throws {
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

    public func removeSitePreferences() throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(sql: "DELETE FROM site_preferences")
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }
}
