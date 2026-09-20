import BrowsemiumCore
import Foundation
import GRDB

public struct AIConversationSummary: Hashable, Sendable, Identifiable {
    public let id: ConversationID
    public let title: String
    public let updatedAt: Date

    public init(id: ConversationID, title: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }
}

/// Stores assistant conversations in the active profile's database. The
/// `ai_conversations` / `ai_messages` tables have existed since the first
/// schema; this is what finally writes to them.
public final class AIConversationRepository: @unchecked Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    @discardableResult
    public func createConversation(title: String, id: ConversationID = ConversationID()) throws -> ConversationID {
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO ai_conversations (id, title, created_at, updated_at)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [id.rawValue.uuidString, title, Date(), Date()]
                )
            }
            return id
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func appendMessage(
        conversationID: ConversationID,
        role: AIMessageRole,
        content: String,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO ai_messages (id, conversation_id, role, content, created_at)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [id.uuidString, conversationID.rawValue.uuidString, role.rawValue, content, createdAt]
                )
                try db.execute(
                    sql: "UPDATE ai_conversations SET updated_at = ? WHERE id = ?",
                    arguments: [createdAt, conversationID.rawValue.uuidString]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func conversations(limit: Int = 30) throws -> [AIConversationSummary] {
        do {
            return try database.databaseQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT id, title, updated_at FROM ai_conversations ORDER BY updated_at DESC LIMIT ?",
                    arguments: [limit]
                ).compactMap { row in
                    guard let idString = row["id"] as String?,
                          let id = UUID(uuidString: idString) else { return nil }
                    return AIConversationSummary(
                        id: ConversationID(rawValue: id),
                        title: row["title"] ?? "Conversation",
                        updatedAt: row["updated_at"] ?? Date()
                    )
                }
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func messages(conversationID: ConversationID) throws -> [AIMessage] {
        do {
            return try database.databaseQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, role, content, created_at FROM ai_messages
                        WHERE conversation_id = ?
                        ORDER BY created_at ASC
                        """,
                    arguments: [conversationID.rawValue.uuidString]
                ).compactMap { row in
                    guard let idString = row["id"] as String?,
                          let id = UUID(uuidString: idString),
                          let roleRaw = row["role"] as String?,
                          let role = AIMessageRole(rawValue: roleRaw) else { return nil }
                    return AIMessage(
                        id: id,
                        role: role,
                        content: row["content"] ?? "",
                        createdAt: row["created_at"] ?? Date()
                    )
                }
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func rename(conversationID: ConversationID, title: String) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: "UPDATE ai_conversations SET title = ?, updated_at = ? WHERE id = ?",
                    arguments: [title, Date(), conversationID.rawValue.uuidString]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    public func delete(conversationID: ConversationID) throws {
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM ai_conversations WHERE id = ?",
                    arguments: [conversationID.rawValue.uuidString]
                )
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }
}
