@testable import BrowsemiumUI
import BrowsemiumCore
import Foundation
import Testing
import BrowsemiumEngineKit

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

@Test @MainActor
func quickActionWithoutAPageFailsVisibly() async {
    let model = BrowserWindowModel()
    let ai = AIDockViewModel(environment: model.environment)

    await ai.runQuickAction(.summarizePage, tabID: nil)

    #expect(ai.errorMessage != nil)
    #expect(!ai.isReviewPresented)
}

@Test @MainActor
func quickActionCaptureFailureKeepsTheReviewClosed() async {
    let model = BrowserWindowModel()
    let ai = AIDockViewModel(environment: model.environment)
    // The tab exists but has no live web view, so capture must throw.
    let tabID = try! #require(model.session.activeTabID)

    await ai.runQuickAction(.summarizePage, tabID: tabID)

    #expect(ai.errorMessage != nil)
    #expect(!ai.isReviewPresented)
    // The canned prompt must not leak into the draft on failure.
    #expect(ai.draft.isEmpty)
}

@Test @MainActor
func quickActionRequestsOpenTheDockAndHandOffOnce() {
    let model = BrowserWindowModel()
    model.perform(.aiQuickAction(.summarizePage))

    #expect(model.isAIDockVisible)
    #expect(model.consumePendingAIQuickAction() == .summarizePage)
    #expect(model.consumePendingAIQuickAction() == nil)
}
