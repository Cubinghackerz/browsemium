import BrowsemiumCore
import Foundation
import GRDB

public struct ClosedTabEntry: Hashable, Codable, Sendable, Identifiable {
    public let id: Int64
    public let tabID: TabID
    public let spaceID: SpaceID
    public let title: String
    public let url: URL?
    public let closedAt: Date
}

public final class ClosedTabRepository: @unchecked Sendable {
    public var maximumEntries: Int

    private let database: AppDatabase

    public init(database: AppDatabase, maximumEntries: Int = 50) {
        self.database = database
        self.maximumEntries = maximumEntries
    }

    public func record(_ tab: BrowserTab, closedAt: Date = Date()) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO closed_tabs (tab_id, space_id, title, url, closed_at)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        tab.id.rawValue.uuidString,
                        tab.spaceID.rawValue.uuidString,
                        tab.title,
                        tab.lastCommittedURL?.absoluteString,
                        closedAt
                    ]
                )
                try db.execute(
                    sql: """
                        DELETE FROM closed_tabs WHERE id NOT IN (
                            SELECT id FROM closed_tabs ORDER BY closed_at DESC LIMIT ?
                        )
                        """,
                    arguments: [maximumEntries]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func mostRecent() throws -> ClosedTabEntry? {
        try recent(limit: 1).first
    }

    public func recent(limit: Int = 20) throws -> [ClosedTabEntry] {
        do {
            return try database.databaseQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM closed_tabs ORDER BY closed_at DESC LIMIT ?",
                    arguments: [limit]
                ).compactMap { row in
                    guard let id = row["id"] as Int64?,
                          let tabIDString = row["tab_id"] as String?,
                          let tabID = UUID(uuidString: tabIDString),
                          let spaceIDString = row["space_id"] as String?,
                          let spaceID = UUID(uuidString: spaceIDString) else {
                        return nil
                    }
                    let url = (row["url"] as String?).flatMap(URL.init(string:))
                    return ClosedTabEntry(
                        id: id,
                        tabID: TabID(rawValue: tabID),
                        spaceID: SpaceID(rawValue: spaceID),
                        title: row["title"] ?? "",
                        url: url,
                        closedAt: row["closed_at"] ?? Date()
                    )
                }
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    @discardableResult
    public func remove(id: Int64) throws -> ClosedTabEntry? {
        do {
            let entry = try recent(limit: 1000).first { $0.id == id }
            try database.databaseQueue.write { db in
                try db.execute(sql: "DELETE FROM closed_tabs WHERE id = ?", arguments: [id])
            }
            return entry
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func deleteAll() throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(sql: "DELETE FROM closed_tabs")
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }
}
