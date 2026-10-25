import BrowsemiumCore
import BrowsemiumData
import Foundation
import GRDB
import Testing

@Test
func sitePoliciesRoundTripAndNormalizeHosts() throws {
    let database = try AppDatabase.inMemoryProfile()
    let repository = ExtensionSitePolicyRepository(database: database)

    #expect(try repository.policies(for: "ext").isEmpty)
    #expect(try repository.mode(extensionID: "ext", host: "example.com") == nil)

    try repository.set(extensionID: "ext", host: "Example.COM", mode: .deny)
    #expect(try repository.mode(extensionID: "ext", host: "example.com") == .deny)
    #expect(try repository.mode(extensionID: "ext", host: "https://example.com/page") == .deny)

    // Updating the same host replaces the row, never duplicates it.
    try repository.set(extensionID: "ext", host: "example.com", mode: .allow)
    #expect(try repository.policies(for: "ext").count == 1)
    #expect(try repository.mode(extensionID: "ext", host: "example.com") == .allow)

    // Sibling hosts are isolated.
    #expect(try repository.mode(extensionID: "ext", host: "sibling.com") == nil)
    try repository.set(extensionID: "ext", host: "sibling.com", mode: .deny)
    #expect(try repository.mode(extensionID: "ext", host: "example.com") == .allow)
    #expect(try repository.mode(extensionID: "ext", host: "sibling.com") == .deny)

    // Clearing returns the host to WebKit's default.
    try repository.remove(extensionID: "ext", host: "example.com")
    #expect(try repository.mode(extensionID: "ext", host: "example.com") == nil)
    #expect(try repository.policies(for: "ext").count == 1)
}

@Test
func sitePoliciesAreScopedToTheExtensionAndProfile() throws {
    let databaseA = try AppDatabase.inMemoryProfile()
    let databaseB = try AppDatabase.inMemoryProfile()
    let repositoryA = ExtensionSitePolicyRepository(database: databaseA)
    let repositoryB = ExtensionSitePolicyRepository(database: databaseB)

    try repositoryA.set(extensionID: "ext-a", host: "example.com", mode: .deny)
    try repositoryA.set(extensionID: "ext-b", host: "example.com", mode: .allow)

    #expect(try repositoryA.mode(extensionID: "ext-a", host: "example.com") == .deny)
    #expect(try repositoryA.mode(extensionID: "ext-b", host: "example.com") == .allow)
    // The other profile's database knows nothing about either choice.
    #expect(try repositoryB.policies(for: "ext-a").isEmpty)
    #expect(try repositoryB.mode(extensionID: "ext-a", host: "example.com") == nil)
}

@Test
func removingAnExtensionClearsItsSiteChoices() throws {
    let database = try AppDatabase.inMemoryProfile()
    let repository = ExtensionSitePolicyRepository(database: database)

    try repository.set(extensionID: "ext", host: "one.example", mode: .deny)
    try repository.set(extensionID: "ext", host: "two.example", mode: .allow)
    try repository.removeAll(for: "ext")

    #expect(try repository.policies(for: "ext").isEmpty)
    #expect(try repository.allPolicies().isEmpty)
}

@Test
func unreadableHostsAreRefusedRatherThanStoredRaw() throws {
    let database = try AppDatabase.inMemoryProfile()
    let repository = ExtensionSitePolicyRepository(database: database)

    #expect(throws: BrowsemiumError.self) {
        try repository.set(extensionID: "ext", host: "   ", mode: .deny)
    }
    #expect(throws: BrowsemiumError.self) {
        try repository.set(extensionID: "", host: "example.com", mode: .deny)
    }
    #expect(try repository.allPolicies().isEmpty)
}

@Test
func sitePolicyTableExistsAfterMigration() throws {
    let database = try AppDatabase.inMemoryProfile()
    let tables = try database.databaseQueue.read { db in
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    #expect(tables.contains("extension_site_policies"))
}

@Test
func sitePolicyHostNormalization() {
    #expect(ExtensionSitePolicy.normalizeHost("Example.COM") == "example.com")
    #expect(ExtensionSitePolicy.normalizeHost("https://Example.com/Page") == "example.com")
    #expect(ExtensionSitePolicy.normalizeHost("http://sub.example.com:8080/x") == "sub.example.com")
    #expect(ExtensionSitePolicy.normalizeHost("localhost") == "localhost")
    #expect(ExtensionSitePolicy.normalizeHost("   ") == nil)
    #expect(ExtensionSitePolicy.normalizeHost("") == nil)
}
