import BrowsemiumCore
import Foundation
import Testing

private let now = Date(timeIntervalSince1970: 2_000_000)
private let personal = BrowserSpace(name: "Personal")

private func tab(
    _ space: BrowserSpace = personal,
    idleHours: Double,
    pinned: Bool = false,
    folder: FolderID? = nil
) -> BrowserTab {
    BrowserTab(
        spaceID: space.id, title: "t", position: 0, isPinned: pinned, folderID: folder,
        lastAccessedAt: now.addingTimeInterval(-idleHours * 3_600)
    )
}

private func context(
    hours: Int = 24,
    visible: Set<TabID> = [],
    protected: Set<TabID> = [],
    tabs: [BrowserTab]
) -> TabArchivePolicy.Context {
    TabArchivePolicy.Context(
        now: now, hours: hours, visibleTabIDs: visible, protectedTabIDs: protected,
        addresses: Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, URL(string: "https://example.com/\($0.id.rawValue)")!) })
    )
}

@Test
func onlyTabsIdleLongEnoughAreArchived() {
    let fresh = tab(idleHours: 1)
    let stale = tab(idleHours: 30)
    let alsoFresh = tab(idleHours: 5)
    let tabs = [fresh, stale, alsoFresh]
    #expect(TabArchivePolicy.candidates(tabs: tabs, spaces: [personal], context: context(tabs: tabs)) == [stale.id])
    // The boundary is inclusive.
    let edge = tab(idleHours: 24)
    #expect(TabArchivePolicy.candidates(tabs: [fresh, edge], spaces: [personal], context: context(tabs: [fresh, edge])) == [edge.id])
}

@Test
func pinnedFiledVisibleAndProtectedTabsAreNeverArchived() {
    let folder = FolderID()
    let pinned = tab(idleHours: 99, pinned: true)
    let filed = tab(idleHours: 99, folder: folder)
    let visible = tab(idleHours: 99)
    let busy = tab(idleHours: 99)
    let plain = tab(idleHours: 99)
    let anchor = tab(idleHours: 0)
    let tabs = [pinned, filed, visible, busy, plain, anchor]
    let result = TabArchivePolicy.candidates(
        tabs: tabs, spaces: [personal],
        context: context(visible: [visible.id], protected: [busy.id], tabs: tabs)
    )
    #expect(result == [plain.id])
}

@Test
func lockedAndSeparateSpacesAreLeftAlone() {
    let locked = BrowserSpace(name: "Locked", isLocked: true)
    let separate = BrowserSpace(name: "Client", dataStoreID: UUID())
    let a = tab(locked, idleHours: 99), b = tab(locked, idleHours: 99)
    let c = tab(separate, idleHours: 99), d = tab(separate, idleHours: 99)
    let e = tab(idleHours: 99), f = tab(idleHours: 0)
    let tabs = [a, b, c, d, e, f]
    let result = TabArchivePolicy.candidates(tabs: tabs, spaces: [personal, locked, separate], context: context(tabs: tabs))
    #expect(result == [e.id])
}

@Test
func aSpaceAlwaysKeepsAtLeastOneTabAndTheFreshestOfTheStaleOnesStays() {
    let oldest = tab(idleHours: 300)
    let middle = tab(idleHours: 200)
    let newest = tab(idleHours: 100)
    let tabs = [newest, oldest, middle]
    let result = TabArchivePolicy.candidates(tabs: tabs, spaces: [personal], context: context(tabs: tabs))
    #expect(result == [oldest.id, middle.id])
    #expect(!result.contains(newest.id))

    let only = tab(idleHours: 999)
    #expect(TabArchivePolicy.candidates(tabs: [only], spaces: [personal], context: context(tabs: [only])).isEmpty)
}

@Test
func tabsWithoutAWebAddressAreNotArchived() {
    let blank = tab(idleHours: 99)
    let other = tab(idleHours: 99)
    let anchor = tab(idleHours: 0)
    var ctx = context(tabs: [blank, other, anchor])
    ctx.addresses[blank.id] = nil
    ctx.addresses[other.id] = URL(string: "file:///tmp/x")
    #expect(TabArchivePolicy.candidates(tabs: [blank, other, anchor], spaces: [personal], context: ctx).isEmpty)
}

@Test
func zeroHoursMeansOff() {
    let stale = tab(idleHours: 99)
    let anchor = tab(idleHours: 0)
    #expect(TabArchivePolicy.candidates(tabs: [stale, anchor], spaces: [personal], context: context(hours: 0, tabs: [stale, anchor])).isEmpty)
}
