import BrowsemiumCore
import Foundation
import GRDB

/// Tabs put away automatically after sitting unused. Entries have the same
/// shape as recently closed tabs (`closedAt` is the archive time) so the
/// Library can list both the same way.
public final class ArchivedTabRepository: @unchecked Sendable {
    public var maximumEntries: Int

    private let database: AppDatabase

    public init(database: AppDatabase, maximumEntries: Int = 300) {
        self.database = database
        self.maximumEntries = maximumEntries
    }

    public func record(_ tab: BrowserTab, url: URL, archivedAt: Date = Date()) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO archived_tabs (tab_id, space_id, title, url, archived_at)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        tab.id.rawValue.uuidString,
                        tab.spaceID.rawValue.uuidString,
                        tab.title,
                        url.absoluteString,
                        archivedAt
                    ]
                )
                try db.execute(
                    sql: """
                        DELETE FROM archived_tabs WHERE id NOT IN (
                            SELECT id FROM archived_tabs ORDER BY archived_at DESC, id DESC LIMIT ?
                        )
                        """,
                    arguments: [maximumEntries]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func recent(limit: Int = 100) throws -> [ClosedTabEntry] {
        do {
            return try database.databaseQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM archived_tabs ORDER BY archived_at DESC, id DESC LIMIT ?",
                    arguments: [limit]
                ).compactMap { row in
                    guard let id = row["id"] as Int64?,
                          let tabIDString = row["tab_id"] as String?, let tabID = UUID(uuidString: tabIDString),
                          let spaceIDString = row["space_id"] as String?, let spaceID = UUID(uuidString: spaceIDString) else {
                        return nil
                    }
                    return ClosedTabEntry(
                        id: id,
                        tabID: TabID(rawValue: tabID),
                        spaceID: SpaceID(rawValue: spaceID),
                        title: row["title"] ?? "",
                        url: (row["url"] as String?).flatMap(URL.init(string:)),
                        closedAt: row["archived_at"] ?? Date()
                    )
                }
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    @discardableResult
    public func remove(id: Int64) throws -> Bool {
        do {
            return try database.databaseQueue.write { db in
                try db.execute(sql: "DELETE FROM archived_tabs WHERE id = ?", arguments: [id])
                return db.changesCount > 0
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func removeAll() throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(sql: "DELETE FROM archived_tabs")
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func count() throws -> Int {
        do {
            return try database.databaseQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM archived_tabs") ?? 0
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }
}
