@testable import BrowsemiumUI
import BrowsemiumCore
import Foundation
import Testing
import BrowsemiumEngineKit

@Test @MainActor
func privateAIContextNeverCapturesOrIncludesPageMetadata() async throws {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    model.enterPrivateMode()
    let tabID = model.newTab(url: URL(string: "https://private-ai-fixture.example")!)
    engine.liveTabs.insert(tabID)
    let ai = AIDockViewModel(windowModel: model)
    await ai.attach(.readablePage, tabID: tabID)
    let multi = await model.captureTabsForAI([tabID])
    let preparation = try await ai.prepareWebProviderMessage(userPrompt: "Generic question", tab: model.activeTab, provider: .openAI)
    #expect(engine.capturedTabs.isEmpty)
    #expect(ai.attachments.isEmpty)
    #expect(multi.isEmpty)
    #expect(!preparation.text.contains("private-ai-fixture"))
    #expect(!preparation.text.contains("stub page text"))
}

@Test @MainActor
func privateAIDockDoesNotRestorePersistentConversations() throws {
    let model = BrowserWindowModel(environment: .inMemory(engine: StubEngine()))
    let id = try model.environment.conversationRepository.createConversation(title: "Fixture conversation")
    try model.environment.conversationRepository.appendMessage(conversationID: id, role: .user, content: "Fixture text")
    model.enterPrivateMode()
    let ai = AIDockViewModel(windowModel: model)
    ai.refreshConversations()
    ai.openConversation(id)
    #expect(ai.conversationList.isEmpty)
    #expect(ai.messages.isEmpty)
    #expect(ai.currentConversationID == nil)
}

@Test @MainActor
func unlockedAIPageStillCapturesReadableText() async {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    let tabID = model.newTab(url: URL(string: "https://public-ai-fixture.example")!)
    let ai = AIDockViewModel(windowModel: model)
    await ai.attach(.readablePage, tabID: tabID)
    #expect(engine.capturedTabs == [tabID])
    #expect(ai.attachments.count == 1)
}

@Test @MainActor
func lockedAIContextNeverCapturesOrIncludesPageMetadata() async throws {
    let engine = StubEngine()
    let model = BrowserWindowModel(environment: .inMemory(engine: engine))
    let space = model.createGroup(named: "Locked fixture")
    let tabID = model.newTab(url: URL(string: "https://locked-ai-fixture.example")!)
    engine.liveTabs.insert(tabID)
    let tab = try #require(model.activeTab)
    model.setSpaceLocked(space, locked: true)
    let ai = AIDockViewModel(windowModel: model)
    await ai.attach(.readablePage, tabID: tabID)
    let preparation = try await ai.prepareWebProviderMessage(userPrompt: "Generic question", tab: tab, provider: .openAI)
    #expect(engine.capturedTabs.isEmpty)
    #expect(ai.attachments.isEmpty)
    #expect(!preparation.text.contains("locked-ai-fixture"))
    #expect(!preparation.text.contains("stub page text"))
}

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
