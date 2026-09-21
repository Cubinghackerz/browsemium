import BrowsemiumCore
import Foundation

public struct TabSleepSignals: Sendable, Hashable {
    public var isAudible: Bool
    public var isCapturingMedia: Bool
    public var hasActiveDownload: Bool
    public var isKeepAwake: Bool

    public init(
        isAudible: Bool = false,
        isCapturingMedia: Bool = false,
        hasActiveDownload: Bool = false,
        isKeepAwake: Bool = false
    ) {
        self.isAudible = isAudible
        self.isCapturingMedia = isCapturingMedia
        self.hasActiveDownload = hasActiveDownload
        self.isKeepAwake = isKeepAwake
    }

    public var protectsFromSleep: Bool {
        isAudible || isCapturingMedia || hasActiveDownload || isKeepAwake
    }
}

public struct TabSleepPolicy: Sendable {
    public var idleInterval: TimeInterval
    public var maximumLiveTabs: Int

    public init(idleInterval: TimeInterval = 300, maximumLiveTabs: Int = 4) {
        self.idleInterval = idleInterval
        self.maximumLiveTabs = maximumLiveTabs
    }

    public func hibernationCandidates(
        tabs: [BrowserTab],
        activeTabIDs: Set<TabID>,
        signals: [TabID: TabSleepSignals],
        now: Date = Date()
    ) -> [TabID] {
        let eligible = tabs.filter { tab in
            guard tab.lifecycle == .active || tab.lifecycle == .suspended else { return false }
            if activeTabIDs.contains(tab.id) { return false }
            if signals[tab.id]?.protectsFromSleep == true { return false }
            return now.timeIntervalSince(tab.lastAccessedAt) >= idleInterval
        }

        return eligible
            .sorted { $0.lastAccessedAt < $1.lastAccessedAt }
            .map(\.id)
    }

    public func excessLiveTabs(
        tabs: [BrowserTab],
        activeTabIDs: Set<TabID>,
        signals: [TabID: TabSleepSignals]
    ) -> [TabID] {
        let live = tabs.filter { tab in
            guard tab.lifecycle == .active || tab.lifecycle == .loading else { return false }
            if activeTabIDs.contains(tab.id) { return false }
            if signals[tab.id]?.protectsFromSleep == true { return false }
            return true
        }
        let overflow = live.count - max(0, maximumLiveTabs - activeTabIDs.count)
        guard overflow > 0 else { return [] }
        return live
            .sorted { $0.lastAccessedAt < $1.lastAccessedAt }
            .prefix(overflow)
            .map(\.id)
    }
}
