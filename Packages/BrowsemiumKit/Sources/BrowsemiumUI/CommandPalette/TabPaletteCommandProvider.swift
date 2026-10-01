import BrowsemiumCore

/// Value-only construction: the model supplies the current unlock snapshot.
/// Locked tab metadata is filtered before any palette row is constructed.
enum TabPaletteCommandProvider {
    static func commands(in session: BrowserSessionState, unlockedSpaceIDs: Set<SpaceID>,
                         recentLimit: Int? = nil) -> [BrowserPaletteCommand] {
        var tabs = session.tabs.filter {
            $0.id != session.activeTabID && unlockedSpaceIDs.contains($0.spaceID)
        }
        if let recentLimit {
            tabs = Array(tabs.sorted { $0.lastAccessedAt > $1.lastAccessedAt }.prefix(recentLimit))
        }
        return tabs.map { tab in
            BrowserPaletteCommand(id: "tab-\(tab.id.rawValue.uuidString)", title: tab.title,
                                  shortcut: tab.lastCommittedURL?.host ?? "", kind: .tab,
                                  subtitle: tab.lastCommittedURL?.host ?? "Open tab", command: .selectTab(tab.id))
        }
    }
}
