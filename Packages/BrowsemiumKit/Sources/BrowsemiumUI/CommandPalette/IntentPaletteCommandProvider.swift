import BrowsemiumCore
import BrowsemiumEngine
import Foundation

enum IntentPaletteCommandProvider {
    /// Matches address-bar resolution and keeps the user's raw search query.
    static func primary(for query: String, searchTemplate: String, searchEngineName: String) -> BrowserPaletteCommand? {
        let template = URL(string: searchTemplate) ?? URL(string: SearchEnginePreset.google.template)!
        guard let request = try? NavigationResolver(searchURL: template).resolve(query) else { return nil }
        let looksLikeURL = query.contains("://") || (query.contains(".") && !query.contains(" "))
        if looksLikeURL {
            return BrowserPaletteCommand(id: "open-url", title: "Open \(request.url.absoluteString)", shortcut: "↵",
                                         kind: .action, subtitle: "Open in a new tab", command: .openURLInNewTab(request.url))
        }
        return BrowserPaletteCommand(id: "search", title: "Search for “\(query)”", shortcut: "↵", kind: .action,
                                     subtitle: "with \(searchEngineName)", command: .searchFor(query))
    }

    /// Explicit space, folder, and split actions. Existing destination-space
    /// authorization remains in dispatch, not in the row constructor.
    static func commands(in session: BrowserSessionState, activeTab: BrowserTab?,
                         activeFolders: [TabFolder], isSplitViewActive: Bool) -> [BrowserPaletteCommand] {
        var intents: [BrowserPaletteCommand] = []
        for space in session.spaces where space.id != session.activeSpaceID {
            intents.append(BrowserPaletteCommand(id: "switch-space-\(space.id.rawValue.uuidString)",
                title: "Switch to Space: \(space.name)", shortcut: "", kind: .action,
                subtitle: "Show this space's tabs", command: .switchSpace(space.id)))
        }
        if let activeTab {
            for space in session.spaces where space.id != activeTab.spaceID {
                intents.append(BrowserPaletteCommand(id: "move-to-space-\(space.id.rawValue.uuidString)",
                    title: "Move “\(activeTab.title)” to Space: \(space.name)", shortcut: "", kind: .action,
                    subtitle: "Move the active tab", command: .moveTabToSpace(activeTab.id, space.id)))
            }
            for folder in activeFolders where folder.id != activeTab.folderID {
                intents.append(BrowserPaletteCommand(id: "move-to-folder-\(folder.id.rawValue.uuidString)",
                    title: "Move “\(activeTab.title)” to Folder: \(folder.name)", shortcut: "", kind: .action,
                    subtitle: "Move the active tab", command: .assignTabToFolder(activeTab.id, folder.id)))
            }
            if activeTab.folderID != nil {
                intents.append(BrowserPaletteCommand(id: "leave-folder", title: "Remove “\(activeTab.title)” from its Folder",
                    shortcut: "", kind: .action, subtitle: "Move the active tab", command: .assignTabToFolder(activeTab.id, nil)))
            }
        }
        if isSplitViewActive {
            intents.append(BrowserPaletteCommand(id: "close-split", title: "Close Split View", shortcut: "⇧⌘D",
                                                 kind: .action, subtitle: "Keep the tabs open", command: .toggleSplitView))
        } else {
            for tab in session.tabs where tab.spaceID == session.activeSpaceID && tab.id != session.activeTabID {
                intents.append(BrowserPaletteCommand(id: "split-with-\(tab.id.rawValue.uuidString)",
                    title: "Open “\(tab.title)” in Split View", shortcut: "", kind: .action,
                    subtitle: tab.lastCommittedURL?.host ?? "Split view", command: .openTabInSplit(tab.id)))
            }
        }
        return intents
    }
}
