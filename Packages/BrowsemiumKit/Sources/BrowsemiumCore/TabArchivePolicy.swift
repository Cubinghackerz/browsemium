import Foundation

/// Which tabs may be put away because nobody has touched them. The rules err
/// toward leaving tabs alone: the cost of archiving too little is a long tab
/// strip, the cost of archiving the wrong tab is lost work.
public enum TabArchivePolicy {
    public static let allowedHours = [12, 24, 24 * 7, 24 * 30]

    public struct Context: Sendable {
        public var now: Date
        public var hours: Int
        /// Tabs on screen in any pane: never archived.
        public var visibleTabIDs: Set<TabID>
        /// Tabs that protect themselves: audible, capturing, downloading or
        /// kept awake by choice.
        public var protectedTabIDs: Set<TabID>
        /// The address each tab would reopen to.
        public var addresses: [TabID: URL]

        public init(now: Date, hours: Int, visibleTabIDs: Set<TabID>, protectedTabIDs: Set<TabID>, addresses: [TabID: URL]) {
            self.now = now
            self.hours = hours
            self.visibleTabIDs = visibleTabIDs
            self.protectedTabIDs = protectedTabIDs
            self.addresses = addresses
        }
    }

    public static func candidates(
        tabs: [BrowserTab],
        spaces: [BrowserSpace],
        context: Context
    ) -> [TabID] {
        guard context.hours > 0 else { return [] }
        let cutoff = context.now.addingTimeInterval(-TimeInterval(context.hours) * 3_600)
        let eligibleSpaces = Set(spaces.filter { !$0.isLocked && !$0.hasSeparateData }.map(\.id))
        var remainingInSpace = Dictionary(grouping: tabs, by: \.spaceID).mapValues(\.count)
        var result: [TabID] = []
        // Oldest first, so when a space is nearly all stale the freshest of
        // them is the one that stays.
        for tab in tabs.sorted(by: { $0.lastAccessedAt < $1.lastAccessedAt }) {
            guard eligibleSpaces.contains(tab.spaceID),
                  !tab.isPinned,
                  tab.folderID == nil,
                  !context.visibleTabIDs.contains(tab.id),
                  !context.protectedTabIDs.contains(tab.id),
                  tab.lastAccessedAt <= cutoff,
                  let url = context.addresses[tab.id],
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  (remainingInSpace[tab.spaceID] ?? 0) > 1 else { continue }
            remainingInSpace[tab.spaceID, default: 0] -= 1
            result.append(tab.id)
        }
        return result
    }
}
