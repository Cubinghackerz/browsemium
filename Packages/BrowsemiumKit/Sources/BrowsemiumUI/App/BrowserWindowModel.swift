import AppKit
import BrowsemiumCore
import BrowsemiumData
import BrowsemiumEngine
import Foundation
import Observation
import WebKit
import BrowsemiumEngineKit

public struct BrowserPaletteCommand: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let shortcut: String
    public let command: BrowserCommand

    public init(id: String, title: String, shortcut: String, command: BrowserCommand) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
        self.command = command
    }
}

@MainActor
@Observable
public final class BrowserWindowModel: PermissionPrompting {
    public let environment: BrowserEnvironment
    public let paneID = PaneID()
    public let favicons = FaviconStore()

    /// Serial so history and session writes keep their submission order.
    private static let persistenceQueue = DispatchQueue(
        label: "com.browsemium.persistence",
        qos: .utility
    )

    public private(set) var session: BrowserSessionState
    public var addressText: String
    public var isAIDockVisible: Bool
    public var isCommandPaletteVisible: Bool
    public var activePanel: BrowserPanel
    public var statusMessage: String?
    public var isFindBarVisible: Bool
    public var findText: String
    public var findStatus: String?
    public var isLoading: Bool
    public var loadingProgress: Double
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var isBookmarked: Bool
    public var focusAddressToken: Int
    public var appearance: AppearancePreference
    public private(set) var tabURLs: [TabID: URL]
    /// The link the pointer is over in the active tab, shown in the status
    /// bar. Reported by the page's injected hover monitor.
    public private(set) var hoveredLinkURL: URL?
    /// Tabs that are currently playing audio or have been muted. WebKit does
    /// not expose this, so it comes from the injected page monitor.
    public private(set) var tabAudio: [TabID: TabAudioState] = [:]
    /// Tabs the user marked "keep loaded" from the tab menu. The memory saver
    /// leaves these alone until they are closed or the mark is removed.
    public private(set) var keepAwakeTabIDs: Set<TabID> = []
    public private(set) var bookmarks: [Bookmark] = []
    public private(set) var savedCredentials: [SavedCredential] = []
    public private(set) var downloads: [DownloadProgress] = []
    private var bookmarkedURLs: Set<String> = []
    public var isBookmarksBarVisible: Bool = true

    /// Extra windows are ephemeral: only the first window writes the session,
    /// so two windows cannot clobber each other's saved tabs.
    public var persistsSession = true

    /// Registrations handed back by the runtime. Every window registers its
    /// own, so one window closing cannot silence another.
    private var runtimeObserverTokens: [UUID] = []
    private var downloadObserverToken: UUID?
    private var permissionQueue: [PermissionRequest] = []
    private var permissionContinuations: [UUID: CheckedContinuation<SitePermissionDecision, Never>] = [:]

    /// Window-scoped consumers, such as the AI dock, can release their own
    /// heavyweight WebViews when the runtime receives memory pressure.
    public var memoryPressureHandler: (@MainActor (MemoryPressureLevel) -> Void)?

    /// Whether post-first-frame startup work already ran for this window.
    private var didRunDeferredStartup = false

    /// Increments whenever the active profile changes. Views use it to
    /// release profile-scoped web content, like AI provider panels.
    public private(set) var profileSwitchToken = 0

    public let paletteCommands: [BrowserPaletteCommand] = [
        BrowserPaletteCommand(id: "new-tab", title: "New Tab", shortcut: "⌘T", command: .newTab),
        BrowserPaletteCommand(id: "close-tab", title: "Close Tab", shortcut: "⌘W", command: .closeTab(TabID())),
        BrowserPaletteCommand(id: "reload", title: "Reload Page", shortcut: "⌘R", command: .reload),
        BrowserPaletteCommand(id: "reopen", title: "Reopen Closed Tab", shortcut: "⇧⌘T", command: .reopenClosedTab),
        BrowserPaletteCommand(id: "bookmark", title: "Bookmark This Page", shortcut: "⌘D", command: .toggleBookmark),
        BrowserPaletteCommand(id: "history", title: "Open History", shortcut: "⌘Y", command: .openHistory),
        BrowserPaletteCommand(id: "bookmarks", title: "Open Bookmarks", shortcut: "⌥⌘B", command: .openBookmarks),
        BrowserPaletteCommand(id: "downloads", title: "Open Downloads", shortcut: "⇧⌘J", command: .openDownloads),
        BrowserPaletteCommand(id: "settings", title: "Open Settings", shortcut: "⌘,", command: .openSettings),
        BrowserPaletteCommand(id: "toggle-ai", title: "Toggle Assistant", shortcut: "⇧⌘A", command: .toggleAIDock),
        BrowserPaletteCommand(id: "ai-summarize", title: "AI: Summarize This Page", shortcut: "", command: .aiQuickAction(.summarizePage)),
        BrowserPaletteCommand(id: "ai-keypoints", title: "AI: Extract Key Points", shortcut: "", command: .aiQuickAction(.keyPoints)),
        BrowserPaletteCommand(id: "ai-explain", title: "AI: Explain Selection", shortcut: "", command: .aiQuickAction(.explainSelection)),
        BrowserPaletteCommand(id: "zoom-in", title: "Zoom In", shortcut: "⌘+", command: .zoomIn),
        BrowserPaletteCommand(id: "zoom-out", title: "Zoom Out", shortcut: "⌘-", command: .zoomOut),
        BrowserPaletteCommand(id: "zoom-reset", title: "Reset Zoom", shortcut: "⌘0", command: .resetZoom),
        BrowserPaletteCommand(id: "save-pdf", title: "Save Page as PDF", shortcut: "", command: .savePageAsPDF),
        BrowserPaletteCommand(id: "save-screenshot", title: "Save Page Screenshot", shortcut: "", command: .savePageScreenshot),
        BrowserPaletteCommand(id: "pip", title: "Picture in Picture", shortcut: "", command: .togglePictureInPicture),
        BrowserPaletteCommand(id: "clear-data", title: "Clear Browsing Data", shortcut: "", command: .clearBrowsingData)
    ]

    public init(environment: BrowserEnvironment = BrowserEnvironment.inMemory()) {
        self.environment = environment
        let storedSettings = environment.loadSettings()
        let initialSession: BrowserSessionState
        if let restored = try? environment.sessionRepository.load() {
            initialSession = restored
        } else {
            let space = BrowserSpace(name: "Personal")
            let tab = BrowserTab(spaceID: space.id, title: "New Tab", position: 0)
            initialSession = BrowserSessionState(
                spaces: [space],
                tabs: [tab],
                activeSpaceID: space.id,
                activeTabID: tab.id
            )
        }
        session = initialSession
        addressText = initialSession.tabs.first { $0.id == initialSession.activeTabID }?.lastCommittedURL?.absoluteString ?? ""
        isAIDockVisible = storedSettings.isAIDockEnabled
        isCommandPaletteVisible = false
        activePanel = .none
        statusMessage = nil
        isFindBarVisible = false
        findText = ""
        findStatus = nil
        isLoading = false
        loadingProgress = 0
        canGoBack = false
        canGoForward = false
        isBookmarked = false
        focusAddressToken = 0
        appearance = storedSettings.appearance
        tabURLs = Dictionary(uniqueKeysWithValues: initialSession.tabs.compactMap { tab in
            tab.lastCommittedURL.map { (tab.id, $0) }
        })
        isBookmarksBarVisible = UserDefaults.standard.object(forKey: "browsemium.bookmarksBarVisible") as? Bool ?? true

        startObservingRuntime()
        environment.engine.beginMemoryPressureMonitoring { [weak self] level in
            guard let self else { return }
            self.memoryPressureHandler?(level)
            switch level {
            case .warning:
                self.applySleepPolicy()
            case .critical:
                self.environment.engine.hibernateInactiveTabs()
                self.statusMessage = "Inactive tabs were unloaded to reduce memory use"
            }
        }
        environment.engine.apply(storedSettings)
        applyAppearanceToApp()
        LaunchMetrics.mark(.modelReady)
    }

    /// Work that must happen early but not on the path to the first frame:
    /// database maintenance and the bookmark/credential/permission reads that
    /// fill the UI. Called from the window's onAppear so launch time is
    /// measured and the window is not held up by SQLite.
    public func performDeferredStartup() {
        guard !didRunDeferredStartup else { return }
        didRunDeferredStartup = true
        environment.runMaintenance()
        refreshBookmarks()
        refreshSavedCredentials()
        refreshSitePermissions()
        persistSession()
        LaunchMetrics.mark(.idle)
    }

