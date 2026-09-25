import BrowsemiumCore
import BrowsemiumUI
import Foundation
import Testing
import BrowsemiumEngineKit

// MARK: - Skills

@Test @MainActor
func savingAndRunningASkill() {
    let model = BrowserWindowModel()

    let skill = model.saveAISkill(name: "  Weekly digest  ", prompt: "  Summarize the week.  ")
    #expect(skill?.name == "Weekly digest")
    #expect(skill?.prompt == "Summarize the week.")
    #expect(model.aiSkills.count == 1)

    model.perform(.runAISkill(skill!))
    #expect(model.isAIDockVisible)
    if case .skill(let pending) = model.pendingAssistantTask {
        #expect(pending.id == skill?.id)
    } else {
        Issue.record("Expected a skill task")
    }
    #expect(model.consumePendingAssistantTask() != nil)
    #expect(model.pendingAssistantTask == nil)
}

@Test @MainActor
func aSkillNeedsANameAndAPrompt() {
    let model = BrowserWindowModel()

    #expect(model.saveAISkill(name: "   ", prompt: "Do something") == nil)
    #expect(model.saveAISkill(name: "Empty", prompt: "   ") == nil)
    #expect(model.aiSkills.isEmpty)
    #expect(model.statusMessage == "A skill needs a name and a prompt")
}

@Test @MainActor
func deletingASkillRemovesItFromTheList() {
    let model = BrowserWindowModel()
    let skill = model.saveAISkill(name: "Doomed", prompt: "Delete me.")!

    model.deleteAISkill(skill)

    #expect(model.aiSkills.isEmpty)
    #expect(model.statusMessage == "Deleted skill “Doomed”")
}

@Test @MainActor
func skillsAppearInThePalette() {
    let model = BrowserWindowModel()
    let skill = model.saveAISkill(name: "Meeting notes", prompt: "Turn this into minutes.")!

    let results = model.filteredCommands(query: "meeting")
    let row = results.first { $0.command == .runAISkill(skill) }
    #expect(row != nil)
    #expect(row?.title == "Run Skill: Meeting notes")
    #expect(row?.kind == .action)
}

@Test @MainActor
func summarizeOpenTabsIsAPaletteIntent() {
    let model = BrowserWindowModel()

    let results = model.filteredCommands(query: "summarize open tabs")
    #expect(results.contains { $0.command == .summarizeOpenTabs })

    model.perform(.summarizeOpenTabs)
    #expect(model.isAIDockVisible)
    #expect(model.pendingAssistantTask != nil)
}

// MARK: - Multi-tab context

@Test @MainActor
func tabsWithoutLivePagesAreSkippedForContext() async {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://example.invalid/one"))
    model.newTab(url: URL(string: "https://example.invalid/two"))

    // The test process never completes a real load, so nothing is live and
    // the capture must skip with an explanation rather than hang or invent
    // content.
    let attachments = await model.captureTabsForAI(model.visibleTabs.map(\.id))
    #expect(attachments.isEmpty)
    #expect(model.statusMessage?.contains("had nothing to read") == true)
}

@Test @MainActor
func contextCandidatesExcludeTheActiveAndUnloadedTabs() {
    let model = BrowserWindowModel()
    model.newTab(url: URL(string: "https://example.invalid/one"))

    let candidates = model.tabsAvailableForAIContext()
    #expect(!candidates.contains { $0.id == model.session.activeTabID })
    #expect(candidates.isEmpty)
}

@Test @MainActor
func multiTabSummaryExplainsWhenThereIsOnlyOneTab() async {
    let model = BrowserWindowModel()
    let dock = AIDockViewModel(environment: model.environment)

    await dock.runMultiTabSummary(windowModel: model)

    #expect(dock.errorMessage == "Open another page first — there is only one live tab.")
}

// MARK: - Dock attachment rules

