import BrowsemiumCore
import Foundation
import GRDB

/// Per-profile "this site opens in that space" rules. Hosts are stored in the
/// normalised form `SpaceRouteHost` produces, so the repository never has to
/// guess at spelling.
public final class SpaceRouteRepository: @unchecked Sendable {
    /// A profile with hundreds of rules is a misuse, not a feature; the cap
    /// keeps matching and the Settings list cheap.
    public static let maximumRoutes = 200

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func routes() throws -> [SpaceRoute] {
        do {
            return try database.databaseQueue.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM space_routes ORDER BY created_at, id").map(Self.route(from:))
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    /// Adds a rule, or re-points the existing rule for the same host and
    /// subdomain mode at a different space. Returns the stored rule.
    @discardableResult
    public func save(
        host rawHost: String,
        includesSubdomains: Bool,
        spaceID: SpaceID,
        now: Date = Date()
    ) throws -> SpaceRoute {
        let host: String
        switch SpaceRouteHost.normalize(rawHost, includesSubdomains: includesSubdomains) {
        case .success(let normalized): host = normalized
        case .failure(let error): throw BrowsemiumError.databaseFailure(error.message)
        }
        do {
            return try database.databaseQueue.write { db in
                if let existing = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM space_routes WHERE host = ? AND includes_subdomains = ?",
                    arguments: [host, includesSubdomains]
                ) {
                    let route = Self.route(from: existing)
                    try db.execute(
                        sql: "UPDATE space_routes SET space_id = ? WHERE id = ?",
                        arguments: [spaceID.rawValue.uuidString, route.id.uuidString]
                    )
                    return SpaceRoute(
                        id: route.id, host: host, includesSubdomains: includesSubdomains,
                        spaceID: spaceID, createdAt: route.createdAt
                    )
                }
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM space_routes") ?? 0
                guard count < Self.maximumRoutes else {
                    throw BrowsemiumError.databaseFailure("Too many routing rules. Remove one first.")
                }
                let route = SpaceRoute(host: host, includesSubdomains: includesSubdomains, spaceID: spaceID, createdAt: now)
                try db.execute(
                    sql: """
                        INSERT INTO space_routes (id, host, includes_subdomains, space_id, created_at)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        route.id.uuidString, route.host, route.includesSubdomains,
                        route.spaceID.rawValue.uuidString, route.createdAt
                    ]
                )
                return route
            }
        } catch let error as BrowsemiumError {
            throw error
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func remove(id: UUID) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(sql: "DELETE FROM space_routes WHERE id = ?", arguments: [id.uuidString])
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    /// Deleting a space takes its rules with it, so a site never routes
    /// toward a space that no longer exists.
    public func removeRoutes(to spaceID: SpaceID) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM space_routes WHERE space_id = ?",
                    arguments: [spaceID.rawValue.uuidString]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    private static func route(from row: Row) -> SpaceRoute {
        let idString: String = row["id"]
        let spaceString: String = row["space_id"]
        return SpaceRoute(
            id: UUID(uuidString: idString) ?? UUID(),
            host: row["host"],
            includesSubdomains: row["includes_subdomains"],
            spaceID: SpaceID(rawValue: UUID(uuidString: spaceString) ?? UUID()),
            createdAt: row["created_at"]
        )
    }
}
