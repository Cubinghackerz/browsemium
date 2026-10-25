import Testing
@testable import BrowsemiumUI

@Test
func everySettingsCardLivesInExactlyOneSection() {
    let cards = SettingsCatalog.entries.map(\.card)
    #expect(Set(cards).count == cards.count, "no card is listed twice")
    #expect(Set(cards) == Set(SettingsCardID.allCases), "no card is missing")
    for pane in SettingsPane.allCases {
        #expect(!SettingsCatalog.cards(in: pane).isEmpty, Comment(rawValue: "\(pane.title) is empty"))
    }
    let reached = SettingsPane.allCases.flatMap { SettingsCatalog.cards(in: $0) }
    #expect(Set(reached) == Set(SettingsCardID.allCases))
}

@Test
func searchFindsCardsByTitleKeywordAndSection() {
    #expect(SettingsCatalog.cards(matching: "compact").contains(.general))
    #expect(SettingsCatalog.cards(matching: "inspector").contains(.browsing))
    #expect(SettingsCatalog.cards(matching: "memory").contains(.performance))
    #expect(SettingsCatalog.cards(matching: "keychain") == [.passwords])
    #expect(SettingsCatalog.cards(matching: "MCP").contains(.agent))
    #expect(SettingsCatalog.cards(matching: "apple intelligence").contains(.assistant))
    // A section's name finds everything in it.
    #expect(Set(SettingsCatalog.cards(matching: "extensions")).contains(.extensions))
    // Several words must all match.
    #expect(SettingsCatalog.cards(matching: "tab layout") == [.general])
    #expect(SettingsCatalog.cards(matching: "tab zzzz").isEmpty)
}

@Test
func anEmptyOrUnknownSearchFindsNothing() {
    #expect(SettingsCatalog.cards(matching: "   ").isEmpty)
    #expect(SettingsCatalog.cards(matching: "qqqqqq").isEmpty)
}

@Test
func accentsDoNotGetInTheWay() {
    #expect(SettingsCatalog.cards(matching: "lìcense").contains(.about))
    #expect(SettingsCatalog.cards(matching: "licénse").contains(.about))
}
