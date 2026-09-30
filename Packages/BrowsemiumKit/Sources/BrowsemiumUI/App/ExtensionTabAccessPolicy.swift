import BrowsemiumCore

enum ExtensionTabAccessPolicy {
    static func readableSpaceIDs(in session: BrowserSessionState, unlocked: Set<SpaceID>) -> Set<SpaceID> {
        guard !session.isPrivate else { return [] }
        return Set(session.spaces.filter { !$0.isLocked || unlocked.contains($0.id) }.map(\.id))
    }

    static func tabIDs(in session: BrowserSessionState, unlocked: Set<SpaceID>) -> Set<TabID> {
        let spaces = readableSpaceIDs(in: session, unlocked: unlocked)
        return Set(session.tabs.filter { spaces.contains($0.spaceID) }.map(\.id))
    }
}
