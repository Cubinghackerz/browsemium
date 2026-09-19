import BrowsemiumCore
import Foundation
import GRDB

public struct HistoryVisit: Hashable, Codable, Sendable, Identifiable {
    public let id: Int64
    public let url: URL
    public let title: String
    public let visitedAt: Date

    public init(id: Int64, url: URL, title: String, visitedAt: Date) {
        self.id = id
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
    }
}

public final class HistoryRepository: @unchecked Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    @discardableResult
    public func record(url: URL, title: String, visitedAt: Date = Date()) throws -> HistoryVisit {
        do {
            return try database.databaseQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO history_visits (url, title, visited_at) VALUES (?, ?, ?)",
                    arguments: [url.absoluteString, title, visitedAt]
                )
                let id = db.lastInsertedRowID
                return HistoryVisit(id: id, url: url, title: title, visitedAt: visitedAt)
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func recent(limit: Int = 200) throws -> [HistoryVisit] {
        try read(
            sql: "SELECT id, url, title, visited_at FROM history_visits ORDER BY visited_at DESC LIMIT ?",
            arguments: [limit]
        )
    }

    public func search(_ query: String, limit: Int = 50) throws -> [HistoryVisit] {
        guard let match = Self.fullTextQuery(query) else {
            return try recent(limit: limit)
        }
        return try read(
            sql: """
                SELECT h.id, h.url, h.title, h.visited_at
                FROM history_visits h
                JOIN history_visits_fts f ON f.rowid = h.id
                WHERE history_visits_fts MATCH ?
                ORDER BY h.visited_at DESC
                LIMIT ?
                """,
            arguments: [match, limit]
        )
    }

    /// URLs already present in history, so an import does not duplicate them.
    public func existingURLs(among urls: [URL]) throws -> Set<String> {
        guard !urls.isEmpty else { return [] }
        do {
            return try database.databaseQueue.read { db in
                var found = Set<String>()
                // Chunked to stay well under SQLite's variable limit.
                for chunk in stride(from: 0, to: urls.count, by: 400) {
                    let slice = urls[chunk..<min(chunk + 400, urls.count)].map(\.absoluteString)
                    let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ", ")
                    let rows = try String.fetchAll(
                        db,
                        sql: "SELECT DISTINCT url FROM history_visits WHERE url IN (\(placeholders))",
                        arguments: StatementArguments(slice)
                    )
                    found.formUnion(rows)
                }
                return found
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    /// Records many visits in a single transaction.
    @discardableResult
    public func recordMany(_ visits: [(url: URL, title: String, visitedAt: Date)]) throws -> Int {
        guard !visits.isEmpty else { return 0 }
        do {
            return try database.databaseQueue.write { db in
                var inserted = 0
                for visit in visits {
                    try db.execute(
                        sql: "INSERT INTO history_visits (url, title, visited_at) VALUES (?, ?, ?)",
                        arguments: [visit.url.absoluteString, visit.title, visit.visitedAt]
                    )
                    inserted += 1
                }
                return inserted
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func count() throws -> Int {
        do {
            return try database.databaseQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM history_visits") ?? 0
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func deleteAll() throws {
        try write("DELETE FROM history_visits")
    }

    @discardableResult
    public func delete(olderThan date: Date) throws -> Int {
        do {
            return try database.databaseQueue.write { db in
                try db.execute(sql: "DELETE FROM history_visits WHERE visited_at < ?", arguments: [date])
                return db.changesCount
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    @discardableResult
    public func delete(_ visit: HistoryVisit) throws -> Bool {
        do {
            return try database.databaseQueue.write { db in
                try db.execute(sql: "DELETE FROM history_visits WHERE id = ?", arguments: [visit.id])
                return db.changesCount > 0
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    private func read(sql: String, arguments: StatementArguments) throws -> [HistoryVisit] {
        do {
            return try database.databaseQueue.read { db in
                try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
                    guard let urlString = row["url"] as String?,
                          let url = URL(string: urlString) else {
                        return nil
                    }
                    return HistoryVisit(
                        id: row["id"],
                        url: url,
                        title: row["title"] ?? "",
                        visitedAt: row["visited_at"] ?? Date()
                    )
                }
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    private func write(_ sql: String) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(sql: sql)
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    static func fullTextQuery(_ query: String) -> String? {
        let tokens = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens
            .map { "\"\($0)\"*" }
            .joined(separator: " ")
    }
}
