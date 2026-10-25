import BrowsemiumCore
import Foundation
import GRDB

/// Per-profile page watches. Holds hashes, never page text.
public final class PageWatchRepository: @unchecked Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func all() throws -> [PageWatch] {
        do {
            return try database.databaseQueue.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM page_watches ORDER BY created_at, id").compactMap(Self.watch(from:))
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    /// Adds a watch for an https page, or returns the existing one for the
    /// same address. Refuses beyond the limit.
    @discardableResult
    public func add(url: URL, title: String, intervalMinutes: Int, now: Date = Date()) throws -> PageWatch {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            throw BrowsemiumError.databaseFailure("Only ordinary https pages can be watched.")
        }
        let interval = max(intervalMinutes, PageWatchLimits.minimumIntervalMinutes)
        let stripped = Self.withoutFragment(url)
        do {
            return try database.databaseQueue.write { db in
                if let row = try Row.fetchOne(db, sql: "SELECT * FROM page_watches WHERE url = ?", arguments: [stripped.absoluteString]),
                   let existing = Self.watch(from: row) {
                    return existing
                }
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM page_watches") ?? 0
                guard count < PageWatchLimits.maximumWatches else {
                    throw BrowsemiumError.databaseFailure("You can watch up to \(PageWatchLimits.maximumWatches) pages. Remove one first.")
                }
                let watch = PageWatch(url: stripped, title: title.isEmpty ? host : title, intervalMinutes: interval, createdAt: now)
                try db.execute(
                    sql: """
                        INSERT INTO page_watches (id, url, title, interval_minutes, consecutive_failures, created_at)
                        VALUES (?, ?, ?, ?, 0, ?)
                        """,
                    arguments: [watch.id.uuidString, watch.url.absoluteString, watch.title, watch.intervalMinutes, watch.createdAt]
                )
                return watch
            }
        } catch let error as BrowsemiumError {
            throw error
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    /// Records the result of a check.
    public func recordCheck(_ watch: PageWatch) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: """
                        UPDATE page_watches SET title = ?, last_hash = ?, last_sentences = ?, last_checked_at = ?,
                            last_changed_at = ?, consecutive_failures = ?, last_problem = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        watch.title, watch.lastHash, watch.lastSentences.joined(separator: " "),
                        watch.lastCheckedAt, watch.lastChangedAt, watch.consecutiveFailures, watch.lastProblem,
                        watch.id.uuidString
                    ]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func setInterval(minutes: Int, id: UUID) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: "UPDATE page_watches SET interval_minutes = ?, consecutive_failures = 0, last_problem = NULL WHERE id = ?",
                    arguments: [max(minutes, PageWatchLimits.minimumIntervalMinutes), id.uuidString]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func remove(id: UUID) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(sql: "DELETE FROM page_watches WHERE id = ?", arguments: [id.uuidString])
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public static func withoutFragment(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.fragment = nil
        return components.url ?? url
    }

    private static func watch(from row: Row) -> PageWatch? {
        guard let idString = row["id"] as String?, let id = UUID(uuidString: idString),
              let urlString = row["url"] as String?, let url = URL(string: urlString) else { return nil }
        let sentences = ((row["last_sentences"] as String?) ?? "").split(separator: " ").map(String.init)
        return PageWatch(
            id: id,
            url: url,
            title: row["title"] ?? url.host ?? "",
            intervalMinutes: row["interval_minutes"] ?? PageWatchLimits.defaultIntervalMinutes,
            lastHash: row["last_hash"],
            lastSentences: sentences,
            lastCheckedAt: row["last_checked_at"],
            lastChangedAt: row["last_changed_at"],
            consecutiveFailures: row["consecutive_failures"] ?? 0,
            lastProblem: row["last_problem"],
            createdAt: row["created_at"] ?? Date()
        )
    }
}
