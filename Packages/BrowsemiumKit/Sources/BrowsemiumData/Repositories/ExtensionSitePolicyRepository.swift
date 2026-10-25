import BrowsemiumCore
import Foundation
import GRDB

/// Profile-local per-extension site-access choices.
///
/// Explicit rows only: the absence of a row means "ask" (WebKit's default).
/// Hosts are stored lower-cased and matched exactly; there is no wildcard or
/// suffix matching. One row per (extension, host).
public final class ExtensionSitePolicyRepository: @unchecked Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func policies(for extensionID: String) throws -> [ExtensionSitePolicy] {
        do {
            return try database.databaseQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT extension_id, host, mode FROM extension_site_policies WHERE extension_id = ? ORDER BY host",
                    arguments: [extensionID]
                ).compactMap(Self.policy(from:))
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func allPolicies() throws -> [ExtensionSitePolicy] {
        do {
            return try database.databaseQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT extension_id, host, mode FROM extension_site_policies ORDER BY extension_id, host"
                ).compactMap(Self.policy(from:))
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func mode(extensionID: String, host: String) throws -> ExtensionSiteAccessMode? {
        guard let normalized = ExtensionSitePolicy.normalizeHost(host) else { return nil }
        do {
            return try database.databaseQueue.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT mode FROM extension_site_policies WHERE extension_id = ? AND host = ?",
                    arguments: [extensionID, normalized]
                ), let raw: String = row["mode"] else { return nil }
                return ExtensionSiteAccessMode(rawValue: raw)
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    /// Stores an explicit choice. A host that cannot be normalized is refused
    /// with `BrowsemiumError.invalidInput` rather than stored raw.
    public func set(extensionID: String, host: String, mode: ExtensionSiteAccessMode) throws {
        guard let normalized = ExtensionSitePolicy.normalizeHost(host), !extensionID.isEmpty else {
            throw BrowsemiumError.invalidInput("That site address could not be read.")
        }
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO extension_site_policies (extension_id, host, mode, updated_at)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(extension_id, host) DO UPDATE SET
                            mode = excluded.mode,
                            updated_at = excluded.updated_at
                        """,
                    arguments: [extensionID, normalized, mode.rawValue, Date()]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func remove(extensionID: String, host: String) throws {
        guard let normalized = ExtensionSitePolicy.normalizeHost(host) else { return }
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM extension_site_policies WHERE extension_id = ? AND host = ?",
                    arguments: [extensionID, normalized]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    /// Drops every site choice for one extension. Used when the extension is
    /// removed, so a reinstall starts from WebKit's default.
    public func removeAll(for extensionID: String) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM extension_site_policies WHERE extension_id = ?",
                    arguments: [extensionID]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    private static func policy(from row: Row) -> ExtensionSitePolicy? {
        guard let extensionID: String = row["extension_id"],
              let host: String = row["host"],
              let raw: String = row["mode"],
              let mode = ExtensionSiteAccessMode(rawValue: raw) else { return nil }
        return ExtensionSitePolicy(extensionID: extensionID, host: host, mode: mode)
    }
}
