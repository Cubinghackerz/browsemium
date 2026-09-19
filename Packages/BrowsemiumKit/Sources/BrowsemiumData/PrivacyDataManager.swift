import BrowsemiumCore
import Foundation
import GRDB

public final class PrivacyDataManager: @unchecked Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func clear(_ scope: ClearScope) throws {
        var statements: [String] = []
        if scope.contains(.history) {
            statements.append("DELETE FROM history_visits")
        }
        if scope.contains(.downloads) {
            statements.append("DELETE FROM downloads")
        }
        if scope.contains(.sitePermissions) {
            statements.append("DELETE FROM site_permissions")
        }
        if scope.contains(.sitePreferences) {
            statements.append("DELETE FROM site_preferences")
        }
        if scope.contains(.closedTabs) {
            statements.append("DELETE FROM closed_tabs")
        }
        if scope.contains(.aiConversations) {
            statements.append("DELETE FROM ai_conversations")
        }
        guard !statements.isEmpty else { return }

        do {
            try database.databaseQueue.write { db in
                for statement in statements {
                    try db.execute(sql: statement)
                }
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }
}
