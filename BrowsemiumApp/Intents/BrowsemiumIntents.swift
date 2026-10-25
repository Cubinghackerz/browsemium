import AppIntents
import AppKit
import BrowsemiumCore
import BrowsemiumUI
import Foundation

/// Shortcuts actions. They go through the same two doors as everything else
/// that automates Browsemium: `AppURLCommand` for navigation (so an action
/// can only open, search or switch space) and `AppAutomation` for reads
/// (titles and addresses, never page text; never private windows or locked
/// spaces). There is no action that asks an AI, grants an agent access or
/// changes settings.

struct AutomationIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

@MainActor
private func send(_ command: AppURLCommand) throws {
    let link = command.url
    if case .failure(let error) = AppURLCommand.parse(link) {
        throw AutomationIntentError(message: error.message)
    }
    if let model = LiveWindowIndex.shared.activeModel {
        model.performURLCommand(link)
    } else {
        // No window yet (the app was just launched): the scheme handler
        // opens one and runs the same command.
        NSWorkspace.shared.open(link)
    }
}

// MARK: - Entities

struct SpaceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Space"
    static let defaultQuery = SpaceEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct SpaceEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [SpaceEntity] {
        AppAutomation.spaces().filter { identifiers.contains($0.id) }.map { SpaceEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [SpaceEntity] {
        AppAutomation.spaces().map { SpaceEntity(id: $0.id, name: $0.name) }
    }
}

struct TabEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tab"
    static let defaultQuery = TabEntityQuery()

    var id: String
    var title: String
    var url: URL?
    var spaceName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(url?.host ?? spaceName)")
    }

    init(_ tab: AutomationTab) {
        id = tab.id
        title = tab.title
        url = tab.url
        spaceName = tab.spaceName
    }
}

struct TabEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [TabEntity] {
        AppAutomation.openTabs().filter { identifiers.contains($0.id) }.map(TabEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [TabEntity] {
        AppAutomation.openTabs().map(TabEntity.init)
    }
}

// MARK: - Actions that navigate

struct OpenInBrowsemiumIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Page in Browsemium"
    static let description = IntentDescription("Opens a web address in a new Browsemium tab.")

    @Parameter(title: "Web Address")
    var url: URL

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$url) in Browsemium")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try send(.open(url))
        return .result()
    }
}

struct SearchInBrowsemiumIntent: AppIntent {
    static let title: LocalizedStringResource = "Search in Browsemium"
    static let description = IntentDescription("Searches the web with your chosen search engine in a new tab.")

    @Parameter(title: "Search For")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search for \(\.$query) in Browsemium")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try send(.search(query))
        return .result()
    }
}

struct SwitchSpaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Space in Browsemium"
    static let description = IntentDescription("Switches to a space. A locked space still asks for Touch ID or your password.")

    @Parameter(title: "Space")
    var space: SpaceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Switch to \(\.$space) in Browsemium")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try send(.switchSpace(name: space.name))
        return .result()
    }
}

// MARK: - Actions that read

struct ListOpenTabsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Open Tabs from Browsemium"
    static let description = IntentDescription(
        "Returns the title and address of each open tab. Private windows and locked spaces are left out, and no page text is returned."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[TabEntity]> {
        .result(value: AppAutomation.openTabs().map(TabEntity.init))
    }
}

struct GetCurrentPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Current Page from Browsemium"
    static let description = IntentDescription(
        "Returns the title and address of the page in the front window. Nothing is returned for a private window."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TabEntity?> {
        .result(value: AppAutomation.currentPage().map(TabEntity.init))
    }
}
