import BrowsemiumCore
import BrowsemiumData
import BrowsemiumExtensions
import BrowsemiumUI
import Foundation
import Testing
import BrowsemiumEngineKit

@MainActor
private func makeIndexModel(engine: StubEngine = StubEngine()) -> (BrowserWindowModel, StubEngine, BrowserEnvironment) {    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-page-index-\(UUID().uuidString)", isDirectory: true)
    let environment = BrowserEnvironment.inMemory(
        engine: engine,
        extensionStore: ExtensionStore(rootDirectory: root))
    return (BrowserWindowModel(environment: environment), engine, environment)
}

@MainActor
private func enableIndex(_ model: BrowserWindowModel) {
    model.updateSettings { $0.indexPageTextOnMac = true }
}

@MainActor
private func finish(_ engine: StubEngine, _ model: BrowserWindowModel, url: String, title: String = "Fixture") {
    let tab = model.session.activeTabID!
    engine.emit(.committed(URL(string: url)!), for: tab)
    engine.emit(.finished(title: title, url: URL(string: url)!), for: tab)
}

// MARK: - Capture hook

@Test @MainActor
func finishedPagesAreIndexedWhenOptedIn() async throws {
    let (model, engine, environment) = makeIndexModel()
    enableIndex(model)

    finish(engine, model, url: "https://indexed.example/article")

    try #require(await waitFor { (try? environment.pageTextRepository.size().pages) == 1 })
    let hits = try environment.pageTextRepository.search("stub")
    #expect(hits.count == 1)
    #expect(hits.first?.url.absoluteString == "https://indexed.example/article")
}

@Test @MainActor
func indexingStaysOffByDefault() async throws {
    let (model, engine, environment) = makeIndexModel()
    #expect(model.environment.loadSettings().indexPageTextOnMac == false)

    finish(engine, model, url: "https://off.example/")

    try await Task.sleep(for: .milliseconds(300))
    #expect(try environment.pageTextRepository.size().pages == 0)
    #expect(engine.capturedTabs.isEmpty)
}

@Test @MainActor
func privateWindowsNeverIndex() async throws {
    let (model, engine, environment) = makeIndexModel()
    enableIndex(model)
    model.enterPrivateMode()

    finish(engine, model, url: "https://private.example/")

    try await Task.sleep(for: .milliseconds(300))
    #expect(try environment.pageTextRepository.size().pages == 0)
}

@Test @MainActor
func lockedAndSeparateDataSpacesNeverIndex() async throws {
    let (model, engine, environment) = makeIndexModel(engine: StubEngine())
    enableIndex(model)
    let personal = model.session.activeSpaceID
    let locked = model.createGroup(named: "Locked fixture")
    let separate = model.createGroup(named: "Separate fixture", separateData: true)

    // Open the hidden pages while their spaces are still ordinary, then lock
    // one: the finished events below fire after the lock, when indexing must
    // already refuse.
    model.switchGroup(locked)
    let lockedTab = model.session.activeTabID!
    _ = model.newTab(url: URL(string: "https://hidden.example/locked"))
    let lockedPage = model.session.activeTabID!
    model.switchGroup(separate)
    _ = model.newTab(url: URL(string: "https://hidden.example/separate"))
    let separatePage = model.session.activeTabID!
    model.switchGroup(personal)
    model.setSpaceLocked(locked, locked: true)
    _ = lockedTab

    for tab in [lockedPage, separatePage] {
        let url = model.tabURLs[tab] ?? model.session.tabs.first { $0.id == tab }?.lastCommittedURL
        engine.emit(.finished(title: "Hidden", url: url), for: tab)
    }
    try await Task.sleep(for: .milliseconds(300))
    #expect(try environment.pageTextRepository.size().pages == 0)
}

@Test @MainActor
func credentialedAndNonWebPagesNeverIndex() async throws {
    let (model, engine, environment) = makeIndexModel()
    enableIndex(model)
    for url in ["https://user:pass@creds.example/", "about:blank"] {
        finish(engine, model, url: url)
    }
    try await Task.sleep(for: .milliseconds(300))
    #expect(try environment.pageTextRepository.size().pages == 0)
}

@Test @MainActor
func excludedHostsAreSkippedAndPurged() async throws {
    let (model, engine, environment) = makeIndexModel()
    enableIndex(model)
    finish(engine, model, url: "https://excluded.example/a")
    try #require(await waitFor { (try? environment.pageTextRepository.size().pages) == 1 })

    model.setPageTextExcluded(true, host: "excluded.example")

    #expect(model.isPageTextExcluded(host: "excluded.example"))
    #expect(try environment.pageTextRepository.size().pages == 0)
    // New loads on excluded hosts are skipped up front.
    finish(engine, model, url: "https://excluded.example/b")
    try await Task.sleep(for: .milliseconds(300))
    #expect(try environment.pageTextRepository.size().pages == 0)
    #expect(model.excludedPageTextHosts().contains("excluded.example"))

    model.setPageTextExcluded(false, host: "excluded.example")
    #expect(!model.isPageTextExcluded(host: "excluded.example"))
}

