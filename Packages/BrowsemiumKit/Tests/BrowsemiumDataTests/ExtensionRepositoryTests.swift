import BrowsemiumCore
import BrowsemiumData
import Foundation
import GRDB
import Testing

@Test
func extensionRegistryRoundTripsEnablementAndErrors() throws {
    let database = try AppDatabase.inMemoryProfile()
    let repository = ExtensionRepository(database: database)

    let record = try repository.upsert(id: "demo", name: "Demo", version: "1.0")
    #expect(record.isEnabled == false)
    #expect(try repository.all().count == 1)

    try repository.setEnabled(id: "demo", isEnabled: true)
    #expect(try repository.record(id: "demo")?.isEnabled == true)

    try repository.setLastError(id: "demo", message: "Manifest is invalid")
    #expect(try repository.record(id: "demo")?.lastError == "Manifest is invalid")

    try repository.remove(id: "demo")
    #expect(try repository.all().isEmpty)
}

@Test
func reinstallingKeepsTheUsersEnablementChoice() throws {
    let database = try AppDatabase.inMemoryProfile()
    let repository = ExtensionRepository(database: database)

    try repository.upsert(id: "demo", name: "Demo", version: "1.0")
    try repository.setEnabled(id: "demo", isEnabled: true)

    // A reinstall updates the metadata but must not silently disable — or
    // silently enable — anything.
    let updated = try repository.upsert(id: "demo", name: "Demo Renamed", version: "2.0")

    #expect(updated.isEnabled == true)
    #expect(updated.name == "Demo Renamed")
    #expect(updated.version == "2.0")
}

@Test
func reconcileAddsUnknownExtensionsDisabled() throws {
    let database = try AppDatabase.inMemoryProfile()
    let repository = ExtensionRepository(database: database)
    try repository.upsert(id: "existing", name: "Existing", version: "1.0")
    try repository.setEnabled(id: "existing", isEnabled: true)

    try repository.reconcile(with: [
        "existing": (name: "Existing", version: "1.0"),
        "newcomer": (name: "Newcomer", version: "0.1")
    ])

    let all = try repository.all()
    #expect(all.count == 2)
    #expect(all.first { $0.id == "existing" }?.isEnabled == true)
    #expect(all.first { $0.id == "newcomer" }?.isEnabled == false)
}

@Test
func extensionEnablementIsScopedToTheProfileDatabase() throws {
    let databaseA = try AppDatabase.inMemoryProfile()
    let databaseB = try AppDatabase.inMemoryProfile()
    let repositoryA = ExtensionRepository(database: databaseA)
    let repositoryB = ExtensionRepository(database: databaseB)

    try repositoryA.upsert(id: "demo", name: "Demo", version: "1.0", enabledByDefault: true)

    #expect(try repositoryA.record(id: "demo")?.isEnabled == true)
    #expect(try repositoryB.record(id: "demo") == nil)
}

@Test
func extensionsTableExistsAfterMigration() throws {
    let database = try AppDatabase.inMemoryProfile()
    let tables = try database.databaseQueue.read { db in
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    #expect(tables.contains("extensions"))
}
