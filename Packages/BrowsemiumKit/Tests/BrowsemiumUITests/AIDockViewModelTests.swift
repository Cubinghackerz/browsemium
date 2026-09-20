import BrowsemiumUI
import Foundation
import Testing

@Test
func composerPreparationPreservesItsIdentity() {
    let id = UUID()
    let preparation = ProviderComposerPreparation(
        text: "Ask about this page",
        fileURLs: [],
        id: id
    )

    #expect(preparation.id == id)
    #expect(preparation.text == "Ask about this page")
}

@Test
func composerPreparationsGetIndependentDefaultIdentities() {
    let first = ProviderComposerPreparation(text: "first")
    let second = ProviderComposerPreparation(text: "second")

    #expect(first.id != second.id)
}