@Test @MainActor
func adoptingPageTextFromSeveralTabsKeepsEveryPage() {
    let model = BrowserWindowModel()
    let dock = AIDockViewModel(environment: model.environment)
    let first = AIContextAttachment.readablePage(
        PageTextContext(url: URL(string: "https://one.example"), title: "One", text: "First page")
    )
    let second = AIContextAttachment.readablePage(
        PageTextContext(url: URL(string: "https://two.example"), title: "Two", text: "Second page")
    )

    dock.adopt([first, second])

    #expect(dock.attachments.count == 2)
}

@Test @MainActor
func recapturingOnePageReplacesOnlyThatPage() {
    let model = BrowserWindowModel()
    let dock = AIDockViewModel(environment: model.environment)
    let url = URL(string: "https://one.example")
    dock.adopt([
        .readablePage(PageTextContext(url: url, title: "One", text: "Old text")),
        .readablePage(PageTextContext(url: URL(string: "https://two.example"), title: "Two", text: "Second page"))
    ])

    dock.adopt([.readablePage(PageTextContext(url: url, title: "One", text: "New text"))])

    #expect(dock.attachments.count == 2)
    let texts = dock.attachments.compactMap { attachment -> String? in
        guard case .readablePage(let context) = attachment else { return nil }
        return context.text
    }
    #expect(texts.contains("New text"))
    #expect(texts.contains("Second page"))
    #expect(!texts.contains("Old text"))
}

@Test @MainActor
func selectionsStaySingular() {
    let model = BrowserWindowModel()
    let dock = AIDockViewModel(environment: model.environment)

    dock.adopt([.selection(PageTextContext(text: "first selection"))])
    dock.adopt([.selection(PageTextContext(text: "second selection"))])

    #expect(dock.attachments.count == 1)
}

@Test @MainActor
func adoptingTabContextFillsTheDraftOnlyWhenEmpty() {
    let model = BrowserWindowModel()
    let dock = AIDockViewModel(environment: model.environment)
    let attachment = AIContextAttachment.readablePage(
        PageTextContext(url: URL(string: "https://one.example"), title: "One", text: "Page")
    )

    dock.adoptTabsContext([attachment], prompt: "Summarize these pages.")
    #expect(dock.draft == "Summarize these pages.")

    dock.clearAttachments()
    dock.draft = "A draft the user already typed"
    dock.adoptTabsContext([attachment], prompt: "Summarize these pages.")
    #expect(dock.draft == "A draft the user already typed")
}

@Test @MainActor
func applyingASkillFillsTheComposerWithoutSending() {
    let model = BrowserWindowModel()
    let dock = AIDockViewModel(environment: model.environment)
    let skill = AISkill(name: "Rewrite", prompt: "Rewrite this tightly.")

    dock.applySkill(skill)

    #expect(dock.draft == "Rewrite this tightly.")
    #expect(dock.isReviewPresented == false)
    #expect(dock.errorMessage == nil)
}

// MARK: - Writing assists

@Test
func writingAssistsCaptureTheSelectionAndNeverThePage() {
    for action in AIQuickAction.allCases where action.isWritingAssist {
        #expect(action.captureKind == .selection)
    }
    #expect(AIQuickAction.rewriteSelection.prompt.contains("Rewrite"))
    #expect(AIQuickAction.shortenSelection.prompt.contains("Shorten"))
    #expect(AIQuickAction.bulletPoints.prompt.contains("bullet"))
}

// MARK: - Locked-space context guard

@Test @MainActor
func lockedSpaceTabsAreNeverAIContext() async {
    let engine = StubEngine()
    let environment = BrowserEnvironment.inMemory(engine: engine)
    let model = BrowserWindowModel(environment: environment)
    let personal = model.session.activeSpaceID
    let secret = model.createGroup(named: "Secret")
    model.newTab(url: URL(string: "https://secret.example/file"))
    let secretTab = model.session.activeTabID!
    engine.liveTabs = [secretTab]
    model.switchGroup(personal)
    model.setSpaceLocked(secret, locked: true)

    // The attach menu must not even name a locked tab, and a direct capture
    // request for it is refused the same way.
    #expect(!model.tabsAvailableForAIContext().contains { $0.id == secretTab })
    let attachments = await model.captureTabsForAI([secretTab])
    #expect(attachments.isEmpty)
    #expect(engine.capturedTabs.isEmpty)
}
