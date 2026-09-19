import BrowsemiumCore
import Foundation
import GRDB

public struct MaintenanceReport: Hashable, Sendable {
    public let prunedHistoryVisits: Int
    public let trimmedClosedTabs: Int
}

public final class DatabaseMaintenance: @unchecked Sendable {
    public var maximumClosedTabs: Int

    private let database: AppDatabase

    public init(database: AppDatabase, maximumClosedTabs: Int = 50) {
        self.database = database
        self.maximumClosedTabs = maximumClosedTabs
    }

    @discardableResult
    public func run(settings: BrowserSettings, now: Date = Date()) throws -> MaintenanceReport {
        do {
            return try database.databaseQueue.write { db in
                var prunedVisits = 0
                if let days = settings.historyRetentionDays {
                    let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
                    try db.execute(sql: "DELETE FROM history_visits WHERE visited_at < ?", arguments: [cutoff])
                    prunedVisits = db.changesCount
                }

                try db.execute(
                    sql: """
                        DELETE FROM closed_tabs WHERE id NOT IN (
                            SELECT id FROM closed_tabs ORDER BY closed_at DESC LIMIT ?
                        )
                        """,
                    arguments: [maximumClosedTabs]
                )
                let trimmedClosedTabs = db.changesCount

                return MaintenanceReport(
                    prunedHistoryVisits: prunedVisits,
                    trimmedClosedTabs: trimmedClosedTabs
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }
}
