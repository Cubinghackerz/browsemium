import BrowsemiumCore
import BrowsemiumData
import Foundation
import Testing

@Test
func cosmeticRulesRoundTripForTheirHost() throws {
    let database = try AppDatabase.inMemoryProfile()
    let repository = CosmeticRuleRepository(database: database)

    let first = try repository.add(host: "example.com", selector: "#promo", label: "div#promo")
    _ = try repository.add(host: "example.com", selector: "body > aside:nth-of-type(2)", label: "aside")
    _ = try repository.add(host: "other.test", selector: "#banner", label: "div#banner")

    let rules = try repository.rules(host: "example.com")
    #expect(rules.count == 2)
    #expect(rules.first?.id == first.id)
    #expect(rules.first?.selector == "#promo")
    #expect(try repository.rules(host: "other.test").count == 1)
    #expect(try repository.rules(host: "missing.test").isEmpty)
}

@Test
func cosmeticRuleHostsAreNormalizedToLowercase() throws {
    let database = try AppDatabase.inMemoryProfile()
    let repository = CosmeticRuleRepository(database: database)

    _ = try repository.add(host: "Example.COM", selector: "#ad", label: "div#ad")

    #expect(try repository.rules(host: "example.com").count == 1)
    #expect(try repository.hosts() == ["example.com"])
}

@Test
func disablingARuleKeepsItForLater() throws {
    let database = try AppDatabase.inMemoryProfile()
    let repository = CosmeticRuleRepository(database: database)
    let rule = try repository.add(host: "example.com", selector: "#ad", label: "div#ad")

    try repository.setEnabled(false, id: rule.id)

    let stored = try repository.rules(host: "example.com")
    #expect(stored.count == 1)
    #expect(stored.first?.isEnabled == false)

    try repository.setEnabled(true, id: rule.id)
    #expect(try repository.rules(host: "example.com").first?.isEnabled == true)
}

@Test
func removingARuleDeletesIt() throws {
    let database = try AppDatabase.inMemoryProfile()
    let repository = CosmeticRuleRepository(database: database)
    let rule = try repository.add(host: "example.com", selector: "#ad", label: "div#ad")

    try repository.remove(id: rule.id)

    #expect(try repository.rules(host: "example.com").isEmpty)
    #expect(try repository.hosts().isEmpty)
}

@Test
func cssSkipsDisabledRulesAndKeepsTheRest() throws {
    let enabled = CosmeticRule(host: "example.com", selector: "#ad", label: "div#ad")
    let disabled = CosmeticRule(host: "example.com", selector: ".sponsor", label: "div.sponsor", isEnabled: false)

    let css = CosmeticRuleRepository.css(for: [enabled, disabled])

    #expect(css == "#ad { display: none !important; }")
    #expect(CosmeticRuleRepository.css(for: [disabled]).isEmpty)
}

@Test
func cosmeticRulesAreScopedToTheProfileDatabase() throws {
    let databaseA = try AppDatabase.inMemoryProfile()
    let databaseB = try AppDatabase.inMemoryProfile()
    _ = try CosmeticRuleRepository(database: databaseA).add(host: "example.com", selector: "#ad", label: "div#ad")

    #expect(try CosmeticRuleRepository(database: databaseB).hosts().isEmpty)
}
