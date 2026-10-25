import BrowsemiumCore
import BrowsemiumData
import Foundation
import Testing

@Test
func routesRoundTripAndKeepOldestFirst() throws {
    let repository = SpaceRouteRepository(database: try AppDatabase.inMemoryProfile())
    let work = SpaceID()
    let first = try repository.save(host: "GitHub.com", includesSubdomains: false, spaceID: work, now: Date(timeIntervalSince1970: 1))
    _ = try repository.save(host: "example.com", includesSubdomains: true, spaceID: work, now: Date(timeIntervalSince1970: 2))

    let routes = try repository.routes()
    #expect(routes.map(\.host) == ["github.com", "example.com"])
    #expect(routes.first?.id == first.id)
    #expect(routes.last?.includesSubdomains == true)
    #expect(routes.first?.spaceID == work)
}

@Test
func savingTheSameHostRepointsInsteadOfDuplicating() throws {
    let repository = SpaceRouteRepository(database: try AppDatabase.inMemoryProfile())
    let work = SpaceID()
    let personal = SpaceID()
    let first = try repository.save(host: "github.com", includesSubdomains: false, spaceID: work)
    let second = try repository.save(host: "github.com", includesSubdomains: false, spaceID: personal)

    #expect(first.id == second.id)
    let routes = try repository.routes()
    #expect(routes.count == 1)
    #expect(routes.first?.spaceID == personal)

    // The subdomain variant is a separate rule.
    _ = try repository.save(host: "github.com", includesSubdomains: true, spaceID: work)
    #expect(try repository.routes().count == 2)
}

@Test
func invalidHostsAreRefusedBeforeAnythingIsWritten() throws {
    let repository = SpaceRouteRepository(database: try AppDatabase.inMemoryProfile())
    let space = SpaceID()
    for bad in ["https://github.com", "github.com/path", "*.github.com", "", "user@github.com", "github.com:81"] {
        #expect(throws: BrowsemiumError.self) {
            try repository.save(host: bad, includesSubdomains: false, spaceID: space)
        }
    }
    #expect(throws: BrowsemiumError.self) {
        try repository.save(host: "com", includesSubdomains: true, spaceID: space)
    }
    #expect(try repository.routes().isEmpty)
}

@Test
func removingASpaceRemovesItsRulesOnly() throws {
    let repository = SpaceRouteRepository(database: try AppDatabase.inMemoryProfile())
    let work = SpaceID()
    let personal = SpaceID()
    _ = try repository.save(host: "github.com", includesSubdomains: false, spaceID: work)
    _ = try repository.save(host: "gmail.com", includesSubdomains: false, spaceID: personal)

    try repository.removeRoutes(to: work)
    #expect(try repository.routes().map(\.host) == ["gmail.com"])

    let remaining = try #require(try repository.routes().first)
    try repository.remove(id: remaining.id)
    #expect(try repository.routes().isEmpty)
}

@Test
func theRuleCountIsBounded() throws {
    let repository = SpaceRouteRepository(database: try AppDatabase.inMemoryProfile())
    let space = SpaceID()
    for index in 0..<SpaceRouteRepository.maximumRoutes {
        _ = try repository.save(host: "site\(index).example", includesSubdomains: false, spaceID: space)
    }
    #expect(throws: BrowsemiumError.self) {
        try repository.save(host: "one-too-many.example", includesSubdomains: false, spaceID: space)
    }
    // Re-pointing an existing rule is still allowed at the cap.
    _ = try repository.save(host: "site0.example", includesSubdomains: false, spaceID: SpaceID())
    #expect(try repository.routes().count == SpaceRouteRepository.maximumRoutes)
}
