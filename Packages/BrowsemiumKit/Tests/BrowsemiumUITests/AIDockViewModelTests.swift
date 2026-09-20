@testable import BrowsemiumUI
import BrowsemiumCore
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

@Test
func automaticWebContextIsTextOnly() {
    let kinds = WebAIContextPolicy.automaticCaptureKinds(
        includePageContext: true,
        hasReadablePage: false,
        pageURL: URL(string: "https://example.com/article")
    )

    #expect(kinds == [.readablePage])
    #expect(!kinds.contains(.viewportImage))
    #expect(!kinds.contains(.fullPageImage))
}

@Test
func automaticWebContextDoesNotCaptureUnsupportedPages() {
    let kinds = WebAIContextPolicy.automaticCaptureKinds(
        includePageContext: true,
        hasReadablePage: false,
        pageURL: URL(string: "file:///tmp/page.html")
    )

    #expect(kinds.isEmpty)
}
