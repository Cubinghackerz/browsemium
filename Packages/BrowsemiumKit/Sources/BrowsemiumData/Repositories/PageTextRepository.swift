import BrowsemiumCore
import Foundation
import GRDB

/// One indexed page's searchable text.
public struct PageTextEntry: Hashable, Codable, Sendable {
    public let url: URL
    public let title: String
    public let snippet: String
    public let indexedAt: Date

    public init(url: URL, title: String, snippet: String, indexedAt: Date = Date()) {
        self.url = url
        self.title = title
        self.snippet = snippet
        self.indexedAt = indexedAt
    }
}

/// The opt-in on-Mac page-text index. Stores at most 4 KB of readable text
/// per page, unencrypted, in the profile database. Only ever holds pages the
/// eligibility policy allowed in; private, locked, separate-data, and
/// credentialed pages never reach it, and callers filter per-site excludes
/// at query time.
public final class PageTextRepository: @unchecked Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Inserts or replaces one page's text. Snippets longer than 4 KB are
    /// refused rather than silently truncated.
    public func index(url: URL, title: String, snippet: String, now: Date = Date()) throws {
        guard let bytes = snippet.data(using: .utf8), bytes.count <= PageTextIndexPolicy.maxSnippetBytes else {
            throw BrowsemiumError.invalidInput("Page text exceeds the 4 KB index limit.")
        }
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO page_texts (url, title, snippet, indexed_at)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(url) DO UPDATE SET
                            title = excluded.title,
                            snippet = excluded.snippet,
                            indexed_at = excluded.indexed_at
                        """,
                    arguments: [url.absoluteString, title, snippet, now]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    /// Full-text matches, best first, one row per page. Excluded hosts are
    /// filtered by the caller-supplied set so a stale exclude never leaks.
    public func search(_ query: String, limit: Int = 50, excluding hosts: Set<String> = []) throws -> [PageTextEntry] {
        guard let match = Self.fullTextQuery(query) else { return [] }
        do {
            return try database.databaseQueue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT p.url, p.title, p.snippet, p.indexed_at, bm25(page_texts_fts) AS rank
                        FROM page_texts p
                        JOIN page_texts_fts f ON f.rowid = p.rowid
                        WHERE page_texts_fts MATCH ?
                        ORDER BY rank
                        LIMIT ?
                        """,
                    arguments: [match, limit]
                )
                var entries: [PageTextEntry] = []
                for row in rows {
                    guard let rawURL = row["url"] as String?,
                          let url = URL(string: rawURL),
                          !hosts.contains(url.host?.lowercased() ?? "") else { continue }
                    entries.append(PageTextEntry(
                        url: url,
                        title: row["title"] ?? "",
                        snippet: row["snippet"] ?? "",
                        indexedAt: row["indexed_at"] ?? Date()
                    ))
                }
                return entries
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    /// Recent pages for "Resume topics", newest first. Bounded.
    public func recent(limit: Int = 60) throws -> [PageTextEntry] {
        do {
            return try database.databaseQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT url, title, snippet, indexed_at FROM page_texts ORDER BY indexed_at DESC LIMIT ?",
                    arguments: [limit]
                ).compactMap { row in
                    guard let rawURL = row["url"] as String?, let url = URL(string: rawURL) else { return nil }
                    return PageTextEntry(
                        url: url,
                        title: row["title"] ?? "",
                        snippet: row["snippet"] ?? "",
                        indexedAt: row["indexed_at"] ?? Date()
                    )
                }
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    /// Visible size for Settings: page count plus stored snippet bytes.
    public func size() throws -> (pages: Int, bytes: Int) {
        do {
            return try database.databaseQueue.read { db in
                let pages = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM page_texts") ?? 0
                let bytes = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(LENGTH(CAST(snippet AS BLOB))), 0) FROM page_texts") ?? 0
                return (pages, bytes)
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func remove(urls: [URL]) throws {
        guard !urls.isEmpty else { return }
        do {
            try database.databaseQueue.write { db in
                for chunk in stride(from: 0, to: urls.count, by: 400) {
                    let slice = urls[chunk..<min(chunk + 400, urls.count)].map(\.absoluteString)
                    let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ", ")
                    try db.execute(
                        sql: "DELETE FROM page_texts WHERE url IN (\(placeholders))",
                        arguments: StatementArguments(slice)
                    )
                }
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func clear() throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(sql: "DELETE FROM page_texts")
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    /// Tokenizes a query into an FTS5 MATCH expression, mirroring the history
    /// reader. Returns nil for queries with no usable terms, so callers fall
    /// back instead of matching everything.
    static func fullTextQuery(_ query: String) -> String? {
        let tokens = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(10)
        guard !tokens.isEmpty else { return nil }
        return tokens
            .map { "\"\($0)\"*" }
            .joined(separator: " ")
    }
}
