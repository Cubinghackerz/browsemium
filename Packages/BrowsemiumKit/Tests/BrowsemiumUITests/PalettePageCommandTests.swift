import BrowsemiumCore
import BrowsemiumUI
import Foundation
import Testing

@Suite @MainActor
struct PalettePageCommandTests {
    @Test(arguments: [
        ("print page", "print-page", "⌘P"),
        ("find in page", "find-in-page", "⌘F"),
        ("reader mode", "reader-mode", "⇧⌘R"),
        ("hide element", "hide-element", "⇧⌘H")
    ])
    func pageActionsAreDiscoverable(query: String, id: String, shortcut: String) throws {
        let model = BrowserWindowModel(environment: .inMemory(engine: StubEngine()))
        let row = try #require(model.filteredCommands(query: query).first { $0.id == id })
        #expect(row.kind == .command)
        #expect(row.shortcut == shortcut)
        let expectedCommands: [String: BrowserCommand] = [
            "print-page": .printPage, "find-in-page": .findInPage,
            "reader-mode": .toggleReaderMode, "hide-element": .hideElement
        ]
        #expect(row.command == expectedCommands[id])
        #expect(model.paletteCommands.filter { $0.id == id }.count == 1)
        #expect(model.filteredCommands(query: "").contains { $0.id == id })
    }

    @Test
    func findActionOpensTheExistingFindBar() throws {
        let model = BrowserWindowModel(environment: .inMemory(engine: StubEngine()))
        let row = try #require(model.filteredCommands(query: "find in page").first { $0.id == "find-in-page" })
        #expect(!model.isFindBarVisible)
        model.perform(row.command)
        #expect(model.isFindBarVisible)
    }

    @Test
    func printActionTargetsOnlyTheActiveTab() throws {
        let engine = StubEngine()
        let model = BrowserWindowModel(environment: .inMemory(engine: engine))
        let activeTabID = try #require(model.session.activeTabID)
        let row = try #require(model.filteredCommands(query: "print page").first { $0.id == "print-page" })
        #expect(engine.printedTabs.isEmpty)
        model.perform(row.command)
        #expect(engine.printedTabs == [activeTabID])
    }

    @Test
    func hideActionArmsTheExistingPickerWithoutSaving() throws {
        let engine = StubEngine()
        let environment = BrowserEnvironment.inMemory(engine: engine)
        let model = BrowserWindowModel(environment: environment)
        let activeTabID = try #require(model.session.activeTabID)
        engine.liveTabs.insert(activeTabID)
        engine.emit(.committed(URL(string: "https://fixture.example/page")), for: activeTabID)
        let row = try #require(model.filteredCommands(query: "hide element").first { $0.id == "hide-element" })
        model.perform(row.command)
        #expect(model.isPickingElement)
        #expect(engine.pickingTabs == [activeTabID])
        #expect(model.cosmeticRules(for: "fixture.example").isEmpty)
    }

    @Test
    func readerActionUsesTheExistingExtractionAndFailurePath() async throws {
        let engine = StubEngine()
        let model = BrowserWindowModel(environment: .inMemory(engine: engine))
        let activeTabID = try #require(model.session.activeTabID)
        let row = try #require(model.filteredCommands(query: "reader mode").first { $0.id == "reader-mode" })
        model.perform(row.command)
        #expect(model.isReaderLoading)
        let completed = try await waitFor { !model.isReaderLoading }
        #expect(completed)
        #expect(engine.articleRequests == [activeTabID])
        #expect(!model.isReaderModeActive)
        #expect(model.statusMessage == BrowsemiumError.webContentUnavailable.localizedDescription)
    }

    @Test
    func inspectorCommandExplainsHowToEnableItWhileDeveloperToolsAreOff() throws {
        let model = BrowserWindowModel(environment: .inMemory(engine: StubEngine()))
        let row = try #require(model.paletteCommands.first { $0.id == "web-inspector" })
        #expect(row.shortcut == "⌥⌘I")

        model.perform(row.command)

        #expect(model.statusMessage?.contains("Developer tools") == true)
    }

    @Test
    func inspectorCommandReportsAnEngineThatCannotInspect() throws {
        let environment = BrowserEnvironment.inMemory(engine: StubEngine())
        var settings = environment.loadSettings()
        settings.developerToolsEnabled = true
        environment.saveSettings(settings)
        let model = BrowserWindowModel(environment: environment)

        model.perform(.showWebInspector)

        // The stub engine has no inspector, which is the same answer a
        // page without a live web view gets.
        #expect(model.statusMessage?.contains("can't be inspected") == true)
    }
}