// MARK: - Suggestions and palette

@Test @MainActor
func pageTextRowsAppearInAddressSuggestions() throws {
    let (model, _, environment) = makeIndexModel()
    enableIndex(model)
    try environment.pageTextRepository.index(
        url: URL(string: "https://suggest.example/deep")!,
        title: "Deep page", snippet: "uncommon words about gardening")
    model.addressText = "uncommon gardening"

    model.updateAddressSuggestions()

    #expect(model.addressSuggestions.contains {
        $0.kind == .pageText && $0.value == "https://suggest.example/deep"
    })
}

@Test @MainActor
func pageTextRowsStayOutWhenOffOrPrivate() throws {
    let (model, _, environment) = makeIndexModel()
    try environment.pageTextRepository.index(
        url: URL(string: "https://suggest.example/deep")!,
        title: "Deep page", snippet: "uncommon words about gardening")
    model.addressText = "uncommon gardening"

    // Indexed but opted out: no rows.
    model.updateAddressSuggestions()
    #expect(!model.addressSuggestions.contains { $0.kind == .pageText })

    // Opted in but private: no rows.
    enableIndex(model)
    model.enterPrivateMode()
    model.addressText = "uncommon gardening"
    model.updateAddressSuggestions()
    #expect(!model.addressSuggestions.contains { $0.kind == .pageText })
}

@Test @MainActor
func pageTextPaletteRowsOpenPages() throws {
    let (model, _, environment) = makeIndexModel()
    enableIndex(model)
    try environment.pageTextRepository.index(
        url: URL(string: "https://palette.example/deep")!,
        title: "Deep page", snippet: "uncommon words about gardening")

    let rows = model.filteredCommands(query: "uncommon gardening")
    let row = try #require(rows.first { $0.kind == .pageText })

    let before = model.session.tabs.count
    model.perform(row.command)
    #expect(model.session.tabs.count == before + 1)

    model.enterPrivateMode()
    #expect(!model.filteredCommands(query: "uncommon gardening").contains { $0.kind == .pageText })
}

// MARK: - Topics and settings

@Test @MainActor
func resumeTopicsNeedsTheIndexAndIgnoresExcludes() async throws {
    let (model, _, environment) = makeIndexModel()
    // Index off: nothing, even with content present.
    try environment.pageTextRepository.index(
        url: URL(string: "https://a.example/")!, title: "Swift concurrency", snippet: "swift actors")
    #expect(await model.resumeTopics().isEmpty)

    enableIndex(model)
    try environment.pageTextRepository.index(
        url: URL(string: "https://b.example/")!, title: "Swift actors", snippet: "swift tasks")
    try environment.pageTextRepository.index(
        url: URL(string: "https://c.example/")!, title: "Sourdough starter", snippet: "flour water")
    try environment.pageTextRepository.index(
        url: URL(string: "https://d.example/")!, title: "Sourdough baking", snippet: "flour oven")

    let topics = await model.resumeTopics()
    #expect(!topics.isEmpty)
    #expect(topics.count <= 3)

    // Excluding a host removes its pages even though the rows predate it.
    model.setPageTextExcluded(true, host: "a.example")
    model.setPageTextExcluded(true, host: "b.example")
    let filtered = await model.resumeTopics()
    #expect(filtered.allSatisfy { topic in
        topic.pages.allSatisfy { !["a.example", "b.example"].contains($0.url.host) }
    })

    model.enterPrivateMode()
    #expect(await model.resumeTopics().isEmpty)
}

@Test @MainActor
func openingAResumeTopicOpensItsPages() throws {
    let (model, _, _) = makeIndexModel()
    let topic = ResumeTopic(label: "Fixture", pages: [
        TopicPage(url: URL(string: "https://one.example/")!, title: "One", snippet: ""),
        TopicPage(url: URL(string: "https://two.example/")!, title: "Two", snippet: "")
    ])
    let before = model.session.tabs.count
    model.openResumeTopic(topic)
    #expect(model.session.tabs.count == before + 2)
}

@Test @MainActor
func pageIndexSizeAndClearBehave() throws {
    let (model, _, environment) = makeIndexModel()
    #expect(model.pageTextIndexSize()?.pages == 0)
    try environment.pageTextRepository.index(
        url: URL(string: "https://sized.example/")!, title: "Sized", snippet: "12345")
    #expect(model.pageTextIndexSize()?.pages == 1)
    #expect(model.pageTextIndexSize()?.bytes == 5)
    model.clearPageTextIndex()
    #expect(model.pageTextIndexSize()?.pages == 0)
    #expect(model.statusMessage == "Page index cleared.")

    model.enterPrivateMode()
    #expect(model.pageTextIndexSize() == nil)
}
