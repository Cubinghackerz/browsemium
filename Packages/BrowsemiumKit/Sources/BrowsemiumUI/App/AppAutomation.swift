import BrowsemiumCore
import Foundation

/// A tab as an outside automation (a Shortcuts action, a script) may see it:
/// title, address and space, nothing about its contents.
public struct AutomationTab: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let url: URL?
    public let spaceName: String
    public let isActive: Bool
}

public struct AutomationSpace: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let isLocked: Bool
}

/// The read side of the automation surface. It is deliberately narrow:
/// private windows and locked spaces never appear, addresses lose their
/// credentials and fragment, and nothing here returns page text.
@MainActor
public enum AppAutomation {
    /// Tabs in ordinary windows. A locked space's tabs are listed only after
    /// the person unlocked it in that window this run (the same rule the
    /// command palette uses).
    public static func openTabs(registry: LiveWindowIndex = .shared) -> [AutomationTab] {
        registry.models.filter { !$0.session.isPrivate }.flatMap { model in
            let unlocked = Set(model.session.spaces.filter { model.isSpaceUnlocked($0.id) }.map(\.id))
            return model.session.tabs
                .filter { unlocked.contains($0.spaceID) }
                .map { tab in
                    AutomationTab(
                        id: tab.id.rawValue.uuidString,
                        title: tab.title.isEmpty ? (tab.lastCommittedURL?.host ?? "New Tab") : tab.title,
                        url: sanitized(model.tabURLs[tab.id] ?? tab.lastCommittedURL),
                        spaceName: model.session.spaces.first { $0.id == tab.spaceID }?.name ?? "",
                        isActive: tab.id == model.session.activeTabID
                    )
                }
        }
    }

    /// The page in the active ordinary window, or nil when there is none
    /// (no window, a private window, or a page that has not loaded).
    public static func currentPage(registry: LiveWindowIndex = .shared) -> AutomationTab? {
        guard let model = registry.activeModel, !model.session.isPrivate,
              let tabID = model.session.activeTabID,
              model.isSpaceUnlocked(model.session.activeSpaceID) else { return nil }
        return openTabs(registry: registry).first { $0.id == tabID.rawValue.uuidString }
    }

    /// Spaces in the active ordinary window. Locked ones are listed (the
    /// name is not secret) and flagged; switching to one still asks for
    /// Touch ID.
    public static func spaces(registry: LiveWindowIndex = .shared) -> [AutomationSpace] {
        guard let model = registry.activeModel, !model.session.isPrivate else { return [] }
        return model.session.spaces.map {
            AutomationSpace(id: $0.id.rawValue.uuidString, name: $0.name, isLocked: $0.isLocked)
        }
    }

    /// An address with credentials and fragment removed.
    static func sanitized(_ url: URL?) -> URL? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.user = nil
        components.password = nil
        components.fragment = nil
        return components.url
    }
}
