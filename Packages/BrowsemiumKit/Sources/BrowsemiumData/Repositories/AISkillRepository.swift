import BrowsemiumCore
import Foundation
import GRDB

/// Saved assistant prompts. Profile-scoped like every other user artifact:
/// a skill saved in one profile stays there.
public final class AISkillRepository: @unchecked Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func all() throws -> [AISkill] {
        do {
            return try database.databaseQueue.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM ai_skills ORDER BY name COLLATE NOCASE")
                    .map(Self.skill(from:))
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    @discardableResult
    public func save(name: String, prompt: String) throws -> AISkill {
        let skill = AISkill(name: name, prompt: prompt)
        do {
            try database.databaseQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO ai_skills (id, name, prompt, created_at) VALUES (?, ?, ?, ?)",
                    arguments: [skill.id.uuidString, skill.name, skill.prompt, skill.createdAt]
                )
            }
            return skill
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    @discardableResult
    public func remove(id: UUID) throws -> Bool {
        do {
            return try database.databaseQueue.write { db in
                try db.execute(sql: "DELETE FROM ai_skills WHERE id = ?", arguments: [id.uuidString])
                return db.changesCount > 0
            }
        } catch {
            throw BrowsemiumError.databaseFailure(error.localizedDescription)
        }
    }

    private static func skill(from row: Row) -> AISkill {
        AISkill(
            id: UUID(uuidString: row["id"]) ?? UUID(),
            name: row["name"],
            prompt: row["prompt"],
            createdAt: row["created_at"] ?? Date()
        )
    }
}
