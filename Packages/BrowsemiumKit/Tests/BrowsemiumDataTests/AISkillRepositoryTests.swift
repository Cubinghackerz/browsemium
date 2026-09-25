import BrowsemiumCore
import BrowsemiumData
import Foundation
import GRDB
import Testing

@Test
func aiSkillsRoundTripAndSortByName() throws {
    let database = try AppDatabase.inMemoryProfile()
    let repository = AISkillRepository(database: database)

    try repository.save(name: "Zebra summary", prompt: "Summarize like a zebra.")
    try repository.save(name: "Alpha rewrite", prompt: "Rewrite tightly.")

    let all = try repository.all()
    #expect(all.map(\.name) == ["Alpha rewrite", "Zebra summary"])
    #expect(all.first?.prompt == "Rewrite tightly.")
}

@Test
func removingAnAISkillReportsWhetherItExisted() throws {
    let database = try AppDatabase.inMemoryProfile()
    let repository = AISkillRepository(database: database)
    let skill = try repository.save(name: "Temporary", prompt: "Delete me.")

    #expect(try repository.remove(id: skill.id) == true)
    #expect(try repository.remove(id: skill.id) == false)
    #expect(try repository.all().isEmpty)
}

@Test
func aiSkillsAreScopedToTheProfileDatabase() throws {
    let databaseA = try AppDatabase.inMemoryProfile()
    let databaseB = try AppDatabase.inMemoryProfile()
    try AISkillRepository(database: databaseA).save(name: "Only here", prompt: "Local.")

    #expect(try AISkillRepository(database: databaseB).all().isEmpty)
}

@Test
func aiSkillsTableExistsAfterMigration() throws {
    let database = try AppDatabase.inMemoryProfile()
    let tables = try database.databaseQueue.read { db in
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    #expect(tables.contains("ai_skills"))
}