    public var activeTab: BrowserTab? {
        guard let activeTabID = session.activeTabID else { return nil }
        return session.tabs.first { $0.id == activeTabID }
    }

    public var liveWebViewCount: Int {
        environment.engine.liveTabCount
    }

    /// One row in the address-bar suggestion list.
    public struct AddressSuggestion: Identifiable, Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case history
            case bookmark
            case search
        }

        public let id: String
        public let kind: Kind
        public let title: String
        public let subtitle: String
        /// What pressing Return does.
        public let value: String
    }

    public private(set) var addressSuggestions: [AddressSuggestion] = []
    public var highlightedSuggestion: Int = 0
    public var isAddressFocused: Bool = false

    /// Whether the dropdown should be on screen.
    public var isShowingAddressSuggestions: Bool {
        isAddressFocused && !addressSuggestions.isEmpty
    }

    /// Local-only suggestions: your own history and bookmarks, plus a search
    /// row. Nothing is sent anywhere to build this list.
    public func updateAddressSuggestions() {
        let query = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isAddressShowingCurrentPage else {
            addressSuggestions = []
            return
        }
        // A typed URL is not a search.
        if query.contains("://") || (query.contains(".") && !query.contains(" ")) {
            addressSuggestions = []
            return
        }

        var seen = Set<String>()
        var suggestions: [AddressSuggestion] = []

        let visits = (try? environment.historyRepository.search(query, limit: 12)) ?? []
        for visit in visits {
            let key = visit.url.absoluteString
            guard seen.insert(key).inserted else { continue }
            suggestions.append(
                AddressSuggestion(
                    id: "history-\(key)",
                    kind: .history,
                    title: visit.title.isEmpty ? (visit.url.host ?? key) : visit.title,
                    subtitle: visit.url.host ?? key,
                    value: key
                )
            )
        }

        for bookmark in bookmarks where matches(bookmark, query: query) {
            let key = bookmark.url.absoluteString
            guard seen.insert(key).inserted else { continue }
            suggestions.append(
                AddressSuggestion(
                    id: "bookmark-\(key)",
                    kind: .bookmark,
                    title: bookmark.title.isEmpty ? (bookmark.url.host ?? key) : bookmark.title,
                    subtitle: bookmark.url.host ?? key,
                    value: key
                )
            )
        }

        suggestions.append(
            AddressSuggestion(
                id: "search-\(query)",
                kind: .search,
                title: "Search for “\(query)”",
                subtitle: "with \(activeSearchEngineName)",
                value: query
            )
        )

        addressSuggestions = Array(suggestions.prefix(8))
        highlightedSuggestion = 0
    }

    private func matches(_ bookmark: Bookmark, query: String) -> Bool {
        bookmark.title.localizedCaseInsensitiveContains(query)
            || bookmark.url.absoluteString.localizedCaseInsensitiveContains(query)
    }

    /// True while the field still shows the page you are on, so opening the
    /// address bar does not immediately offer suggestions for it.
    private var isAddressShowingCurrentPage: Bool {
        guard let tabID = session.activeTabID, let current = tabURLs[tabID] else { return false }
        return addressText == current.absoluteString
    }

    public func dismissAddressSuggestions() {
        addressSuggestions = []
        highlightedSuggestion = 0
    }

    public func moveSuggestionSelection(by offset: Int) {
        guard !addressSuggestions.isEmpty else { return }
        let count = addressSuggestions.count
        highlightedSuggestion = ((highlightedSuggestion + offset) % count + count) % count
    }

    /// Runs the highlighted suggestion, or the raw text when none is shown.
    public func acceptHighlightedSuggestion() {
        guard addressSuggestions.indices.contains(highlightedSuggestion) else {
            submitAddress()
            return
        }
        acceptSuggestion(addressSuggestions[highlightedSuggestion])
    }

    public func acceptSuggestion(_ suggestion: AddressSuggestion) {
        addressSuggestions = []
        switch suggestion.kind {
        case .history, .bookmark:
            addressText = suggestion.value
            submitAddress()
        case .search:
            addressText = suggestion.value
            submitAddress()
        }
    }

    public var activeDownloads: [DownloadProgress] {
        downloads.filter { !$0.isFinished && $0.failureMessage == nil }
    }

    public var hasActiveDownloads: Bool {
        !activeDownloads.isEmpty
    }

    /// Progress of the most recent in-flight download, for the toolbar ring.
    public var downloadProgressFraction: Double? {
        activeDownloads.first?.fraction
    }

    /// Reload only makes sense once a page exists to reload.
    public var canReload: Bool {
        isLoading || activeTab?.lastCommittedURL != nil
    }

    public var sleepingTabCount: Int {
        session.tabs.filter { $0.lifecycle == .hibernated || $0.lifecycle == .suspended }.count
    }

    /// Only reports figures that can be verified: whether this tab holds a
    /// live web view, and the app's measured footprint with its scope stated.
    public func tabStats(for tab: BrowserTab) -> TabStats {
        TabStats(
            isLive: environment.engine.isLive(tabID: tab.id),
            lifecycle: tab.lifecycle,
            liveTabs: liveWebViewCount,
            sleepingTabs: sleepingTabCount,
            footprint: memorySummary.formatted,
            footprintScope: memoryScopeDescription
        )
    }

    /// Live download state for the toolbar indicator. Derived from the same
    /// updates that are written to the downloads database, so the two can
    /// never disagree.
    public struct DownloadProgress: Identifiable, Sendable, Hashable {
        public let id: UUID
        public let filename: String
        public let bytesReceived: Int64
        public let totalBytes: Int64
        public let isFinished: Bool
        public let failureMessage: String?

        public init(
            id: UUID,
            filename: String,
            bytesReceived: Int64,
            totalBytes: Int64,
            isFinished: Bool,
            failureMessage: String?
        ) {
            self.id = id
            self.filename = filename
            self.bytesReceived = bytesReceived
            self.totalBytes = totalBytes
            self.isFinished = isFinished
            self.failureMessage = failureMessage
        }

        public var fraction: Double? {
            guard totalBytes > 0 else { return nil }
            return min(max(Double(bytesReceived) / Double(totalBytes), 0), 1)
        }

        public var percentText: String {
            guard let fraction else { return "Starting…" }
            return "\(Int(fraction * 100))%"
        }
    }

    public struct TabStats: Sendable {
        public let isLive: Bool
        public let lifecycle: TabLifecycle
        public let liveTabs: Int
        public let sleepingTabs: Int
        public let footprint: String
        public let footprintScope: String
    }

    @discardableResult
    public func newTab(url: URL? = nil) -> TabID {
        let tab = BrowserTab(
            spaceID: session.activeSpaceID,
            title: url == nil ? "New Tab" : (url?.host ?? "Loading"),
            lastCommittedURL: url,
            position: session.tabs.count
        )
        session = BrowserSessionState(
            spaces: session.spaces,
            tabs: session.tabs + [tab],
            activeSpaceID: session.activeSpaceID,
            activeTabID: tab.id,
            isPrivate: session.isPrivate
        )
        activePanel = .none
        addressText = url?.absoluteString ?? ""
        if let url {
            tabURLs[tab.id] = url
            Task { try? await environment.engine.navigate(tabID: tab.id, to: NavigationRequest(url: url)) }
        }
        refreshNavigationState()
        persistSession()
        return tab.id
    }

    public func closeTab(_ tabID: TabID? = nil) {
        let targetID = tabID ?? session.activeTabID
        guard let targetID, let tab = session.tabs.first(where: { $0.id == targetID }) else { return }

        if !session.isPrivate {
            try? environment.closedTabRepository.record(tab)
        }
        environment.engine.discard(tabID: targetID)
        tabURLs[targetID] = nil
        tabAudio[targetID] = nil
        keepAwakeTabIDs.remove(targetID)

        let closedIndex = session.tabs.filter { $0.spaceID == tab.spaceID }.firstIndex { $0.id == targetID } ?? 0
        var tabs = session.tabs.filter { $0.id != targetID }
        var remainingInGroup = tabs.filter { $0.spaceID == tab.spaceID }
        if remainingInGroup.isEmpty {
            let replacement = BrowserTab(spaceID: tab.spaceID, title: "New Tab")
            tabs.append(replacement)
            remainingInGroup = [replacement]
        }
        // Activate the tab that slid into the closed tab's place, falling back
        // to the one before it — the same behaviour as Chrome and Safari.
        let neighbourIndex = min(closedIndex, remainingInGroup.count - 1)
        let nextActiveID = session.activeTabID == targetID ? remainingInGroup[neighbourIndex].id : session.activeTabID
        session = BrowserSessionState(
            spaces: session.spaces,
            tabs: tabs,
            activeSpaceID: session.activeSpaceID,
            activeTabID: nextActiveID,
            isPrivate: session.isPrivate
        )
        addressText = activeTab?.lastCommittedURL?.absoluteString ?? ""
        refreshNavigationState()
        persistSession()
    }

    public func selectTab(_ tabID: TabID) {
        guard session.tabs.contains(where: { $0.id == tabID }) else { return }
        let tabs = session.tabs.map { tab in
            guard tab.id == tabID else { return tab }
            return BrowserTab(
                id: tab.id,
                spaceID: tab.spaceID,
                title: tab.title,
                lastCommittedURL: tab.lastCommittedURL,
                position: tab.position,
                isPinned: tab.isPinned,
                lifecycle: tab.lifecycle,
                createdAt: tab.createdAt,
                lastAccessedAt: Date()
            )
        }
        session = BrowserSessionState(
            spaces: session.spaces,
            tabs: tabs,
            activeSpaceID: session.activeSpaceID,
            activeTabID: tabID,
            isPrivate: session.isPrivate
        )
        activePanel = .none
        readerArticle = nil
        hoveredLinkURL = nil
        addressText = tabURLs[tabID]?.absoluteString ?? activeTab?.lastCommittedURL?.absoluteString ?? ""
        refreshNavigationState()
        persistSession()
        Task { await environment.engine.activate(tabID: tabID, in: paneID) }
    }

    /// A tab in the current space already pointing at this URL, compared
    /// loosely so a trailing slash or scheme case does not defeat the match.
    private func duplicateTab(of url: URL, excluding tabID: TabID) -> TabID? {
        let target = Self.normalizedForDuplicateCheck(url)
        return session.tabs.first { tab in
            tab.id != tabID
                && tab.spaceID == session.activeSpaceID
                && (tabURLs[tab.id] ?? tab.lastCommittedURL).map(Self.normalizedForDuplicateCheck) == target
        }?.id
    }

    private static func normalizedForDuplicateCheck(_ url: URL) -> String {
        var normalized = url.absoluteString
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            // Scheme and host are case-insensitive; the path is not.
            if let scheme = components.scheme { components.scheme = scheme.lowercased() }
            if let host = components.host { components.host = host.lowercased() }
            normalized = components.string ?? normalized
        }
        if normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized
    }

    public func moveTab(_ sourceID: TabID, before targetID: TabID) {
        guard sourceID != targetID else { return }
        let group = session.activeSpaceID
        var groupTabs = session.tabs.filter { $0.spaceID == group }
        guard let sourceIndex = groupTabs.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = groupTabs.firstIndex(where: { $0.id == targetID }) else { return }
        let moved = groupTabs.remove(at: sourceIndex)
        let insertionIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        groupTabs.insert(moved, at: insertionIndex)
        // Splice the reordered group back into the global tab list, leaving
        // other groups' tabs untouched.
        var iterator = groupTabs.makeIterator()
        var tabs = session.tabs.map { tab in
            tab.spaceID == group ? (iterator.next() ?? tab) : tab
        }
        tabs = tabs.enumerated().map { position, tab in
            BrowserTab(
                id: tab.id,
                spaceID: tab.spaceID,
                title: tab.title,
                lastCommittedURL: tab.lastCommittedURL,
                position: position,
                isPinned: tab.isPinned,
                lifecycle: tab.lifecycle,
                createdAt: tab.createdAt,
                lastAccessedAt: tab.lastAccessedAt
            )
        }
        session = BrowserSessionState(
            spaces: session.spaces,
            tabs: tabs,
            activeSpaceID: session.activeSpaceID,
            activeTabID: session.activeTabID,
            isPrivate: session.isPrivate
        )
        persistSession()
    }

    public func togglePin(_ tabID: TabID) {
        updateTab(tabID) { tab in
            BrowserTab(
                id: tab.id,
                spaceID: tab.spaceID,
                title: tab.title,
                lastCommittedURL: tab.lastCommittedURL,
                position: tab.position,
                isPinned: !tab.isPinned,
                lifecycle: tab.lifecycle,
                createdAt: tab.createdAt,
                lastAccessedAt: tab.lastAccessedAt
            )
        }
        persistSession()
    }

    // MARK: - Tab groups

    /// Tabs in the active group, in strip order.
    public var visibleTabs: [BrowserTab] {
        session.tabs.filter { $0.spaceID == session.activeSpaceID }
    }

    public var activeGroup: BrowserSpace? {
        session.spaces.first { $0.id == session.activeSpaceID }
    }

    @discardableResult
    public func createGroup(named name: String, color: String? = nil) -> SpaceID {
        let palette = ["#5B8DEF", "#8F6BE8", "#E8734A", "#3FA46A", "#D9A93B", "#C8557F"]
        let space = BrowserSpace(
            name: name,
            color: color ?? palette[session.spaces.count % palette.count]
        )
        let tab = BrowserTab(spaceID: space.id, title: "New Tab", position: session.tabs.count)
        session = BrowserSessionState(
            spaces: session.spaces + [space],
            tabs: session.tabs + [tab],
            activeSpaceID: space.id,
            activeTabID: tab.id,
            isPrivate: session.isPrivate
        )
        activePanel = .none
        addressText = ""
        refreshNavigationState()
        persistSession()
        statusMessage = "Group “\(name)” created"
        return space.id
    }

    public func switchGroup(_ spaceID: SpaceID) {
        guard session.spaces.contains(where: { $0.id == spaceID }),
              spaceID != session.activeSpaceID else { return }
        var tabs = session.tabs
        var target = tabs.filter { $0.spaceID == spaceID }.max { $0.lastAccessedAt < $1.lastAccessedAt }?.id
        if target == nil {
            let tab = BrowserTab(spaceID: spaceID, title: "New Tab", position: tabs.count)
            tabs.append(tab)
            target = tab.id
        }
        session = BrowserSessionState(
            spaces: session.spaces,
            tabs: tabs,
            activeSpaceID: spaceID,
            activeTabID: target,
            isPrivate: session.isPrivate
        )
        activePanel = .none
        addressText = target
            .flatMap { id in session.tabs.first { $0.id == id }?.lastCommittedURL?.absoluteString } ?? ""
        refreshNavigationState()
        persistSession()
        if let target {
            Task { await environment.engine.activate(tabID: target, in: paneID) }
        }
    }

    public func renameGroup(_ spaceID: SpaceID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let spaces = session.spaces.map { space in
            space.id == spaceID
                ? BrowserSpace(id: space.id, name: trimmed, createdAt: space.createdAt, color: space.color)
                : space
        }
        session = BrowserSessionState(
            spaces: spaces,
            tabs: session.tabs,
            activeSpaceID: session.activeSpaceID,
            activeTabID: session.activeTabID,
            isPrivate: session.isPrivate
        )
        persistSession()
    }

    /// Deletes a group and closes its tabs. The last remaining group cannot be
    /// deleted.
    public func deleteGroup(_ spaceID: SpaceID) {
        guard session.spaces.count > 1,
              let space = session.spaces.first(where: { $0.id == spaceID }) else { return }
        let doomed = session.tabs.filter { $0.spaceID == spaceID }
        for tab in doomed {
            environment.engine.discard(tabID: tab.id)
            tabURLs[tab.id] = nil
        }
        let spaces = session.spaces.filter { $0.id != spaceID }
        let tabs = session.tabs.filter { $0.spaceID != spaceID }
        var nextActiveTab = session.activeTabID
        var nextSpace = session.activeSpaceID
        if session.activeSpaceID == spaceID {
            nextSpace = spaces.first?.id ?? session.activeSpaceID
            nextActiveTab = tabs.filter { $0.spaceID == nextSpace }.max { $0.lastAccessedAt < $1.lastAccessedAt }?.id
            if nextActiveTab == nil, let firstSpace = spaces.first {
                let tab = BrowserTab(spaceID: firstSpace.id, title: "New Tab", position: tabs.count)
                nextActiveTab = tab.id
                session = BrowserSessionState(
                    spaces: spaces,
                    tabs: tabs + [tab],
                    activeSpaceID: firstSpace.id,
                    activeTabID: tab.id,
                    isPrivate: session.isPrivate
                )
                statusMessage = "Deleted “\(space.name)”"
                addressText = ""
                refreshNavigationState()
                persistSession()
                return
            }
        }
        session = BrowserSessionState(
            spaces: spaces,
            tabs: tabs,
            activeSpaceID: nextSpace,
            activeTabID: nextActiveTab,
            isPrivate: session.isPrivate
        )
        addressText = activeTab?.lastCommittedURL?.absoluteString ?? ""
        refreshNavigationState()
        persistSession()
        statusMessage = "Deleted “\(space.name)”"
    }

    public func moveTab(_ tabID: TabID, toGroup spaceID: SpaceID) {
        guard let tab = session.tabs.first(where: { $0.id == tabID }),
              tab.spaceID != spaceID,
              session.spaces.contains(where: { $0.id == spaceID }) else { return }
        updateTab(tabID) { tab in
            BrowserTab(
                id: tab.id,
                spaceID: spaceID,
                title: tab.title,
                lastCommittedURL: tab.lastCommittedURL,
                position: tab.position,
                isPinned: tab.isPinned,
                lifecycle: tab.lifecycle,
                createdAt: tab.createdAt,
                lastAccessedAt: tab.lastAccessedAt
            )
        }
        // If the active tab just left the visible group, follow it.
        if session.activeTabID == tabID, spaceID != session.activeSpaceID {
            switchGroup(spaceID)
        }
        persistSession()
    }

    // MARK: - Ask AI

    /// Context handed to the assistant dock from outside it — the page context
    /// menu, for now. The dock adopts it and the user still types and sends.
    public private(set) var pendingAIContext: [AIContextAttachment] = []
    public private(set) var aiContextToken = 0

    public func consumePendingAIContext() -> [AIContextAttachment] {
        defer { pendingAIContext = [] }
        return pendingAIContext
    }

    /// A quick action requested from outside the dock (command palette, menu).
    /// Same handoff as pendingAIContext: the dock consumes the token and the
    /// review sheet still gates what is sent.
    public private(set) var pendingAIQuickAction: AIQuickAction?
    public private(set) var aiQuickActionToken = 0

    public func consumePendingAIQuickAction() -> AIQuickAction? {
        defer { pendingAIQuickAction = nil }
        return pendingAIQuickAction
    }

    private func requestAIQuickAction(_ action: AIQuickAction) {
        pendingAIQuickAction = action
        aiQuickActionToken += 1
        if !isAIDockVisible {
            toggleAIDock()
        }
    }

    private func captureSelectionForAI(tabID: TabID) {
        Task {
            do {
                let captured = try await environment.engine.capture(
                    tabID: tabID,
                    request: CaptureRequest(kinds: [.selection])
                )
                pendingAIContext = captured.attachments
                aiContextToken += 1
                if !isAIDockVisible {
                    toggleAIDock()
                }
                statusMessage = "Selection attached — ask your question"
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Reader mode

    /// The article currently shown in Reader, or nil when the page itself is
    /// displayed.
    public private(set) var readerArticle: ReaderArticle?
    public var isReaderLoading = false

    public var isReaderModeActive: Bool { readerArticle != nil }

    /// Extracts the page with Readability and shows the reading view. Pressing
    /// it again (or Done in the view) returns to the page.
    public func toggleReaderMode() {
        if readerArticle != nil {
            closeReader()
            return
        }
        guard let tabID = session.activeTabID else { return }
        isReaderLoading = true
        Task {
            defer { isReaderLoading = false }
            do {
                readerArticle = try await environment.engine.extractArticle(tabID: tabID)
                activePanel = .none
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    public func closeReader() {
        readerArticle = nil
    }

    /// Whether this site should open in Reader automatically.
    public func prefersReader(for url: URL?) -> Bool {
        guard let origin = url?.host else { return false }
        return (try? environment.sitePreferenceRepository.value(origin: origin, preference: "reader")) == "always"
    }

    public func setReaderPreference(always: Bool) {
        guard let host = (tabURLs[session.activeTabID ?? TabID()] ?? activeTab?.lastCommittedURL)?.host else {
            return
        }
        if always {
            try? environment.sitePreferenceRepository.set(origin: host, preference: "reader", value: "always")
            statusMessage = "Reader will open automatically on \(host)"
        } else {
            try? environment.sitePreferenceRepository.remove(origin: host, preference: "reader")
            statusMessage = "Reader will not open automatically on \(host)"
        }
    }

    public func focusAddress() {
        focusAddressToken += 1
    }

    /// Mutes or unmutes a tab's media. The page applies it through the
    /// injected monitor, and the state survives navigation.
    public func toggleTabMute(_ tabID: TabID) {
        let isMuted = tabAudio[tabID]?.isMuted ?? false
        let next = !isMuted
        environment.engine.setMuted(tabID: tabID, muted: next)
        tabAudio[tabID] = TabAudioState(isPlaying: next ? false : (tabAudio[tabID]?.isPlaying ?? false), isMuted: next)
        if !next, tabAudio[tabID]?.isPlaying != true, tabAudio[tabID]?.isMuted != true {
            tabAudio[tabID] = nil
        }
        statusMessage = next ? "Tab muted" : "Tab unmuted"
    }

    public func showFindBar() {
        isFindBarVisible = true
    }

    public func dismissFindBar() {
        isFindBarVisible = false
        findStatus = nil
        findText = ""
        if let tabID = session.activeTabID {
            environment.engine.clearFindHighlight(tabID: tabID)
        }
    }

    public func findOnPage(backwards: Bool = false) {
        guard let tabID = session.activeTabID else { return }
        let query = findText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            findStatus = nil
            return
        }
        Task {
            let outcome = await environment.engine.find(tabID: tabID, query: query, backwards: backwards)
            findStatus = outcome.found ? outcome.describedResult : "No matches"
        }
    }

    public func zoomIn() {
        guard let tabID = session.activeTabID else { return }
        environment.engine.adjustZoom(tabID: tabID, by: 0.1)
        persistZoomForActivePage()
    }

    public func zoomOut() {
        guard let tabID = session.activeTabID else { return }
        environment.engine.adjustZoom(tabID: tabID, by: -0.1)
        persistZoomForActivePage()
    }

    public func resetZoom() {
        guard let tabID = session.activeTabID else { return }
        environment.engine.resetZoom(tabID: tabID)
        if let host = Self.zoomHost(of: activeTab?.lastCommittedURL ?? tabURLs[tabID]) {
            try? environment.sitePreferenceRepository.remove(origin: host, preference: "zoom")
        }
    }

    /// Saves the current page zoom for the site's host. Zooming is a per-site
    /// preference: returning to the host restores it, and hosts never inherit
    /// a level dialed in somewhere else.
    private func persistZoomForActivePage() {
        // Private windows remember nothing, including zoom.
        guard !session.isPrivate,
              let tabID = session.activeTabID,
              let host = Self.zoomHost(of: activeTab?.lastCommittedURL ?? tabURLs[tabID]) else { return }
        let zoom = environment.engine.currentZoom(tabID: tabID)
        try? environment.sitePreferenceRepository.set(origin: host, preference: "zoom", value: String(Double(zoom)))
    }

    /// Host-keyed so example.com keeps its level across pages on that site.
    /// Returns nil for URLs without a host, where zoom is not remembered.
    static func zoomHost(of url: URL?) -> String? {
        guard let host = url?.host(percentEncoded: false), !host.isEmpty else { return nil }
        return host.lowercased()
    }

    /// Restores the saved level — or resets to 100%, so a zoomed site does not
    /// bleed into the next one the tab visits. Hostless pages (file:, about:)
    /// reset too, since a warm webview may carry a previous site's level.
    private func applySiteZoom(tabID: TabID, url: URL) {
        guard let host = Self.zoomHost(of: url) else {
            environment.engine.setZoom(tabID: tabID, to: 1)
            return
        }
        let saved = (try? environment.sitePreferenceRepository.value(origin: host, preference: "zoom"))
            .flatMap { Double($0) }
        environment.engine.setZoom(tabID: tabID, to: saved.map { CGFloat($0) } ?? 1)
    }

    public func printPage() {
        guard let tabID = session.activeTabID else { return }
        environment.engine.printPage(tabID: tabID)
    }

    /// Saves the full page as a PDF next to the user's downloads location of
    /// choice. The save panel is the consent point — nothing writes without it.
    public func savePageAsPDF() {
        guard let tabID = session.activeTabID else { return }
        let baseName = Self.exportBaseName(for: activeTab)
        Task {
            do {
                let data = try await environment.engine.pagePDF(tabID: tabID)
                saveExport(data: data, baseName: baseName, extension: "pdf")
            } catch {
                statusMessage = "This page could not be saved as a PDF."
            }
        }
    }

    /// Saves the visible viewport as a PNG.
    public func savePageScreenshot() {
        guard let tabID = session.activeTabID else { return }
        let baseName = Self.exportBaseName(for: activeTab)
        Task {
            do {
                let data = try await environment.engine.pageScreenshot(tabID: tabID)
                saveExport(data: data, baseName: baseName, extension: "png")
            } catch {
                statusMessage = "This page could not be captured."
            }
        }
    }

    private static func exportBaseName(for tab: BrowserTab?) -> String {
        let raw = tab?.title ?? tab?.lastCommittedURL?.host ?? "page"
        let safe = raw.replacingOccurrences(of: "[/:\\\\?%*|\"<>]", with: "-", options: .regularExpression)
        return safe.isEmpty ? "page" : safe
    }

    private func saveExport(data: Data, baseName: String, extension ext: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(baseName).\(ext)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            statusMessage = "Saved \(url.lastPathComponent)"
        } catch {
            statusMessage = "The file could not be saved."
        }
    }

    public func togglePictureInPicture() {
        guard let tabID = session.activeTabID else { return }
        Task {
            if await environment.engine.togglePictureInPicture(tabID: tabID) {
                statusMessage = nil
            } else {
                statusMessage = "No video on this page can play in Picture in Picture."
            }
        }
    }

    public func ensureLoaded(_ tabID: TabID) {
        guard !environment.engine.isLive(tabID: tabID) else {
            Task { await environment.engine.activate(tabID: tabID, in: paneID) }
            return
        }
        let url = tabURLs[tabID] ?? session.tabs.first { $0.id == tabID }?.lastCommittedURL
        guard let url else { return }
        tabURLs[tabID] = url
        Task {
            await environment.engine.activate(tabID: tabID, in: paneID)
            try? await environment.engine.navigate(tabID: tabID, to: NavigationRequest(url: url))
        }
    }

    public func updateSettings(_ mutate: (inout BrowserSettings) -> Void) {
        var settings = environment.loadSettings()
        mutate(&settings)
        environment.saveSettings(settings)
        appearance = settings.appearance
        isAIDockVisible = settings.isAIDockEnabled
        environment.engine.apply(settings)
        applyAppearanceToApp()
    }

    /// Keeps the whole process in the chosen appearance.
    ///
    /// The palette is built from dynamic `NSColor`s, which resolve against the
    /// *process* appearance. Forcing only the SwiftUI colour scheme left the
    /// two disagreeing — light panels with dark controls — so the app-level
    /// appearance is set as well.
    public func applyAppearanceToApp() {
        switch appearance {
        case .system:
            NSApplication.shared.appearance = nil
        case .light:
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Unloads every background tab and drops the warm spare, then reports what
    /// changed in the app's own footprint. WebKit frees its page processes on
    /// its own schedule and they are not children of this app, so a number is
    /// only reported when the app process itself measurably shrank.
    public func freeMemoryNow() {
        let before = ProcessMemory.footprintBytes()
        environment.engine.hibernateInactiveTabs()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            let after = ProcessMemory.footprintBytes()
            guard let self else { return }
            let freed = before > after ? before - after : 0
            if freed > 0 {
                self.statusMessage = "Unloaded background tabs — freed \(ByteCountFormatter.string(fromByteCount: Int64(freed), countStyle: .memory))"
            } else {
                self.statusMessage = "Background tabs unloaded. WebKit releases their page processes on its own schedule."
            }
        }
    }

    /// The app's measured memory and what the figure covers. WebKit keeps page
    /// processes in separate XPC services, so the scope is stated rather than
    /// implied.
    public var memorySummary: ProcessMemory.Summary {
        ProcessMemory.summary()
    }

    public var currentMemoryFootprint: String {
        memorySummary.formatted
    }

    public var memoryScopeDescription: String {
        memorySummary.includesPageProcesses
            ? "app and page processes"
            : "app process; WebKit manages the page processes"
    }

    public var contentRuleState: BlockingState {
        environment.engine.blocking
    }

    public var contentRuleCount: Int {
        environment.engine.blocking.ruleCount
    }

    public func currentSettings() -> BrowserSettings {
        environment.loadSettings()
    }

    public func toggleAIDock() {
        isAIDockVisible.toggle()
        var settings = environment.loadSettings()
        settings.isAIDockEnabled = isAIDockVisible
        environment.saveSettings(settings)
    }

    public func toggleCommandPalette() {
        isCommandPaletteVisible.toggle()
    }

    public func dismissCommandPalette() {
        isCommandPaletteVisible = false
    }

    public func openPanel(_ panel: BrowserPanel) {
        activePanel = panel
        isCommandPaletteVisible = false
    }

    public func filteredCommands(query: String) -> [BrowserPaletteCommand] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let tabResults = tabPaletteCommands(matching: trimmedQuery)
        guard !trimmedQuery.isEmpty else { return tabResults + paletteCommands }
        return tabResults + paletteCommands.filter {
            $0.title.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    /// Open tabs as palette results, so ⌘K doubles as a tab switcher: type a
    /// few letters of a page title or address and jump straight to it. The
    /// active tab is never listed — jumping to where you already are is noise.
    private func tabPaletteCommands(matching query: String) -> [BrowserPaletteCommand] {
        let others = session.tabs.filter { $0.id != session.activeTabID }
        let candidates: [BrowserTab]
        if query.isEmpty {
            // Show a few most-recently-used tabs even before typing.
            candidates = others
                .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
                .prefix(5)
                .map { $0 }
        } else {
            candidates = others.filter { tab in
                tab.title.localizedCaseInsensitiveContains(query)
                    || (tab.lastCommittedURL?.absoluteString.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        return candidates.prefix(8).map { tab in
            BrowserPaletteCommand(
                id: "tab-\(tab.id.rawValue.uuidString)",
                title: tab.title,
                shortcut: tab.lastCommittedURL?.host ?? "",
                command: .selectTab(tab.id)
            )
        }
    }

    public func perform(_ command: BrowserCommand) {
        switch command {
        case .newTab:
            newTab()
        case .closeTab(let tabID):
            if session.tabs.contains(where: { $0.id == tabID }) {
                closeTab(tabID)
            } else {
                closeTab()
            }
        case .selectTab(let tabID):
            selectTab(tabID)
        case .toggleAIDock:
            toggleAIDock()
        case .toggleCommandPalette:
            toggleCommandPalette()
        case .reload:
            reload()
        case .stopLoading:
            stopLoading()
        case .goBack:
            goBack()
        case .goForward:
            goForward()
        case .toggleBookmark:
            toggleBookmark()
        case .reopenClosedTab:
            reopenClosedTab()
        case .openHistory:
            openPanel(.history)
        case .openBookmarks:
            openPanel(.bookmarks)
        case .openDownloads:
            openPanel(.downloads)
        case .openSettings:
            openPanel(.settings)
        case .clearBrowsingData:
            clearBrowsingData()
        case .aiQuickAction(let action):
            requestAIQuickAction(action)
        case .zoomIn:
            zoomIn()
        case .zoomOut:
            zoomOut()
        case .resetZoom:
            resetZoom()
        case .savePageAsPDF:
            savePageAsPDF()
        case .savePageScreenshot:
            savePageScreenshot()
        case .togglePictureInPicture:
            togglePictureInPicture()
        }
    }

    /// The engine new searches use, from settings.
    public var activeSearchEngine: SearchEnginePreset? {
        SearchEnginePreset.preset(for: environment.loadSettings().searchEngineTemplate)
    }

    public var activeSearchEngineName: String {
        SearchEnginePreset.name(for: environment.loadSettings().searchEngineTemplate)
    }

    public func selectSearchEngine(_ preset: SearchEnginePreset) {
        updateSettings { $0.searchEngineTemplate = preset.template }
        statusMessage = "Searches now use \(preset.name)"
    }

    public func submitAddress() {
        guard let tabID = session.activeTabID else { return }
        let settings = environment.loadSettings()
        // "!d query" searches with one engine without changing the default.
        let (bangPreset, query) = SearchBangParser.parse(addressText)
        let template = bangPreset?.template ?? settings.searchEngineTemplate
        let resolver = NavigationResolver(
            searchURL: URL(string: template) ?? URL(string: SearchEnginePreset.google.template)!
        )
        do {
            let request = try resolver.resolve(bangPreset == nil ? addressText : query)
            // Typing a URL that is already open in this space switches to the
            // existing tab instead of stacking a duplicate. Navigations the
            // page itself triggers (target=_blank, redirects) are unaffected.
            if let existing = duplicateTab(of: request.url, excluding: tabID) {
                selectTab(existing)
                statusMessage = "Switched to the tab that already had this page open"
                return
            }
            tabURLs[tabID] = request.url
            updateTab(tabID) { tab in
                BrowserTab(
                    id: tab.id,
                    spaceID: tab.spaceID,
                    title: tab.title,
                    lastCommittedURL: request.url,
                    position: tab.position,
                    isPinned: tab.isPinned,
                    lifecycle: .loading,
                    createdAt: tab.createdAt,
                    lastAccessedAt: Date()
                )
            }
            isLoading = true
            statusMessage = nil
            Task { try? await environment.engine.navigate(tabID: tabID, to: request) }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func reload() {
        guard let tabID = session.activeTabID else { return }
        environment.engine.reload(tabID: tabID)
        isLoading = true
    }

    public func stopLoading() {
        guard let tabID = session.activeTabID else { return }
        environment.engine.stopLoading(tabID: tabID)
        isLoading = false
    }

    public func goBack() {
        guard let tabID = session.activeTabID else { return }
        environment.engine.goBack(tabID: tabID)
    }

    public func goForward() {
        guard let tabID = session.activeTabID else { return }
        environment.engine.goForward(tabID: tabID)
    }

    public func toggleBookmark() {
        guard let url = activeTab?.lastCommittedURL else { return }
        do {
            if try environment.bookmarkRepository.contains(url: url) {
                try environment.bookmarkRepository.remove(url: url)
                statusMessage = "Bookmark removed"
            } else {
                try environment.bookmarkRepository.add(url: url, title: activeTab?.title ?? url.host ?? "Bookmark")
                statusMessage = "Bookmarked"
            }
            refreshNavigationState()
            refreshBookmarks()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func refreshBookmarks() {
        let loaded = (try? environment.bookmarkRepository.all()) ?? []
        bookmarks = loaded
        // Kept in memory so the bookmark star never queries SQLite while the
        // user types or navigates.
        bookmarkedURLs = Set(loaded.map(\.url.absoluteString))
        refreshNavigationState()
    }

    public func removeBookmark(_ bookmark: Bookmark) {
        _ = try? environment.bookmarkRepository.remove(id: bookmark.id)
        refreshBookmarks()
        refreshNavigationState()
    }

    public func open(_ url: URL) {
        addressText = url.absoluteString
        submitAddress()
    }

    public func toggleBookmarksBar() {
        isBookmarksBarVisible.toggle()
        UserDefaults.standard.set(isBookmarksBarVisible, forKey: "browsemium.bookmarksBarVisible")
    }

    public func refreshSavedCredentials() {
        savedCredentials = (try? environment.savedCredentialRepository.all()) ?? []
    }

    public func saveCredential(host: String, username: String, password: String) {
        do {
            let credential = try environment.savedCredentialRepository.save(host: host, username: username)
            try environment.keychain.setSecret(password, account: credential.keychainAccount)
            refreshSavedCredentials()
            statusMessage = "Password saved securely in Keychain"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func removeCredential(_ credential: SavedCredential) {
        do {
            try environment.keychain.deleteSecret(account: credential.keychainAccount)
            _ = try environment.savedCredentialRepository.remove(id: credential.id)
            refreshSavedCredentials()
            statusMessage = "Saved password removed"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func fillCredential(_ credential: SavedCredential) {
        guard let tabID = session.activeTabID,
              let url = activeTab?.lastCommittedURL,
              url.scheme == "https",
              url.host?.lowercased() == credential.host else {
            statusMessage = "Open \(credential.host) over HTTPS before filling this password"
            return
        }
        Task {
            do {
                guard let password = try environment.keychain.secret(account: credential.keychainAccount) else {
                    statusMessage = "The password is missing from Keychain"
                    return
                }
                let filled = try await environment.engine.fillCredential(
                    tabID: tabID,
                    username: credential.username,
                    password: password
                )
                statusMessage = filled ? "Login filled — review it before submitting" : "No visible password field was found"
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    public func credentialsForActiveSite() -> [SavedCredential] {
        guard let host = activeTab?.lastCommittedURL?.host?.lowercased() else { return [] }
        return savedCredentials.filter { $0.host == host }
    }

    public func reopenClosedTab() {
        guard let entry = try? environment.closedTabRepository.mostRecent() else {
            statusMessage = "No recently closed tabs"
            return
        }
        _ = try? environment.closedTabRepository.remove(id: entry.id)
        _ = newTab(url: entry.url)
    }

    /// Reopens a specific entry from the recently-closed list and drops it
    /// from that list, matching the ⇧⌘T behaviour.
    public func reopenClosedTab(_ entry: ClosedTabEntry) {
        _ = try? environment.closedTabRepository.remove(id: entry.id)
        _ = newTab(url: entry.url)
    }

    /// The list behind the Recently Closed section.
    public func recentlyClosedTabs(limit: Int = 20) -> [ClosedTabEntry] {
        (try? environment.closedTabRepository.recent(limit: limit)) ?? []
    }

    public func clearBrowsingData() {
        do {
            try environment.privacyDataManager.clear(.everything)
            refreshSitePermissions()
            statusMessage = "Browsing data cleared"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Removes cookies, site storage, and cache for the active profile. This
    /// is the part of "clear browsing data" that lives in the engine rather
    /// than the database, and it was missing entirely: signing out of a site
    /// was the only way to drop its cookies.
    public func clearCookiesAndSiteData() {
        let storeIdentifier = environment.activeProfile.dataStoreUUID
        Task { [weak self] in
            guard let self else { return }
            await self.environment.engine.clearSiteData(
                dataStoreIdentifier: storeIdentifier,
                includeCache: true,
                modifiedSince: .distantPast
            )
            self.statusMessage = "Cookies, site data, and cache cleared for this profile"
        }
    }

    public func clearCache() {
        let storeIdentifier = environment.activeProfile.dataStoreUUID
        Task { [weak self] in
            guard let self else { return }
            await self.environment.engine.clearCache(dataStoreIdentifier: storeIdentifier)
            self.statusMessage = "Cache cleared for this profile"
        }
    }

    public func applySleepPolicy() {
        let tabs = session.tabs
        let signals = sleepSignals(for: tabs)
        let engine = environment.engine
        Task {
            await engine.applySleepPolicy(tabs: tabs, signals: signals, now: Date())
        }
    }

    /// What each tab is doing right now. The policy refuses to unload a tab
    /// that is audible, holding a microphone/camera/screen track, downloading,
    /// or explicitly kept loaded by the user — unloading one of those
    /// mid-flight is how a background call or a download used to disappear.
    func sleepSignals(for tabs: [BrowserTab]) -> [TabID: TabSleepSignals] {
        let busyDownloads = Set(
            environment.engine.downloads.allDownloads()
                .filter { !$0.isFinished && $0.failureMessage == nil }
                .compactMap(\.tabID)
        )
        return Self.makeSignals(
            tabs: tabs,
            audio: tabAudio,
            activeDownloads: busyDownloads,
            keepAwake: keepAwakeTabIDs
        )
    }

    /// Pure mapping from live state to policy input, so the wiring can be
    /// tested without a window.
    static func makeSignals(
        tabs: [BrowserTab],
        audio: [TabID: TabAudioState],
        activeDownloads: Set<TabID>,
        keepAwake: Set<TabID>
    ) -> [TabID: TabSleepSignals] {
        var signals: [TabID: TabSleepSignals] = [:]
        for tab in tabs {
            let state = audio[tab.id]
            signals[tab.id] = TabSleepSignals(
                isAudible: state?.isPlaying == true,
                isCapturingMedia: state?.isCapturingMedia == true,
                hasActiveDownload: activeDownloads.contains(tab.id),
                isKeepAwake: keepAwake.contains(tab.id)
            )
        }
        return signals
    }

    public func isKeptAwake(_ tabID: TabID) -> Bool {
        keepAwakeTabIDs.contains(tabID)
    }

    /// Marks a tab as one the memory saver must never unload. In-memory on
    /// purpose: the sleep policy's own state is per-session too.
    public func toggleKeepAwake(_ tabID: TabID) {
        if keepAwakeTabIDs.remove(tabID) != nil {
            statusMessage = "This tab can be unloaded when idle again"
        } else {
            keepAwakeTabIDs.insert(tabID)
            statusMessage = "This tab stays loaded until you close it"
        }
        applySleepPolicy()
    }

    // MARK: - Site permissions

    /// One camera/microphone request waiting for the user. Pages can ask from
    /// two tabs at once, so they queue instead of overwriting each other.
    public struct PermissionRequest: Identifiable, Sendable {
        public let id: UUID
        public let origin: String
        public let kind: SitePermissionKind
    }

    public var pendingPermissionRequest: PermissionRequest? {
        permissionQueue.first
    }

    /// How many requests are waiting, including the one on screen. A page can
    /// ask for the camera and the microphone, or two tabs can ask at once.
    public var pendingPermissionCount: Int {
        permissionQueue.count
    }

    public private(set) var sitePermissions: [SitePermissionRecord] = []

    /// The engine calls this from `WKUIDelegate`. A remembered answer is
    /// returned immediately; anything else becomes a prompt.
    public func permissionDecision(origin: String, kind: SitePermissionKind) async -> SitePermissionDecision {
        if let stored = try? environment.permissionRepository.decision(origin: origin, kind: kind),
           stored != .ask {
            return stored
        }
        return await withCheckedContinuation { continuation in
            let request = PermissionRequest(id: UUID(), origin: origin, kind: kind)
            permissionQueue.append(request)
            permissionContinuations[request.id] = continuation
            // A prompt nobody answers must not hold the page forever.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                self?.abandonPermissionRequest(request.id)
            }
        }
    }

    public func answerPermissionRequest(_ answer: SitePermissionAnswer) {
        guard let request = permissionQueue.first else { return }
        permissionQueue.removeFirst()
        let decision: SitePermissionDecision = answer == .block ? .deny : .allow
        if answer != .allowOnce {
            try? environment.permissionRepository.set(origin: request.origin, kind: request.kind, decision: decision)
            refreshSitePermissions()
        }
        permissionContinuations.removeValue(forKey: request.id)?.resume(returning: decision)
    }

    private func abandonPermissionRequest(_ id: UUID) {
        guard let index = permissionQueue.firstIndex(where: { $0.id == id }) else { return }
        let request = permissionQueue.remove(at: index)
        permissionContinuations.removeValue(forKey: request.id)?.resume(returning: .deny)
    }

    public func refreshSitePermissions() {
        sitePermissions = (try? environment.permissionRepository.all()) ?? []
    }

    public func removeSitePermission(_ record: SitePermissionRecord) {
        try? environment.permissionRepository.remove(origin: record.origin, kind: record.kind)
        refreshSitePermissions()
    }

    /// Registers this window with the shared runtime. Safe to call again: a
    /// window that is hidden and shown again must not end up with two
    /// registrations or none.
    public func startObservingRuntime() {
        guard runtimeObserverTokens.isEmpty else { return }
        runtimeObserverTokens = [
            environment.engine.addEventObserver { [weak self] tabID, event in
                self?.handle(event, for: tabID)
            }
        ]
        downloadObserverToken = environment.engine.downloads.addObserver { [weak self] info in
            self?.handleDownload(info)
        }
        environment.engine.permissionPrompter = self
    }

    /// Stops observing the shared runtime. Called when a window closes so a
    /// closed window is not kept alive by its own registrations.
    public func stopObservingRuntime() {
        for token in runtimeObserverTokens {
            environment.engine.removeEventObserver(token)
        }
        runtimeObserverTokens = []
        if let downloadObserverToken {
            environment.engine.downloads.removeObserver(downloadObserverToken)
        }
        downloadObserverToken = nil
    }

    private func handle(_ event: TabRuntimeEvent, for tabID: TabID) {
        switch event {
        case .requestedAISelection:
            captureSelectionForAI(tabID: tabID)
        case .linkHovered(let url):
            // Only the visible tab owns the status bar; a background tab's
            // hover events are ignored so the bar never lies.
            if session.activeTabID == tabID {
                hoveredLinkURL = url
            }
        case .audioStateChanged(let state):
            if state.isPlaying || state.isMuted {
                tabAudio[tabID] = state
            } else {
                tabAudio[tabID] = nil
            }
        case .startedLoading(let url):
            if let url {
                tabURLs[tabID] = url
            }
            if session.activeTabID == tabID {
                isLoading = true
                loadingProgress = 0.05
                statusMessage = nil
                hoveredLinkURL = nil
            }
            updateTab(tabID) { tab in
                BrowserTab(
                    id: tab.id,
                    spaceID: tab.spaceID,
                    title: tab.title,
                    lastCommittedURL: url ?? tab.lastCommittedURL,
                    position: tab.position,
                    isPinned: tab.isPinned,
                    lifecycle: .loading,
                    createdAt: tab.createdAt,
                    lastAccessedAt: Date()
                )
            }
        case .committed(let url):
            if let url {
                tabURLs[tabID] = url
                // Page zoom is per-webview, so a navigation keeps the last
                // site's level unless the destination's preference is applied.
                applySiteZoom(tabID: tabID, url: url)
                if session.activeTabID == tabID {
                    addressText = url.absoluteString
                    // Refresh now so the bookmark star follows the new page
                    // instead of the one that was open before it.
                    refreshNavigationState()
                }
            }
        case .finished(let title, let url):
            updateTab(tabID) { tab in
                BrowserTab(
                    id: tab.id,
                    spaceID: tab.spaceID,
                    title: title?.isEmpty == false ? title! : (url?.host ?? tab.title),
                    lastCommittedURL: url ?? tab.lastCommittedURL,
                    position: tab.position,
                    isPinned: tab.isPinned,
                    lifecycle: .active,
                    createdAt: tab.createdAt,
                    lastAccessedAt: Date()
                )
            }
            if let url {
                tabURLs[tabID] = url
                // Icon discovery runs JavaScript and a network fetch. Let the
                // page settle first so it never competes with loading.
                Task { [favicons, engine = environment.engine] in
                    try? await Task.sleep(for: .milliseconds(350))
                    favicons.fetchIcon(engine: engine, tabID: tabID, pageURL: url)
                }
            }
            if session.activeTabID == tabID {
                isLoading = false
                loadingProgress = 1
                addressText = url?.absoluteString ?? addressText
                refreshNavigationState()
            }
            // Sites marked "always use Reader" open straight into it.
            if session.activeTabID == tabID, readerArticle == nil, let url, prefersReader(for: url) {
                toggleReaderMode()
            }
            recordHistory(url: url, title: title)
            persistSession()
            applySleepPolicy()
            LaunchMetrics.mark(.firstNavigation)
            // A finished load is the right moment to refill the warm tab.
            environment.engine.prepareWarmTab()
        case .progressChanged(let progress):
            if session.activeTabID == tabID {
                loadingProgress = progress
            }
        case .failed(let message):
            if session.activeTabID == tabID {
                isLoading = false
                loadingProgress = 1
                statusMessage = message
            }
        case .crashed:
            updateTab(tabID) { tab in
                BrowserTab(
                    id: tab.id,
                    spaceID: tab.spaceID,
                    title: tab.title,
                    lastCommittedURL: tab.lastCommittedURL,
                    position: tab.position,
                    isPinned: tab.isPinned,
                    lifecycle: .crashed,
                    createdAt: tab.createdAt,
                    lastAccessedAt: Date()
                )
            }
            if session.activeTabID == tabID {
                isLoading = false
                statusMessage = "This page stopped responding. Reload to try again."
            }
        case .lifecycleChanged(let lifecycle):
            // Suspension and hibernation happen without a navigation event, so
            // this is what keeps the tab strip, the stats card, the settings
            // counters, and the sleep policy agreeing about what is loaded.
            updateTab(tabID) { tab in
                BrowserTab(
                    id: tab.id,
                    spaceID: tab.spaceID,
                    title: tab.title,
                    lastCommittedURL: tab.lastCommittedURL,
                    position: tab.position,
                    isPinned: tab.isPinned,
                    lifecycle: lifecycle,
                    createdAt: tab.createdAt,
                    lastAccessedAt: tab.lastAccessedAt
                )
            }
        case .requestedNewWindow(let url):
            _ = newTab(url: url)
        case .requestedExternalScheme(let url):
            openExternally(url)
        case .downloadStarted, .downloadFinished, .downloadFailed:
            break
        }
    }

    private func handleDownload(_ info: DownloadInfo) {
        let state: DownloadState = info.failureMessage != nil ? .failed : (info.isFinished ? .finished : .inProgress)
        let progress = DownloadProgress(
            id: info.id,
            filename: info.suggestedFilename,
            bytesReceived: info.bytesReceived,
            totalBytes: info.totalBytes,
            isFinished: info.isFinished,
            failureMessage: info.failureMessage
        )
        if let index = downloads.firstIndex(where: { $0.id == progress.id }) {
            downloads[index] = progress
        } else {
            downloads.insert(progress, at: 0)
        }
        if downloads.count > 20 {
            downloads.removeLast(downloads.count - 20)
        }
        if info.isFinished || info.failureMessage != nil {
            scheduleDownloadDismissal(id: progress.id)
        }
        let record = DownloadRecord(
            id: info.id,
            tabID: info.tabID,
            sourceURL: info.destinationURL ?? URL(fileURLWithPath: "/"),
            destinationURL: info.destinationURL,
            suggestedFilename: info.suggestedFilename,
            state: state,
            bytesReceived: info.bytesReceived,
            totalBytes: info.totalBytes,
            failureMessage: info.failureMessage,
            createdAt: Date(),
            updatedAt: Date()
        )
        try? environment.downloadRepository.upsert(record)

        guard let tabID = info.tabID, tabID == session.activeTabID else { return }
        switch state {
        case .finished:
            statusMessage = "Downloaded \(info.suggestedFilename)"
        case .failed:
            statusMessage = info.failureMessage ?? "The download failed."
        case .inProgress, .cancelled:
            break
        }
    }

    /// A finished download should not leave a permanent badge in the toolbar.
    private func scheduleDownloadDismissal(id: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !self.hasActiveDownloads else { return }
            self.downloads.removeAll { $0.id == id && ($0.isFinished || $0.failureMessage != nil) }
        }
    }

    private func openExternally(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return }
        statusMessage = "Opening \(scheme) link in another app…"
        NSWorkspace.shared.open(url)
    }

    private func recordHistory(url: URL?, title: String?) {
        guard !session.isPrivate,
              let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return
        }
        // Disk writes must never block the frame that just painted a page.
        // A serial queue keeps them in submission order — concurrent tasks
        // could otherwise land out of order and persist a stale session.
        let repository = environment.historyRepository
        let resolvedTitle = title ?? url.host ?? ""
        Self.persistenceQueue.async {
            _ = try? repository.record(url: url, title: resolvedTitle)
        }
    }

    // MARK: - Profiles

    public var activeProfile: BrowserProfile { environment.activeProfile }
    public var profiles: [BrowserProfile] { environment.profiles }

    /// Switches the window to another profile: saves the current session,
    /// drops every web view (they belong to the previous profile's WebKit
    /// data store), points the repositories at the new profile's database,
    /// and rebuilds the tab session.
    public func switchProfile(to profile: BrowserProfile) {
        guard profile.id != environment.activeProfile.id else { return }
        persistSession()
        let previous = environment.activeProfile
        environment.engine.teardownForProfileSwitch()
        do {
            try environment.activate(profile)
        } catch {
            // The runtime was already torn down — fall back to the previous
            // profile rather than leaving the window with no web views.
            try? environment.activate(previous)
            resetForActiveProfile()
            statusMessage = "Could not open \(profile.name): \(error.localizedDescription)"
            return
        }
        resetForActiveProfile()
        statusMessage = "Switched to \(profile.name)"
    }

    @discardableResult
    public func createProfile(named name: String, switchToIt: Bool = true) -> BrowserProfile? {
        do {
            let profile = try environment.createProfile(name: name)
            if switchToIt {
                switchProfile(to: profile)
            } else {
                profileSwitchToken += 1
            }
            return profile
        } catch {
            statusMessage = "Could not create the profile: \(error.localizedDescription)"
            return nil
        }
    }

    public func renameProfile(_ profile: BrowserProfile, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try environment.renameProfile(profile, to: trimmed)
            statusMessage = "Renamed to \(trimmed)"
        } catch {
            statusMessage = "Could not rename the profile: \(error.localizedDescription)"
        }
    }

    /// Deletes a profile and its WebKit data. Deleting the active profile
    /// falls back to the most recently used one, creating a fresh "Personal"
    /// profile if it was the last.
    public func deleteProfile(_ profile: BrowserProfile) {
        let wasActive = profile.id == environment.activeProfile.id
        do {
            try environment.deleteProfile(profile)
        } catch {
            statusMessage = "Could not delete the profile: \(error.localizedDescription)"
            return
        }
        // The profile's own web views must never be reused, and its cookies and
        // logins must not outlive it.
        let storeIdentifier = profile.dataStoreUUID
        Task { await environment.engine.removeAllData(dataStoreIdentifier: storeIdentifier) }

        if wasActive {
            environment.engine.teardownForProfileSwitch()
            let fallback = environment.profiles.first
                ?? (try? environment.createProfile(name: ProfileStore.personalProfileName))
            if let fallback {
                try? environment.activate(fallback)
            }
            // Rebuild the session either way so the window is never left with
            // a dead runtime after deleting the active profile.
            resetForActiveProfile()
        }
        profileSwitchToken += 1
        statusMessage = "Deleted \(profile.name)"
    }

    /// Rebuilds window state around `environment.activeProfile`.
    private func resetForActiveProfile() {
        if let restored = try? environment.sessionRepository.load() {
            session = restored
        } else {
            let space = BrowserSpace(name: "Personal")
            let tab = BrowserTab(spaceID: space.id, title: "New Tab", position: 0)
            session = BrowserSessionState(
                spaces: [space],
                tabs: [tab],
                activeSpaceID: space.id,
                activeTabID: tab.id
            )
        }
        tabURLs = Dictionary(uniqueKeysWithValues: session.tabs.compactMap { tab in
            tab.lastCommittedURL.map { (tab.id, $0) }
        })
        addressText = activeTab?.lastCommittedURL?.absoluteString ?? ""
        activePanel = .none
        readerArticle = nil
        isFindBarVisible = false
        findText = ""
        findStatus = nil
        isLoading = false
        loadingProgress = 0
        canGoBack = false
        canGoForward = false
        downloads = []
        refreshBookmarks()
        refreshSavedCredentials()
        refreshSitePermissions()
        refreshNavigationState()
        environment.runMaintenance()
        profileSwitchToken += 1
    }

    private func refreshNavigationState() {        guard let tabID = session.activeTabID else {
            canGoBack = false
            canGoForward = false
            isBookmarked = false
            return
        }
        canGoBack = environment.engine.canGoBack(tabID: tabID)
        canGoForward = environment.engine.canGoForward(tabID: tabID)
        isLoading = environment.engine.isLoading(tabID: tabID)
        if !isLoading {
            loadingProgress = 0
        }
        // Prefer the URL the tab is actually navigating to. `lastCommittedURL`
        // still points at the previous page until the new one finishes, which
        // left the bookmark star filled on sites that were not bookmarked.
        let currentURL = tabURLs[tabID] ?? activeTab?.lastCommittedURL
        isBookmarked = currentURL.map { bookmarkedURLs.contains($0.absoluteString) } ?? false
    }

    private func persistSession() {
        guard !session.isPrivate, persistsSession else { return }
        // Serialized off the main thread: session saves happen on every tab
        // switch and page finish, and SQLite writes are not free. The queue is
        // serial on purpose so the newest snapshot always wins.
        let snapshot = session
        let repository = environment.sessionRepository
        Self.persistenceQueue.async {
            try? repository.save(snapshot)
        }
    }

    private func updateTab(_ tabID: TabID, transform: (BrowserTab) -> BrowserTab) {
        guard let index = session.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        var tabs = session.tabs
        tabs[index] = transform(tabs[index])
        session = BrowserSessionState(
            spaces: session.spaces,
            tabs: tabs,
            activeSpaceID: session.activeSpaceID,
            activeTabID: session.activeTabID,
            isPrivate: session.isPrivate
        )
    }
}
