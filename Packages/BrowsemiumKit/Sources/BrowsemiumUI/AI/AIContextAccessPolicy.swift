import BrowsemiumCore

enum AIContextAccessPolicy {
    static func mayCapture(_ tabID: TabID, in session: BrowserSessionState, unlocked: Set<SpaceID>) -> Bool {
        guard !session.isPrivate,
              let tab = session.tabs.first(where: { $0.id == tabID }),
              let space = session.spaces.first(where: { $0.id == tab.spaceID }) else { return false }
        return !space.isLocked || unlocked.contains(space.id)
    }
}
