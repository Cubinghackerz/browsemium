import BrowsemiumCore
import Foundation
import GRDB

/// Per-profile CSS tweaks, scoped to a lowercase hostname. Everything stored
/// has passed `SiteTweakValidator`; the repository re-checks so no caller can
/// bypass it.
public final class SiteTweakRepository: @unchecked Sendable {
    /// Tweaks per site. More than this is a sign of misuse, and every enabled
    /// tweak is injected into every page load on that host.
    public static let maximumPerHost = 20

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func tweaks(host: String) throws -> [SiteTweak] {
        do {
            return try database.databaseQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM site_tweaks WHERE host = ? ORDER BY created_at, id",
                    arguments: [host.lowercased()]
                ).map(Self.tweak(from:))
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func hosts() throws -> [String] {
        do {
            return try database.databaseQueue.read { db in
                try String.fetchAll(db, sql: "SELECT DISTINCT host FROM site_tweaks")
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    /// Adds a tweak after validating it. Throws a `SiteTweakProblem` for CSS
    /// that is empty, too large or could load from the network.
    @discardableResult
    public func add(host: String, name: String, css: String, now: Date = Date()) throws -> SiteTweak {
        let checkedCSS = try SiteTweakValidator.validate(css: css).get()
        let checkedName = try SiteTweakValidator.validate(name: name).get()
        let tweak = SiteTweak(host: host, name: checkedName, css: checkedCSS, createdAt: now, updatedAt: now)
        do {
            try database.databaseQueue.write { db in
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM site_tweaks WHERE host = ?", arguments: [tweak.host]) ?? 0
                guard count < Self.maximumPerHost else {
                    throw BrowsemiumError.databaseFailure("Too many tweaks for this site. Remove one first.")
                }
                try db.execute(
                    sql: """
                        INSERT INTO site_tweaks (id, host, name, css, is_enabled, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [tweak.id, tweak.host, tweak.name, tweak.css, tweak.isEnabled, tweak.createdAt, tweak.updatedAt]
                )
            }
        } catch let error as BrowsemiumError {
            throw error
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
        return tweak
    }

    public func update(id: String, name: String, css: String, now: Date = Date()) throws {
        let checkedCSS = try SiteTweakValidator.validate(css: css).get()
        let checkedName = try SiteTweakValidator.validate(name: name).get()
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: "UPDATE site_tweaks SET name = ?, css = ?, updated_at = ? WHERE id = ?",
                    arguments: [checkedName, checkedCSS, now, id]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func setEnabled(_ enabled: Bool, id: String) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(sql: "UPDATE site_tweaks SET is_enabled = ? WHERE id = ?", arguments: [enabled, id])
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func remove(id: String) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(sql: "DELETE FROM site_tweaks WHERE id = ?", arguments: [id])
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    /// The CSS injected for one host: enabled tweaks, oldest first.
    public static func css(for tweaks: [SiteTweak]) -> String {
        tweaks.filter(\.isEnabled).map(\.css).joined(separator: "\n")
    }

    private static func tweak(from row: Row) -> SiteTweak {
        SiteTweak(
            id: row["id"],
            host: row["host"],
            name: row["name"],
            css: row["css"],
            isEnabled: row["is_enabled"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }
}
