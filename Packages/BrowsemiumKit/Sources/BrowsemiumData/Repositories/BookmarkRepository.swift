import BrowsemiumCore
import Foundation
import GRDB

public struct Bookmark: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let url: URL
    public let title: String
    public let folder: String?
    public let createdAt: Date

    public init(id: UUID = UUID(), url: URL, title: String, folder: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.folder = folder
        self.createdAt = createdAt
    }
}

public final class BookmarkRepository: @unchecked Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    @discardableResult
    public func add(url: URL, title: String, folder: String? = nil) throws -> Bookmark {
        let bookmark = Bookmark(url: url, title: title, folder: folder)
        do {
            try database.databaseQueue.write { db in
                let order = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sort_order), 0) + 1 FROM bookmarks") ?? 1
                try db.execute(
                    sql: """
                        INSERT INTO bookmarks (id, url, title, folder, sort_order, created_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        bookmark.id.uuidString,
                        url.absoluteString,
                        title,
                        folder,
                        order,
                        bookmark.createdAt
                    ]
                )
            }
            return bookmark
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func all() throws -> [Bookmark] {
        try read(sql: "SELECT * FROM bookmarks ORDER BY sort_order ASC", arguments: [])
    }

    /// Inserts many bookmarks in one transaction, skipping URLs that already
    /// exist. Used by the browser importer so a large import is a single write
    /// instead of hundreds of round trips.
    @discardableResult
    public func addMany(_ items: [(url: URL, title: String, folder: String?)]) throws -> Int {
        guard !items.isEmpty else { return 0 }
        do {
            return try database.databaseQueue.write { db in
                let existing = try Set(String.fetchAll(db, sql: "SELECT url FROM bookmarks"))
                var order = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sort_order), 0) FROM bookmarks") ?? 0
                var inserted = 0
                var seen = existing
                for item in items {
                    let key = item.url.absoluteString
                    guard !seen.contains(key) else { continue }
                    seen.insert(key)
                    order += 1
                    try db.execute(
                        sql: """
                            INSERT INTO bookmarks (id, url, title, folder, sort_order, created_at)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            UUID().uuidString,
                            key,
                            item.title,
                            item.folder,
                            order,
                            Date()
                        ]
                    )
                    inserted += 1
                }
                return inserted
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func contains(url: URL) throws -> Bool {
        do {
            return try database.databaseQueue.read { db in
                try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM bookmarks WHERE url = ?)",
                    arguments: [url.absoluteString]
                ) ?? false
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func search(_ query: String) throws -> [Bookmark] {
        let pattern = "%\(query)%"
        return try read(
            sql: """
                SELECT * FROM bookmarks
                WHERE title LIKE ? COLLATE NOCASE OR url LIKE ? COLLATE NOCASE
                ORDER BY sort_order ASC
                """,
            arguments: [pattern, pattern]
        )
    }

    @discardableResult
    public func remove(id: UUID) throws -> Bool {
        do {
            return try database.databaseQueue.write { db in
                try db.execute(sql: "DELETE FROM bookmarks WHERE id = ?", arguments: [id.uuidString])
                return db.changesCount > 0
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    @discardableResult
    public func remove(url: URL) throws -> Bool {
        do {
            return try database.databaseQueue.write { db in
                try db.execute(sql: "DELETE FROM bookmarks WHERE url = ?", arguments: [url.absoluteString])
                return db.changesCount > 0
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func deleteAll() throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(sql: "DELETE FROM bookmarks")
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    private func read(sql: String, arguments: StatementArguments) throws -> [Bookmark] {
        do {
            return try database.databaseQueue.read { db in
                try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
                    guard let idString = row["id"] as String?,
                          let id = UUID(uuidString: idString),
                          let urlString = row["url"] as String?,
                          let url = URL(string: urlString) else {
                        return nil
                    }
                    return Bookmark(
                        id: id,
                        url: url,
                        title: row["title"] ?? "",
                        folder: row["folder"],
                        createdAt: row["created_at"] ?? Date()
                    )
                }
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }
}
