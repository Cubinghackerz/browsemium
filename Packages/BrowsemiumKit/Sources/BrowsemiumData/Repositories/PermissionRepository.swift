import BrowsemiumCore
import Foundation
import GRDB

public final class PermissionRepository: @unchecked Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func decision(origin: String, kind: SitePermissionKind) throws -> SitePermissionDecision {
        do {
            let raw = try database.databaseQueue.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT decision FROM site_permissions WHERE origin = ? AND permission = ?",
                    arguments: [origin, kind.rawValue]
                )
            }
            return raw.flatMap(SitePermissionDecision.init(rawValue:)) ?? .ask
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func set(origin: String, kind: SitePermissionKind, decision: SitePermissionDecision, now: Date = Date()) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO site_permissions (origin, permission, decision, updated_at)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(origin, permission) DO UPDATE SET
                            decision = excluded.decision,
                            updated_at = excluded.updated_at
                        """,
                    arguments: [origin, kind.rawValue, decision.rawValue, now]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func all() throws -> [SitePermissionRecord] {
        do {
            return try database.databaseQueue.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM site_permissions ORDER BY origin ASC").compactMap { row in
                    guard let origin = row["origin"] as String?,
                          let permission = row["permission"] as String?,
                          let kind = SitePermissionKind(rawValue: permission),
                          let decisionRaw = row["decision"] as String?,
                          let decision = SitePermissionDecision(rawValue: decisionRaw) else {
                        return nil
                    }
                    return SitePermissionRecord(
                        origin: origin,
                        kind: kind,
                        decision: decision,
                        updatedAt: row["updated_at"] ?? Date()
                    )
                }
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func removeAll() throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(sql: "DELETE FROM site_permissions")
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func remove(origin: String, kind: SitePermissionKind) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM site_permissions WHERE origin = ? AND permission = ?",
                    arguments: [origin, kind.rawValue]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }
}
