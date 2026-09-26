import AppKit
import BrowsemiumCore
import BrowsemiumData
import BrowsemiumEngine
import BrowsemiumExtensions
import Foundation
import Observation
import WebKit
import BrowsemiumEngineKit

public struct BrowserPaletteCommand: Identifiable, Hashable, Sendable {
    /// What a row is, so the palette can show the right icon.
    public enum Kind: String, Sendable, Hashable {
        case tab
        case history
        case bookmark
        case action
        case command
    }

    public let id: String
    public let title: String
    public let shortcut: String
    public let kind: Kind
    /// Secondary line: a host for pages, a context hint for actions.
    public let subtitle: String
    public let command: BrowserCommand

    public init(
        id: String,
        title: String,
        shortcut: String,
        kind: Kind = .command,
        subtitle: String = "",
        command: BrowserCommand
    ) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
        self.kind = kind
        self.subtitle = subtitle
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
    public private(set) var deletingProfileID: UUID? = nil
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
    /// Observable mirror of the active profile's default search engine. The
    /// persisted settings store itself is not observable, so toolbar controls
    /// would otherwise keep showing stale state after Settings changes it.
    public private(set) var searchEngineTemplate: String
    /// Top strip or leading sidebar. Mirrors the stored setting so the window
    /// layout updates the moment Settings changes it.
    public private(set) var tabLayout: TabLayout
    /// The engine owns page zoom, so publish an observable revision when it
    /// changes to refresh computed zoom values in open toolbar popovers.
    var zoomDisplayRevision = 0
    public private(set) var tabURLs: [TabID: URL]
    /// The query an address-bar search showed while its tab sits on the
    /// results page, keyed by tab. Search engines rewrite the URL after load
    /// (DuckDuckGo appends `ia=web` from page JavaScript); while the page is
    /// still those results the bar keeps showing what was typed, like Safari
    /// and Chrome do. Any navigation elsewhere clears the record.
    private struct SearchDisplay: Equatable {
        let query: String
        let url: URL
    }
    private var searchDisplayByTab: [TabID: SearchDisplay] = [:]
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
    /// Collapses the sidebar tab list to a slim rail in sidebar tab-layout
    /// mode. Persisted like the bookmarks bar so it survives relaunches.
    public var isSidebarCollapsed: Bool = false
    /// Extensions whose toolbar button the user hid. A per-profile UI
    /// preference, so the same extension can be pinned in one profile and
    /// hidden in another.
    public private(set) var hiddenExtensionActionIDs: Set<String> = []

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
        BrowserPaletteCommand(id: "clear-data", title: "Clear Browsing Data", shortcut: "", command: .clearBrowsingData),
        BrowserPaletteCommand(id: "tab-layout", title: "Switch Between Top and Sidebar Tabs", shortcut: "", command: .toggleTabLayout),
        BrowserPaletteCommand(id: "split-view", title: "Toggle Split View", shortcut: "⇧⌘D", command: .toggleSplitView),
        BrowserPaletteCommand(id: "duplicate-tab", title: "Duplicate Tab", shortcut: "", command: .duplicateTab(TabID())),
        BrowserPaletteCommand(id: "copy-url", title: "Copy Current URL", shortcut: "⇧⌘C", command: .copyTabURL(TabID())),
        BrowserPaletteCommand(id: "next-tab", title: "Select Next Tab", shortcut: "⌃⇥", command: .selectAdjacentTab(forward: true)),
        BrowserPaletteCommand(id: "previous-tab", title: "Select Previous Tab", shortcut: "⌃⇧⇥", command: .selectAdjacentTab(forward: false)),
        BrowserPaletteCommand(id: "close-others", title: "Close Other Tabs", shortcut: "", command: .closeOtherTabs(TabID())),
        BrowserPaletteCommand(id: "private-window", title: "New Private Window", shortcut: "⇧⌘N", command: .newPrivateWindow),
        BrowserPaletteCommand(id: "ai-summarize-tabs", title: "AI: Summarize Open Tabs", shortcut: "", command: .summarizeOpenTabs),
        BrowserPaletteCommand(id: "ai-rewrite", title: "AI: Rewrite Selection", shortcut: "", command: .aiQuickAction(.rewriteSelection)),
        BrowserPaletteCommand(id: "ai-shorten", title: "AI: Shorten Selection", shortcut: "", command: .aiQuickAction(.shortenSelection)),
        BrowserPaletteCommand(id: "ai-bullets", title: "AI: Selection to Bullets", shortcut: "", command: .aiQuickAction(.bulletPoints))
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
                folders: [],
                activeSpaceID: space.id,
                activeTabID: tab.id
            )
        }
        // Everything that shapes the starting session is computed in locals:
        // a stored property cannot be read until initialization completes.
        var startingSession = Self.sessionLandingUnlocked(initialSession)
        // A restored active tab inside a collapsed folder is revealed.
        if let activeID = startingSession.activeTabID {
            let revealed = Self.expandedFolders(
                around: activeID,
                in: startingSession.folders,
                tabs: startingSession.tabs
            )
            if revealed != startingSession.folders {
                startingSession = BrowserSessionState(
                    spaces: startingSession.spaces,
                    tabs: startingSession.tabs,
                    folders: revealed,
                    activeSpaceID: startingSession.activeSpaceID,
                    activeTabID: startingSession.activeTabID,
                    isPrivate: startingSession.isPrivate
                )
            }
        }
        session = startingSession
        addressText = startingSession.tabs.first { $0.id == startingSession.activeTabID }?.lastCommittedURL?.absoluteString ?? ""
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
        searchEngineTemplate = storedSettings.searchEngineTemplate
        tabLayout = storedSettings.tabLayout
        tabURLs = Dictionary(uniqueKeysWithValues: initialSession.tabs.compactMap { tab in
            tab.lastCommittedURL.map { (tab.id, $0) }
        })
        isBookmarksBarVisible = UserDefaults.standard.object(forKey: "browsemium.bookmarksBarVisible") as? Bool ?? true
        isSidebarCollapsed = UserDefaults.standard.object(forKey: "browsemium.sidebarCollapsed") as? Bool ?? false
        hiddenExtensionActionIDs = Set(
            UserDefaults.standard.stringArray(forKey: Self.hiddenExtensionActionsKey(for: environment.activeProfile)) ?? []
        )

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
        refreshPausedBlockingHosts()
        refreshCosmeticRules()
        applyAppearanceToApp()
        paneOrder = [paneID]
        paneTabIDs[paneID] = session.activeTabID
        activePaneID = paneID
        applyPrivateBrowsingModeToEngine()
        LaunchMetrics.mark(.modelReady)
    }

    /// A restored session whose active space is locked must not open showing
    /// its tabs — not after a relaunch, and not after a profile switch. Lands
    /// on the first unlocked space (with a fresh tab if that space is empty);
    /// if every space is locked — a state the lock controls refuse but a
    /// damaged database can hold — appends a fresh unlocked space so the
    /// browser still opens somewhere safe.
    private static func sessionLandingUnlocked(_ session: BrowserSessionState) -> BrowserSessionState {
        guard let activeSpace = session.spaces.first(where: { $0.id == session.activeSpaceID }),
              activeSpace.isLocked else { return session }
        var spaces = session.spaces
        var tabs = session.tabs
        let destination: BrowserSpace
        if let unlocked = spaces.first(where: { !$0.isLocked }) {
            destination = unlocked
        } else {
            destination = BrowserSpace(name: "Personal")
            spaces.append(destination)
        }
        var target = tabs
            .filter { $0.spaceID == destination.id }
            .max { $0.lastAccessedAt < $1.lastAccessedAt }?.id
        if target == nil {
            let tab = BrowserTab(spaceID: destination.id, title: "New Tab", position: tabs.count)
            tabs.append(tab)
            target = tab.id
        }
        return BrowserSessionState(
            spaces: spaces,
            tabs: tabs,
            folders: session.folders,
            activeSpaceID: destination.id,
            activeTabID: target,
            isPrivate: session.isPrivate
        )
    }

    /// Keeps the engine's storage mode in step with the session: a private
    /// session must never write to the profile's persistent WebKit store.
    private func applyPrivateBrowsingModeToEngine() {
        environment.engine.setPrivateBrowsing(session.isPrivate)
    }

    /// Turns this window into a private window. Called on a freshly created
    /// window before its first frame: the session becomes one blank tab in a
    /// single "Private" space, every web view and warm spare is dropped, and
    /// the engine switches to the ephemeral WebKit store. Nothing here is
    /// written to disk — no history, no closed tabs, no session snapshot.
    public func enterPrivateMode() {
        guard !session.isPrivate else { return }
        closePeek()
        closeSplitView()
        let space = BrowserSpace(name: "Private")
        let tab = BrowserTab(spaceID: space.id, title: "New Tab", position: 0)
        session = BrowserSessionState(
            spaces: [space],
            tabs: [tab],
            folders: [],
            activeSpaceID: space.id,
            activeTabID: tab.id,
            isPrivate: true
        )
        tabURLs.removeAll()
        searchDisplayByTab.removeAll()
        hoveredLinkURL = nil
        addressText = ""
        readerArticle = nil
        activePanel = .none
        unlockedSpaceIDs.removeAll()
        paneTabIDs[activePaneID] = tab.id
        statusMessage = nil
        refreshNavigationState()
        applyPrivateBrowsingModeToEngine()
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
        refreshExtensions()
        refreshAISkills()
        reloadExtensions()
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
            case openTab
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

        // Open tabs outrank history — switching to a tab you already have is
        // cheaper than loading the page again. `value` carries the tab id.
        for tab in session.tabs {
            let url = tabURLs[tab.id] ?? tab.lastCommittedURL
            guard let url,
                  tab.title.localizedCaseInsensitiveContains(query)
                    || url.absoluteString.localizedCaseInsensitiveContains(query),
                  seen.insert(url.absoluteString).inserted else { continue }
            suggestions.append(
                AddressSuggestion(
                    id: "opentab-\(tab.id.rawValue.uuidString)",
                    kind: .openTab,
                    title: tab.title,
                    subtitle: "Switch to tab — \(url.host ?? url.absoluteString)",
                    value: tab.id.rawValue.uuidString
                )
            )
        }

        // History suggestions are a private-window leak of a different kind:
        // they would surface the profile's past into a session meant to leave
        // no trace, so private windows suggest open tabs and search only.
        if !session.isPrivate {
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
        if addressText == current.absoluteString { return true }
        // The bar shows the query while its tab sits on the results page —
        // that still counts as showing the current page.
        if let display = searchDisplayByTab[tabID],
           addressText == display.query,
           Self.isSameSearchPage(recorded: display.url, current: current, query: display.query) {
            return true
        }
        return false
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
        case .openTab:
            if let uuid = UUID(uuidString: suggestion.value) {
                selectTab(TabID(rawValue: uuid))
            }
        case .history, .bookmark, .search:
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
        public let destinationURL: URL?
        public let bytesReceived: Int64
        public let totalBytes: Int64
        public let isFinished: Bool
        public let failureMessage: String?

        public init(
            id: UUID,
            filename: String,
            destinationURL: URL? = nil,
            bytesReceived: Int64,
            totalBytes: Int64,
            isFinished: Bool,
            failureMessage: String?
        ) {
            self.id = id
            self.filename = filename
            self.destinationURL = destinationURL
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
        let previousActive = session.activeTabID
        let tab = BrowserTab(
            spaceID: session.activeSpaceID,
            title: url == nil ? "New Tab" : (url?.host ?? "Loading"),
            lastCommittedURL: url,
            position: session.tabs.count
        )
        session = BrowserSessionState(
            spaces: session.spaces,
            tabs: session.tabs + [tab],
            folders: session.folders,
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
        syncFocusedPane(with: tab.id)
        refreshNavigationState()
        persistSession()
        notifyExtensionsOfStripChange(activated: tab.id, previous: previousActive)
        return tab.id
    }

    public func closeTab(_ tabID: TabID? = nil) {
        let targetID = tabID ?? session.activeTabID
        guard let targetID, let tab = session.tabs.first(where: { $0.id == targetID }) else { return }

        // A tab that never reached a page (a blank "New Tab") has nothing to
        // reopen — recording it would fill Recently Closed with dead rows. The
        // in-flight URL in tabURLs counts: a mid-load close still reopens.
        if !session.isPrivate, let closedURL = tabURLs[targetID] ?? tab.lastCommittedURL {
            try? environment.closedTabRepository.record(
                BrowserTab(
                    id: tab.id,
                    spaceID: tab.spaceID,
                    title: tab.title,
                    lastCommittedURL: closedURL,
                    position: tab.position,
                    isPinned: tab.isPinned,
                    lifecycle: tab.lifecycle,
                    createdAt: tab.createdAt,
                    lastAccessedAt: tab.lastAccessedAt
                )
            )
        }
        environment.engine.discard(tabID: targetID)
        tabURLs[targetID] = nil
        searchDisplayByTab[targetID] = nil
        hoveredLinkURL = nil
        tabAudio[targetID] = nil
        keepAwakeTabIDs.remove(targetID)
        removeTabFromPanes(targetID)

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
        // If the primary pane's tab just closed and its replacement is already
        // tiled beside it, that pane folds back in — two panes must never show
        // the same tab.
        if paneTabIDs[paneID] == targetID, let nextActiveID,
           let pane = paneOrder.first(where: { $0 != paneID && paneTabIDs[$0] == nextActiveID }) {
            paneOrder.removeAll { $0 == pane }
            paneTabIDs[pane] = nil
            if activePaneID == pane {
                activePaneID = paneID
            }
        }
        // A folder whose last tab just closed disappears with it, like
        // Firefox's groups; other (possibly empty, just-created) folders stay.
        var folders = session.folders
        if let closedFolderID = tab.folderID, !tabs.contains(where: { $0.folderID == closedFolderID }) {
            folders.removeAll { $0.id == closedFolderID }
        }
        session = BrowserSessionState(
            spaces: session.spaces,
            tabs: tabs,
            folders: folders,
            activeSpaceID: session.activeSpaceID,
            activeTabID: nextActiveID,
            isPrivate: session.isPrivate
        )
        if let nextActiveID {
            let url = tabURLs[nextActiveID] ?? activeTab?.lastCommittedURL
            addressText = displayAddress(for: url, tabID: nextActiveID)
        } else {
            addressText = ""
        }
        syncFocusedPane(with: nextActiveID)
        refreshNavigationState()
        persistSession()
        notifyExtensionsOfStripChange(closed: targetID, activated: nextActiveID)
    }

    public func selectTab(_ tabID: TabID) {
        guard let target = session.tabs.first(where: { $0.id == tabID }) else { return }
        // A tab in another space switches spaces first — which is also where
        // a locked space asks for authentication. Selecting it directly would
        // show another space's tab while the strip still showed this one.
        guard target.spaceID == session.activeSpaceID else {
            switchGroup(target.spaceID, thenSelect: tabID)
            return
        }
        let previousActive = session.activeTabID
        // A tab already tiled in another pane focuses that pane instead of
        // being pulled into the focused one; otherwise the focused pane
        // adopts the tab.
        if let pane = paneOrder.first(where: { $0 != activePaneID && paneTabIDs[$0] == tabID }) {
            activePaneID = pane
        } else {
            paneTabIDs[activePaneID] = tabID
        }
        let tabs = session.tabs.map { tab in
            tab.id == tabID ? tab.replaced(lastAccessedAt: Date()) : tab
        }
        // Selecting a tab inside a collapsed folder expands the folder — the
        // active tab is never hidden.
        let folders = Self.expandedFolders(around: tabID, in: session.folders, tabs: tabs)
        session = BrowserSessionState(
            spaces: session.spaces,
            tabs: tabs,
            folders: folders,
            activeSpaceID: session.activeSpaceID,
            activeTabID: tabID,
            isPrivate: session.isPrivate
        )
        activePanel = .none
        readerArticle = nil
        hoveredLinkURL = nil
        addressText = displayAddress(for: tabURLs[tabID] ?? activeTab?.lastCommittedURL, tabID: tabID)
        refreshNavigationState()
        persistSession()
        notifyExtensionsOfStripChange(activated: tabID, previous: previousActive)
        Task { await environment.engine.activate(tabID: tabID, in: activePaneID) }
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

    // MARK: - Tab quality of life

    /// ⌘1…⌘8 select the tab at that strip position; ⌘9 always jumps to the
    /// last tab — the Chrome and Safari convention.
    public func selectTab(atStripIndex index: Int) {
        let tabs = visibleTabs
        let target: BrowserTab?
        if index == 9 {
            target = tabs.last
        } else {
            target = (1...tabs.count).contains(index) ? tabs[index - 1] : nil
        }
        if let target { selectTab(target.id) }
    }

    /// ⌃⇥ and ⌘⇧] step through the strip, wrapping at both ends.
    public func selectAdjacentTab(forward: Bool) {
        let tabs = visibleTabs
        guard tabs.count > 1, let active = session.activeTabID,
              let index = tabs.firstIndex(where: { $0.id == active }) else { return }
        let next = forward
            ? tabs[(index + 1) % tabs.count]
            : tabs[(index + tabs.count - 1) % tabs.count]
        selectTab(next.id)
    }

    /// Opens a copy of a tab directly after it — same address, same folder.
    /// The copy is a fresh navigation; nothing from the source page's state
    /// (scroll, form contents, history stack) carries over.
    @discardableResult
    public func duplicateTab(_ tabID: TabID) -> TabID? {
        guard let sourceIndex = session.tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        let source = session.tabs[sourceIndex]
        let url = tabURLs[tabID] ?? source.lastCommittedURL
        let copy = BrowserTab(
            spaceID: source.spaceID,
            title: source.title,
            lastCommittedURL: url,
            position: source.position,
            folderID: source.folderID
        )
        var tabs = session.tabs
        tabs.insert(copy, at: sourceIndex + 1)
        tabs = tabs.enumerated().map { position, tab in tab.replaced(position: position) }
        let previousActive = session.activeTabID
        session = BrowserSessionState(
            spaces: session.spaces,
            tabs: tabs,
            folders: session.folders,
            activeSpaceID: session.activeSpaceID,
            activeTabID: copy.id,
            isPrivate: session.isPrivate
        )
        activePanel = .none
        if let url {
            tabURLs[copy.id] = url
            if let sourceDisplay = searchDisplayByTab[tabID],
               Self.isSameSearchPage(recorded: sourceDisplay.url, current: url, query: sourceDisplay.query) {
                searchDisplayByTab[copy.id] = SearchDisplay(query: sourceDisplay.query, url: url)
                addressText = sourceDisplay.query
            } else {
                addressText = displayAddress(for: url, tabID: copy.id)
            }
            Task { try? await environment.engine.navigate(tabID: copy.id, to: NavigationRequest(url: url)) }
        } else {
            addressText = ""
        }
        syncFocusedPane(with: copy.id)
        refreshNavigationState()
        persistSession()
        notifyExtensionsOfStripChange(activated: copy.id, previous: previousActive)
        return copy.id
    }

    /// Copies the tab's current address — the in-flight URL if one is
    /// loading, else the committed one.
    public func copyURL(of tabID: TabID) {
        guard let url = tabURLs[tabID]
                ?? session.tabs.first(where: { $0.id == tabID })?.lastCommittedURL else {
            statusMessage = "This tab has no address to copy"
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        statusMessage = "Link copied"
    }

    /// Closes every other tab in the space. Pinned tabs survive — pinning is
    /// how the user says "keep this one".
    public func closeOtherTabs(around tabID: TabID) {
        let others = session.tabs.filter {
            $0.spaceID == session.activeSpaceID && $0.id != tabID && !$0.isPinned
        }
        for tab in others { closeTab(tab.id) }
        // Each close picks its own fallback; land back on the tab that asked.
        if session.tabs.contains(where: { $0.id == tabID }) {
            selectTab(tabID)
        }
    }

    /// Closes the tabs after this one in the space's strip order, leaving
    /// pinned tabs alone.
    public func closeTabs(after tabID: TabID) {
        let spaceTabs = session.tabs.filter { $0.spaceID == session.activeSpaceID }
        guard let index = spaceTabs.firstIndex(where: { $0.id == tabID }) else { return }
        for tab in spaceTabs.dropFirst(index + 1) where !tab.isPinned {
            closeTab(tab.id)
        }
        if session.tabs.contains(where: { $0.id == tabID }) {
            selectTab(tabID)
        }
    }

    /// A snapshot of the tab's live page for the hover preview card, or nil
    /// when there is no page to photograph — a sleeping or blank tab falls
    /// back to metadata only.
    public func previewImage(for tabID: TabID) async -> NSImage? {
        guard environment.engine.isLive(tabID: tabID),
              let data = try? await environment.engine.pageScreenshot(tabID: tabID) else { return nil }
        return NSImage(data: data)
    }

    public func moveTab(_ sourceID: TabID, before targetID: TabID) {
        guard sourceID != targetID else { return }
        let group = session.activeSpaceID
        var groupTabs = session.tabs.filter { $0.spaceID == group }
        guard let sourceIndex = groupTabs.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = groupTabs.firstIndex(where: { $0.id == targetID }) else { return }
        // A tab dropped next to another tab adopts that tab's folder — which
        // is also how a tab leaves a folder: drop it on an ungrouped tab.
        let targetFolderID = groupTabs[targetIndex].folderID
        let sourceFolderID = groupTabs[sourceIndex].folderID
        var moved = groupTabs.remove(at: sourceIndex)
        if !moved.isPinned {
            moved = moved.replaced(folderID: .some(targetFolderID))
        }
        let insertionIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        groupTabs.insert(moved, at: insertionIndex)
        // Splice the reordered group back into the global tab list, leaving
        // other groups' tabs untouched.
        var iterator = groupTabs.makeIterator()
        var tabs = session.tabs.map { tab in
            tab.spaceID == group ? (iterator.next() ?? tab) : tab
        }
        tabs = tabs.enumerated().map { position, tab in
            tab.replaced(position: position)
        }
        // The folder the tab left disappears once its last member is gone.
        var folders = session.folders
        if let sourceFolderID, sourceFolderID != targetFolderID,
           !tabs.contains(where: { $0.folderID == sourceFolderID }) {
            folders.removeAll { $0.id == sourceFolderID }
        }
        session = BrowserSessionState(
            spaces: session.spaces,
            tabs: tabs,
            folders: folders,
            activeSpaceID: session.activeSpaceID,
            activeTabID: session.activeTabID,
            isPrivate: session.isPrivate
        )
        persistSession()
    }

    public func togglePin(_ tabID: TabID) {
        let wasPinned = session.tabs.first { $0.id == tabID }?.isPinned ?? false
        let folderID = session.tabs.first { $0.id == tabID }?.folderID
        updateTab(tabID) { tab in
            // Pinned tabs live outside folders: pinning one takes it out of
            // its folder. Unpinning leaves it ungrouped, ready to re-file.
            tab.replaced(
                isPinned: !tab.isPinned,
                folderID: tab.isPinned ? nil : .some(nil)
            )
        }
        if !wasPinned {
            pruneFolderIfEmpty(folderID)
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
        closeSplitView()
        let tab = BrowserTab(spaceID: space.id, title: "New Tab", position: session.tabs.count)
        session = BrowserSessionState(
            spaces: session.spaces + [space],
            tabs: session.tabs + [tab],
            folders: session.folders,
            activeSpaceID: space.id,
            activeTabID: tab.id,
            isPrivate: session.isPrivate
        )
        syncFocusedPane(with: tab.id)
        activePanel = .none
        addressText = ""
        refreshNavigationState()
        persistSession()
        statusMessage = "Group “\(name)” created"
        return space.id
    }

    /// `thenSelect` names a specific tab to land on after the switch — the
    /// palette's cross-space jump uses it so the tab the user clicked is the
    /// one that activates, not whatever was most recent in that space.
    public func switchGroup(_ spaceID: SpaceID, thenSelect requestedTabID: TabID? = nil) {
        // Every space choice invalidates a pending unlock: if the user picks
        // another space while the system prompt is up, that choice wins and
        // the abandoned unlock must not yank the window somewhere else.
        spaceSwitchToken &+= 1
        let token = spaceSwitchToken
        guard let space = session.spaces.first(where: { $0.id == spaceID }),
              spaceID != session.activeSpaceID else {
            // Already in the space: a thenSelect still applies.
            if spaceID == session.activeSpaceID, let requestedTabID {
                selectTab(requestedTabID)
            }
            return
        }
        // A locked space asks for Touch ID (or the login password) first.
        guard space.isLocked, !unlockedSpaceIDs.contains(spaceID) else {
            performSwitchGroup(spaceID, thenSelect: requestedTabID)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let authenticator = self.spaceUnlockAuthenticator ?? BiometricSpaceUnlockAuthenticator()
            let granted = await authenticator.authenticate(reason: "Unlock “\(space.name)”")
            guard self.spaceSwitchToken == token else { return }
            guard granted else {
                self.statusMessage = "“\(space.name)” stayed locked"
                return
            }
            self.unlockedSpaceIDs.insert(spaceID)
            self.performSwitchGroup(spaceID, thenSelect: requestedTabID)
        }
    }

    /// The actual space switch. `switchGroup` gates locked spaces and calls
    /// this once authentication has succeeded. A requested tab wins over the
    /// most-recently-used pick when it belongs to the destination space.
    private func performSwitchGroup(_ spaceID: SpaceID, thenSelect requestedTabID: TabID? = nil) {
        guard session.spaces.contains(where: { $0.id == spaceID }),
              spaceID != session.activeSpaceID else { return }
        // Split panes show this space's tabs; they never carry into another.
        closeSplitView()
        var tabs = session.tabs
        var target = requestedTabID.flatMap { id in
            tabs.first(where: { $0.id == id && $0.spaceID == spaceID })?.id
        } ?? tabs.filter { $0.spaceID == spaceID }.max { $0.lastAccessedAt < $1.lastAccessedAt }?.id
        if target == nil {
            let tab = BrowserTab(spaceID: spaceID, title: "New Tab", position: tabs.count)
            tabs.append(tab)
            target = tab.id
        }
        // Landing on a tab makes it the space's most recent — a later switch
        // back lands here again, which is what the strip implies.
        if let target {
            tabs = tabs.map { $0.id == target ? $0.replaced(lastAccessedAt: Date()) : $0 }
        }
        let folders = target.map { Self.expandedFolders(around: $0, in: session.folders, tabs: tabs) } ?? session.folders
        session = BrowserSessionState(
            spaces: session.spaces,
            tabs: tabs,
            folders: folders,
            activeSpaceID: spaceID,
            activeTabID: target,
            isPrivate: session.isPrivate
        )
        activePanel = .none
        if let target {
            let url = tabURLs[target] ?? session.tabs.first { $0.id == target }?.lastCommittedURL
            addressText = displayAddress(for: url, tabID: target)
        } else {
            addressText = ""
        }
        syncFocusedPane(with: target)
        refreshNavigationState()
        persistSession()
        if let target {
            Task { await environment.engine.activate(tabID: target, in: paneID) }
        }
    }

    // MARK: - Locked spaces

    /// The authenticator behind locked spaces. Swappable so tests drive the
    /// gating without a system prompt.
    public var spaceUnlockAuthenticator: (any SpaceUnlockAuthenticating)?

    /// Spaces unlocked for this run. The lock re-applies on every launch:
    /// unlocking is a moment, not a setting.
    public private(set) var unlockedSpaceIDs: Set<SpaceID> = []

    /// Bumped on every space choice so a slow unlock cannot override a newer
    /// one.
    private var spaceSwitchToken = 0

    public func isSpaceLocked(_ spaceID: SpaceID) -> Bool {
        session.spaces.first { $0.id == spaceID }?.isLocked ?? false
    }

    /// Whether a space's tabs may be shown right now.
    public func isSpaceUnlocked(_ spaceID: SpaceID) -> Bool {
        !isSpaceLocked(spaceID) || unlockedSpaceIDs.contains(spaceID)
    }

    /// Locks or unlocks a space. Locking always leaves at least one unlocked
    /// space: a browser whose every space is locked could not be used.
    public func setSpaceLocked(_ spaceID: SpaceID, locked: Bool) {
        guard let space = session.spaces.first(where: { $0.id == spaceID }) else { return }
        if locked {
            let remainingUnlocked = session.spaces.filter { $0.id != spaceID && !$0.isLocked }
            guard !remainingUnlocked.isEmpty else {
                statusMessage = "Keep at least one space unlocked"
                return
            }
        }
        let spaces = session.spaces.map { $0.id == spaceID ? $0.withLocked(locked) : $0 }
        session = BrowserSessionState(
            spaces: spaces,
            tabs: session.tabs,
            folders: session.folders,
            activeSpaceID: session.activeSpaceID,
            activeTabID: session.activeTabID,
            isPrivate: session.isPrivate
        )
        if locked {
            unlockedSpaceIDs.remove(spaceID)
        } else {
            unlockedSpaceIDs.insert(spaceID)
        }
        persistSession()
        statusMessage = locked
            ? "“\(space.name)” now asks for Touch ID or your password"
            : "“\(space.name)” no longer locks"
        // Locking the space you are standing in locks it immediately: the
        // window moves to an unlocked space rather than sitting half-open
        // inside a space the palette and tab switcher now hide.
        if locked, session.activeSpaceID == spaceID {
            lockSpaceNow(spaceID)
        }
    }

    /// Re-locks a space immediately. Locking the space you are in moves you
    /// to an unlocked one rather than hiding the window.
    public func lockSpaceNow(_ spaceID: SpaceID) {
        guard isSpaceLocked(spaceID) else { return }
        unlockedSpaceIDs.remove(spaceID)
        guard session.activeSpaceID == spaceID else {
            statusMessage = "Space locked"
            return
        }
        guard let fallback = session.spaces.first(where: { $0.id != spaceID && isSpaceUnlocked($0.id) }) else {
            unlockedSpaceIDs.insert(spaceID)
            statusMessage = "Create another space before locking this one"
            return
        }
        performSwitchGroup(fallback.id)
        statusMessage = "Space locked"
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
            folders: session.folders,
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
        if spaceID == session.activeSpaceID {
            closeSplitView()
        }
        let doomed = session.tabs.filter { $0.spaceID == spaceID }
        for tab in doomed {
            environment.engine.discard(tabID: tab.id)
            tabURLs[tab.id] = nil
            searchDisplayByTab[tab.id] = nil
            // Each closed tab is a removal extensions can observe.
            notifyExtensionsOfStripChange(closed: tab.id)
        }
        unlockedSpaceIDs.remove(spaceID)
        var spaces = session.spaces.filter { $0.id != spaceID }
        var tabs = session.tabs.filter { $0.spaceID != spaceID }
        // A deleted group takes its folders with it.
        let folders = session.folders.filter { $0.spaceID != spaceID }
        var nextActiveTab = session.activeTabID
        var nextSpace = session.activeSpaceID
        if session.activeSpaceID == spaceID {
            // Land on an unlocked space — never inside a locked one, whose
            // tabs the lock exists to hide. A destination with no tabs gets a
            // fresh one, and if every remaining space is somehow locked a
            // fresh space keeps the browser usable.
            if let unlocked = spaces.first(where: { isSpaceUnlocked($0.id) }) {
                nextSpace = unlocked.id
            } else {
                let fresh = BrowserSpace(name: "Personal")
                spaces.append(fresh)
                nextSpace = fresh.id
            }
            nextActiveTab = tabs.filter { $0.spaceID == nextSpace }.max { $0.lastAccessedAt < $1.lastAccessedAt }?.id
            if nextActiveTab == nil {
                let tab = BrowserTab(spaceID: nextSpace, title: "New Tab", position: tabs.count)
                tabs.append(tab)
                nextActiveTab = tab.id
            }
        }
        session = BrowserSessionState(
            spaces: spaces,
            tabs: tabs,
            folders: folders,
            activeSpaceID: nextSpace,
            activeTabID: nextActiveTab,
            isPrivate: session.isPrivate
        )
        syncFocusedPane(with: nextActiveTab)
        if let nextActiveTab {
            let url = tabURLs[nextActiveTab] ?? activeTab?.lastCommittedURL
            addressText = displayAddress(for: url, tabID: nextActiveTab)
        } else {
            addressText = ""
        }
        refreshNavigationState()
        persistSession()
        statusMessage = "Deleted “\(space.name)”"
    }

    public func moveTab(_ tabID: TabID, toGroup spaceID: SpaceID) {
        guard let tab = session.tabs.first(where: { $0.id == tabID }),
              tab.spaceID != spaceID,
              session.spaces.contains(where: { $0.id == spaceID }) else { return }
        let folderID = tab.folderID
        updateTab(tabID) { tab in
            // Folders belong to a space, so a tab that changes groups leaves
            // its folder behind.
            tab.replaced(spaceID: spaceID, folderID: .some(nil))
        }
        pruneFolderIfEmpty(folderID)
        removeTabFromPanes(tabID)
        // The primary pane cannot just drop its tab the way a split pane can —
        // something must show there. If the moved tab occupied the primary
        // while another pane was focused, the focused pane folds back into
        // the primary rather than leaving a tab from another space on screen.
        // (When the moved tab was itself focused, the space switch below
        // rebuilds the panes, so this does not run.)
        if paneTabIDs[paneID] == tabID, activePaneID != paneID,
           let focused = paneTabIDs[activePaneID] {
            paneOrder.removeAll { $0 == activePaneID }
            paneTabIDs[activePaneID] = nil
            paneTabIDs[paneID] = focused
            activePaneID = paneID
        }
        // If the active tab just left the visible group, follow it.
        if session.activeTabID == tabID, spaceID != session.activeSpaceID {
            switchGroup(spaceID)
        }
        persistSession()
    }

    /// Drops a folder record once its last member has left it. A folder that
    /// was created empty and never held a tab is left alone.
    private func pruneFolderIfEmpty(_ folderID: FolderID?) {
        guard let folderID,
              session.folders.contains(where: { $0.id == folderID }),
              !session.tabs.contains(where: { $0.folderID == folderID }) else { return }
        session = BrowserSessionState(
            spaces: session.spaces,
            tabs: session.tabs,
            folders: session.folders.filter { $0.id != folderID },
            activeSpaceID: session.activeSpaceID,
            activeTabID: session.activeTabID,
            isPrivate: session.isPrivate
        )
    }

    // MARK: - Tab folders

    /// Folders in the active space, in creation order.
    public var activeFolders: [TabFolder] {
        session.folders.filter { $0.spaceID == session.activeSpaceID }
    }

    public func folder(_ folderID: FolderID) -> TabFolder? {
        session.folders.first { $0.id == folderID }
    }

    /// The folder list with the folder containing `tabID` expanded, if it was
    /// collapsed. Used whenever a tab becomes active so it is never hidden.
    private static func expandedFolders(around tabID: TabID, in folders: [TabFolder], tabs: [BrowserTab]) -> [TabFolder] {
        guard let folderID = tabs.first(where: { $0.id == tabID })?.folderID,
              folders.contains(where: { $0.id == folderID && $0.isCollapsed }) else {
            return folders
        }
        return folders.map { $0.id == folderID ? $0.withCollapsed(false) : $0 }
    }

    /// Tabs in the active space that belong to a folder, in strip order.
    public func tabs(inFolder folderID: FolderID) -> [BrowserTab] {
        visibleTabs.filter { $0.folderID == folderID }
    }

    @discardableResult
    public func createFolder(named name: String, color: String? = nil) -> FolderID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = TabFolder(
            spaceID: session.activeSpaceID,
            name: trimmed.isEmpty ? "New Folder" : trimmed,
            color: color
        )
        session = BrowserSessionState(
            spaces: session.spaces,
            tabs: session.tabs,
            folders: session.folders + [folder],
            activeSpaceID: session.activeSpaceID,
            activeTabID: session.activeTabID,
            isPrivate: session.isPrivate
        )
        persistSession()
        statusMessage = "Folder “\(folder.name)” created"
        return folder.id
    }

    /// Files a tab into a folder, or takes it out when `folderID` is nil.
    /// The tab moves next to the folder's other tabs so members stay
    /// contiguous in the strip. Pinned tabs cannot be filed.
    public func assignTab(_ tabID: TabID, toFolder folderID: FolderID?) {
        guard let tab = session.tabs.first(where: { $0.id == tabID }) else { return }
        if let folderID {
            guard let folder = folder(folderID), folder.spaceID == tab.spaceID else { return }
            guard !tab.isPinned else {
                statusMessage = "Unpin the tab before adding it to a folder"
                return
            }
        }
        let previousFolderID = tab.folderID
        var tabs = session.tabs
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let moved = tabs.remove(at: index).replaced(folderID: .some(folderID))
        if let folderID, let lastMember = tabs.lastIndex(where: { $0.folderID == folderID }) {
            tabs.insert(moved, at: lastMember + 1)
        } else if folderID == nil, let previousFolderID,
                  let lastMember = tabs.lastIndex(where: { $0.folderID == previousFolderID }) {
            // Leaving a folder: step out after the remaining members so the
            // folder's run stays contiguous.
            tabs.insert(moved, at: lastMember + 1)
        } else {
            tabs.insert(moved, at: min(index, tabs.count))
        }
        tabs = tabs.enumerated().map { position, tab in
            tab.replaced(position: position)
        }
        // An emptied folder disappears with its last member.
        var folders = session.folders
        if let previousFolderID, previousFolderID != folderID,
           !tabs.contains(where: { $0.folderID == previousFolderID }) {
            folders.removeAll { $0.id == previousFolderID }
        }
        session = BrowserSessionState(
            spaces: session.spaces,
            tabs: tabs,
            folders: folders,
            activeSpaceID: session.activeSpaceID,
            activeTabID: session.activeTabID,
            isPrivate: session.isPrivate
        )
        persistSession()
    }

    public func toggleFolderCollapsed(_ folderID: FolderID) {
        let folders = session.folders.map { folder in
            folder.id == folderID ? folder.withCollapsed(!folder.isCollapsed) : folder
        }
        session = BrowserSessionState(
            spaces: session.spaces,
            tabs: session.tabs,
            folders: folders,
            activeSpaceID: session.activeSpaceID,
            activeTabID: session.activeTabID,
            isPrivate: session.isPrivate
        )
        persistSession()
    }

    public func renameFolder(_ folderID: FolderID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let folders = session.folders.map { folder in
            folder.id == folderID ? folder.renamed(trimmed) : folder
        }
        session = BrowserSessionState(
            spaces: session.spaces,
            tabs: session.tabs,
            folders: folders,
            activeSpaceID: session.activeSpaceID,
            activeTabID: session.activeTabID,
            isPrivate: session.isPrivate
        )
        persistSession()
    }

    /// Dissolves a folder: its tabs stay open, exactly where they are.
    public func ungroupFolder(_ folderID: FolderID) {
        guard let folder = folder(folderID) else { return }
        let tabs = session.tabs.map { tab in
            tab.folderID == folderID ? tab.replaced(folderID: .some(nil)) : tab
        }
        let folders = session.folders.filter { $0.id != folderID }
        session = BrowserSessionState(
            spaces: session.spaces,
            tabs: tabs,
            folders: folders,
            activeSpaceID: session.activeSpaceID,
            activeTabID: session.activeTabID,
            isPrivate: session.isPrivate
        )
        persistSession()
        statusMessage = "Folder “\(folder.name)” ungrouped"
    }

    /// Closes every tab in a folder. The folder itself goes with them.
    public func closeFolder(_ folderID: FolderID) {
        guard let target = folder(folderID) else { return }
        for tab in tabs(inFolder: folderID) {
            closeTab(tab.id)
        }
        if folder(folderID) != nil {
            // No members were live (metadata-only folder): drop the record.
            session = BrowserSessionState(
                spaces: session.spaces,
                tabs: session.tabs,
                folders: session.folders.filter { $0.id != folderID },
                activeSpaceID: session.activeSpaceID,
                activeTabID: session.activeTabID,
                isPrivate: session.isPrivate
            )
            persistSession()
        }
        statusMessage = "Closed folder “\(target.name)”"
    }

    // MARK: - Peek preview

    /// State of the link-preview overlay (Zen's Glance, Arc's peek).
    public struct PeekState: Identifiable, Sendable {
        public let tabID: TabID
        public var url: URL
        public var title: String
        public var id: TabID { tabID }
    }

    /// The preview tab lives in the engine but never in the session: closing
    /// it leaves no tab, no history entry, and nothing persisted. Promoting
    /// it turns the already-loaded page into a real tab.
    public private(set) var peek: PeekState?

    /// The preview gets its own pane so registering it as active never
    /// suspends the real tab it is layered over.
    private let peekPaneID = PaneID()

    /// Opens a link in the preview overlay. A second peek replaces the first.
    public func openPeek(url: URL) {
        hoverPeekTask?.cancel()
        hoverPeekTask = nil
        closePeek()
        let tabID = TabID()
        peek = PeekState(tabID: tabID, url: url, title: url.host ?? url.absoluteString)
        tabURLs[tabID] = url
        statusMessage = nil
        Task {
            await environment.engine.activate(tabID: tabID, in: peekPaneID)
            try? await environment.engine.navigate(tabID: tabID, to: NavigationRequest(url: url))
        }
    }

    public func closePeek() {
        guard let peek else { return }
        environment.engine.discard(tabID: peek.tabID)
        tabURLs[peek.tabID] = nil
        self.peek = nil
    }

    /// Pending hover-peek, cancelled the moment the pointer leaves the link.
    private var hoverPeekTask: Task<Void, Never>?

    /// Opt-in link preview on hover (Settings → "Preview links on hover").
    /// Debounced so brushing across a page of links opens nothing, and an
    /// open peek is never replaced by the pointer wandering underneath it —
    /// the user may be reading it.
    private func updateHoverPeek(for url: URL?) {
        hoverPeekTask?.cancel()
        hoverPeekTask = nil
        guard environment.loadSettings().linkPreviewOnHover,
              let url, peek == nil else { return }
        // Only real pages are previewable — a javascript: or mailto: link
        // must never load on hover.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        hoverPeekTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled else { return }
            guard self.hoveredLinkURL == url, self.peek == nil else { return }
            self.openPeek(url: url)
        }
    }

    /// Turns the preview into a real tab. The page is already loaded, so
    /// this adopts the same engine tab — no reload, no lost scroll position.
    @discardableResult
    public func promotePeekToTab() -> TabID? {
        guard let peek else { return nil }
        let tab = BrowserTab(
            id: peek.tabID,
            spaceID: session.activeSpaceID,
            title: peek.title,
            lastCommittedURL: peek.url,
            position: session.tabs.count,
            lifecycle: .active
        )
        session = BrowserSessionState(
            spaces: session.spaces,
            tabs: session.tabs + [tab],
            folders: session.folders,
            activeSpaceID: session.activeSpaceID,
            activeTabID: tab.id,
            isPrivate: session.isPrivate
        )
        self.peek = nil
        activePanel = .none
        searchDisplayByTab[tab.id] = nil
        addressText = peek.url.absoluteString
        refreshNavigationState()
        // The page becomes part of the browsing record only once it is a real
        // tab; a preview the user closed leaves no trace.
        recordHistory(url: peek.url, title: peek.title)
        persistSession()
        syncFocusedPane(with: tab.id)
        Task { await environment.engine.activate(tabID: tab.id, in: activePaneID) }
        return tab.id
    }

    // MARK: - Split view

    /// Every pane's tab. The primary pane is `paneID`; a split adds panes in
    /// `paneOrder`. `session.activeTabID` always mirrors the focused pane's
    /// tab, so the toolbar, address bar, and assistant follow the pane the
    /// user last clicked in.
    public private(set) var paneTabIDs: [PaneID: TabID] = [:]
    /// Panes in display order; the first is the primary pane.
    public private(set) var paneOrder: [PaneID] = []
    public private(set) var activePaneID = PaneID()

    /// Four is the ceiling: beyond that every pane is a column too narrow to
    /// read, and the engine keeps a live web view per pane.
    private static let maximumPanes = 4

    public var isSplitViewActive: Bool { paneOrder.count > 1 }

    /// True when this tab is currently tiled in a split pane. The strip and
    /// sidebar use it to mark those tabs; a tab that is merely open is not.
    public func isTabInSplit(_ tabID: TabID) -> Bool {
        guard isSplitViewActive else { return false }
        return paneTabIDs.values.contains(tabID)
    }

    /// The tiled panes, primary first, resolved against the session.
    public var visiblePanes: [(pane: PaneID, tab: BrowserTab)] {
        paneOrder.compactMap { pane in
            guard let tabID = paneTabIDs[pane],
                  let tab = session.tabs.first(where: { $0.id == tabID }) else { return nil }
            return (pane, tab)
        }
    }

    /// Tiles a tab beside the focused pane. The tab keeps its place in the
    /// strip; the pane is just another view onto it.
    public func openInSplitView(_ tabID: TabID) {
        guard let tab = session.tabs.first(where: { $0.id == tabID }),
              tab.spaceID == session.activeSpaceID else { return }
        if paneTabIDs[activePaneID] == tabID { return }
        if let existing = paneOrder.first(where: { $0 != activePaneID && paneTabIDs[$0] == tabID }) {
            // Already tiled in another pane: focus it rather than duplicate.
            focusPane(existing)
            return
        }
        if paneOrder.count >= Self.maximumPanes {
            statusMessage = "Split view holds up to \(Self.maximumPanes) panes"
            return
        }
        let pane = PaneID()
        paneOrder.append(pane)
        paneTabIDs[pane] = tabID
        ensureLoaded(tabID)
        Task { await environment.engine.activate(tabID: tabID, in: pane) }
    }

    /// Splits with the most recently used other tab in this space, or with a
    /// fresh tab when there is nothing else to show. Toggling again closes.
    @discardableResult
    public func toggleSplitView() -> TabID? {
        if isSplitViewActive {
            closeSplitView()
            return nil
        }
        let candidate = session.tabs
            .filter { $0.spaceID == session.activeSpaceID && $0.id != session.activeTabID }
            .max { $0.lastAccessedAt < $1.lastAccessedAt }?.id
        if let candidate {
            openInSplitView(candidate)
            return candidate
        }
        // Nothing else to show: a fresh tab beside the current one.
        let previous = session.activeTabID
        let fresh = newTab()
        if let previous, previous != fresh {
            openInSplitView(previous)
        }
        return fresh
    }

    // MARK: - Drag-to-edge split

    /// True while a tab is being dragged out of the strip; the content area
    /// shows its edge drop zones only then, so they can never sit under the
    /// pointer during ordinary clicking.
    public private(set) var isTabDragActive = false
    private var tabDragResetTask: Task<Void, Never>?

    /// Called when a tab drag begins. The flag clears when a drop lands or
    /// after a timeout — `.onDrag` has no end callback, so the timeout is the
    /// safety net for a drag that ends outside any drop target.
    public func beginTabDrag() {
        isTabDragActive = true
        tabDragResetTask?.cancel()
        tabDragResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled else { return }
            self.isTabDragActive = false
        }
    }

    /// Ends the drag (drop landed anywhere, or the drag was cancelled).
    public func endTabDrag() {
        tabDragResetTask?.cancel()
        tabDragResetTask = nil
        isTabDragActive = false
    }

    /// A tab dropped on a content edge tiles beside the focused pane. The
    /// focused pane's own tab cannot split with itself, so dropping it tiles
    /// the most recent other tab instead — the same thing the ⇧⌘D toggle does.
    public func dropTabOnSplitEdge(_ tabID: TabID) {
        endTabDrag()
        guard let tab = session.tabs.first(where: { $0.id == tabID }),
              tab.spaceID == session.activeSpaceID else { return }
        if paneTabIDs[activePaneID] == tabID {
            toggleSplitView()
        } else {
            openInSplitView(tabID)
        }
    }

    /// Collapses every split. The tabs stay open in the strip.
    public func closeSplitView() {        guard isSplitViewActive else { return }
        for pane in paneOrder.dropFirst() {
            if let tabID = paneTabIDs[pane] {
                Task { await environment.engine.deactivate(tabID: tabID) }
            }
            paneTabIDs[pane] = nil
        }
        paneOrder = [paneID]
        activePaneID = paneID
    }

    /// Closes one split pane; its tab stays open in the strip.
    public func closeSplitPane(_ pane: PaneID) {
        guard pane != paneID,
              let tabID = paneTabIDs[pane] else { return }
        paneOrder.removeAll { $0 == pane }
        paneTabIDs[pane] = nil
        if activePaneID == pane {
            activePaneID = paneID
            if let primaryTab = paneTabIDs[paneID], primaryTab != session.activeTabID {
                selectTab(primaryTab)
            }
        }
        Task { await environment.engine.deactivate(tabID: tabID) }
    }

    /// Focuses a pane by clicking into it. The session's active tab follows.
    public func focusPane(_ pane: PaneID) {
        guard pane != activePaneID, let tabID = paneTabIDs[pane] else { return }
        selectTab(tabID)
    }

    /// Promotes the preview into a real tab and tiles the page it was opened
    /// from beside it — the "preview, then compare side by side" flow.
    @discardableResult
    public func promotePeekToSplitView() -> TabID? {
        let previousActive = session.activeTabID
        guard let promoted = promotePeekToTab() else { return nil }
        if let previousActive, previousActive != promoted {
            openInSplitView(previousActive)
        }
        return promoted
    }

    /// Keeps the focused pane's slot in step with the session's active tab.
    /// Called from every path that changes `session.activeTabID` outside the
    /// pane commands — a close picking a neighbour, a group switch, and so on.
    /// A tab already tiled in another pane gets that pane focused instead:
    /// two panes must never show the same tab.
    private func syncFocusedPane(with tabID: TabID?) {
        if let tabID,
           let existing = paneOrder.first(where: { $0 != activePaneID && paneTabIDs[$0] == tabID }) {
            activePaneID = existing
        } else {
            paneTabIDs[activePaneID] = tabID
        }
    }

    /// Drops a tab out of any pane it was tiled in. A closed or moved tab
    /// must never leave a pane showing it.
    private func removeTabFromPanes(_ tabID: TabID) {
        guard let pane = paneOrder.first(where: { paneTabIDs[$0] == tabID }) else { return }
        if pane == paneID {
            // The primary pane mirrors the active tab and is synced by the
            // caller once the new active tab is known.
            return
        }
        paneOrder.removeAll { $0 == pane }
        paneTabIDs[pane] = nil
        if activePaneID == pane {
            activePaneID = paneID
        }
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
    public var isTranslating = false
    public var readerTranslationRequested = false
    public var readerTranslationNote: String?

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
        readerTranslationNote = nil
        readerTranslationRequested = false
        isTranslating = false
    }

    public func translatePage() {
        guard #available(macOS 15.0, *) else {
            statusMessage = "Page translation needs macOS 15 or newer."
            return
        }
        guard let tabID = session.activeTabID else { return }
        isReaderLoading = true
        Task {
            defer { isReaderLoading = false }
            do {
                readerArticle = try await environment.engine.extractArticle(tabID: tabID)
                readerTranslationNote = nil
                activePanel = .none
                readerTranslationRequested = true
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    public func applyTranslatedArticle(_ text: String) {
        guard let article = readerArticle, !text.isEmpty else { return }
        readerArticle = ReaderArticle(title: article.title, url: article.url, text: text)
        readerTranslationNote = "Translated on this Mac"
    }

    public func failTranslation(_ message: String) {
        statusMessage = message
    }

    public func requestReaderTranslation() {
        guard readerArticle != nil else {
            translatePage()
            return
        }
        guard #available(macOS 15.0, *) else {
            statusMessage = "Page translation needs macOS 15 or newer."
            return
        }
        readerTranslationRequested = true
    }

    /// Whether this site should open in Reader automatically.
    public func prefersReader(for url: URL?) -> Bool {
        guard let origin = url?.host else { return false }
        return (try? environment.sitePreferenceRepository.value(origin: origin, preference: "reader")) == "always"
    }

    public var activePageURL: URL? {
        guard let tabID = session.activeTabID else { return nil }
        return tabURLs[tabID] ?? activeTab?.lastCommittedURL
    }

    public var activePageHost: String? {
        Self.zoomHost(of: activePageURL)
    }

    public var activeZoomPercent: Int {
        _ = zoomDisplayRevision
        guard let tabID = session.activeTabID else { return 100 }
        return Int((environment.engine.currentZoom(tabID: tabID) * 100).rounded())
    }

    /// The site shield popover. Shared so the picker can open it for the
    /// confirmation step instead of inventing a second surface.
    public var isSiteShieldPresented = false
    /// Set while the element picker is armed on the active tab.
    public private(set) var isPickingElement = false
    /// A picked element waiting for the user to confirm hiding it, and the
    /// host it was picked on — confirming after a tab switch must still save
    /// the rule against the site it came from.
    public private(set) var pendingElementPick: ElementPick?
    private var pendingElementPickHost: String?
    /// Bumped whenever the rule set changes so views re-read the lists.
    private var cosmeticRulesRevision = 0
    /// Rules created in a private window. Session-scoped: never persisted.
    private var privateCosmeticRules: [String: [CosmeticRule]] = [:]

    public func isBlockingPaused(for url: URL?) -> Bool {
        guard !session.isPrivate, let host = Self.zoomHost(of: url) else { return false }
        let stored = try? environment.sitePreferenceRepository.value(
            origin: host,
            preference: ProtectionLevel.blockingPreference
        )
        return stored == ProtectionLevel.blockingPausedValue
    }

    public var siteShieldStatus: String {
        let level = currentSettings().protectionLevel
        if session.isPrivate {
            return "\(level.title). A private window does not remember this."
        }
        if !level.blocksContentRules {
            return "\(level.title). Bundled rules are off."
        }
        if isBlockingPaused(for: activePageURL) {
            return "\(level.title). Blocking is paused on this site."
        }
        return "\(level.title). Bundled rules are on for this site."
    }

    public func setBlockingPaused(_ paused: Bool) {
        guard !session.isPrivate else {
            statusMessage = "A private window does not remember site exceptions."
            return
        }
        guard let host = activePageHost, let tabID = session.activeTabID else { return }
        do {
            if paused {
                try environment.sitePreferenceRepository.set(
                    origin: host,
                    preference: ProtectionLevel.blockingPreference,
                    value: ProtectionLevel.blockingPausedValue
                )
                statusMessage = "Blocking paused on \(host)"
            } else {
                try environment.sitePreferenceRepository.remove(
                    origin: host,
                    preference: ProtectionLevel.blockingPreference
                )
                statusMessage = "Blocking resumed on \(host)"
            }
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        environment.engine.setContentRulesPaused(tabID: tabID, paused: paused)
        refreshPausedBlockingHosts()
        reload()
    }

    private func applySiteBlocking(tabID: TabID, url: URL) {
        let paused = isBlockingPaused(for: url)
        environment.engine.setContentRulesPaused(tabID: tabID, paused: paused)
    }

    private func refreshPausedBlockingHosts() {
        let hosts = (try? environment.sitePreferenceRepository.origins(
            preference: ProtectionLevel.blockingPreference,
            value: ProtectionLevel.blockingPausedValue
        )) ?? []
        environment.engine.replacePausedBlockingHosts(hosts)
    }

    // MARK: - Element hiding

    /// Arms the picker (⌘⇧H) on the active tab.
    public func beginElementHiding() {
        guard let tabID = session.activeTabID, activePageURL != nil else {
            statusMessage = "No page to pick an element from."
            return
        }
        guard environment.engine.isLive(tabID: tabID) else {
            statusMessage = "This tab is not loaded yet."
            return
        }
        guard !isReaderModeActive else {
            statusMessage = "Element hiding works on the page, not in Reader."
            return
        }
        environment.engine.beginElementPicking(tabID: tabID)
        isPickingElement = true
        statusMessage = "Click the element to hide. Esc cancels."
    }

    /// Saves the picked element's rule and applies it to the open page.
    public func confirmElementHiding() {
        guard let pick = pendingElementPick, let host = pendingElementPickHost else { return }
        pendingElementPick = nil
        pendingElementPickHost = nil
        if session.isPrivate {
            var rules = privateCosmeticRules[host] ?? []
            rules.append(CosmeticRule(host: host, selector: pick.selector, label: pick.label))
            privateCosmeticRules[host] = rules
            statusMessage = "Element hidden for this private window"
        } else {
            do {
                try environment.cosmeticRuleRepository.add(host: host, selector: pick.selector, label: pick.label)
                statusMessage = "Element hidden on \(host)"
            } catch {
                statusMessage = error.localizedDescription
                return
            }
        }
        refreshCosmeticRules()
    }

    public func cancelElementHiding() {
        if isPickingElement, let tabID = session.activeTabID {
            environment.engine.cancelElementPicking(tabID: tabID)
        }
        isPickingElement = false
        pendingElementPick = nil
        pendingElementPickHost = nil
        statusMessage = nil
    }

    /// Rules that apply to a host: saved ones, plus this private window's
    /// temporary ones.
    public func cosmeticRules(for host: String) -> [CosmeticRule] {
        _ = cosmeticRulesRevision
        var rules = (try? environment.cosmeticRuleRepository.rules(host: host)) ?? []
        rules.append(contentsOf: privateCosmeticRules[host.lowercased()] ?? [])
        return rules
    }

    public func setCosmeticRuleEnabled(_ rule: CosmeticRule, enabled: Bool) {
        if let temporary = privateCosmeticRules[rule.host], temporary.contains(where: { $0.id == rule.id }) {
            privateCosmeticRules[rule.host] = temporary.map { existing in
                var copy = existing
                if copy.id == rule.id { copy.isEnabled = enabled }
                return copy
            }
        } else {
            do {
                try environment.cosmeticRuleRepository.setEnabled(enabled, id: rule.id)
            } catch {
                statusMessage = error.localizedDescription
                return
            }
        }
        refreshCosmeticRules()
        statusMessage = enabled ? "Rule turned back on" : "Rule turned off"
    }

    /// The undo for hiding: the rule is deleted and the element returns.
    public func removeCosmeticRule(_ rule: CosmeticRule) {
        if let temporary = privateCosmeticRules[rule.host], temporary.contains(where: { $0.id == rule.id }) {
            privateCosmeticRules[rule.host] = temporary.filter { $0.id != rule.id }
        } else {
            do {
                try environment.cosmeticRuleRepository.remove(id: rule.id)
            } catch {
                statusMessage = error.localizedDescription
                return
            }
        }
        refreshCosmeticRules()
        statusMessage = "Element shown again"
    }

    /// Rebuilds the per-host CSS the engine injects. Called at launch, after
    /// a profile switch, and after any rule change.
    private func refreshCosmeticRules() {
        var rulesByHost: [String: String] = [:]
        for host in (try? environment.cosmeticRuleRepository.hosts()) ?? [] {
            let rules = (try? environment.cosmeticRuleRepository.rules(host: host)) ?? []
            let css = CosmeticRuleRepository.css(for: rules)
            if !css.isEmpty { rulesByHost[host] = css }
        }
        for (host, rules) in privateCosmeticRules {
            let css = CosmeticRuleRepository.css(for: rules)
            guard !css.isEmpty else { continue }
            rulesByHost[host] = rulesByHost[host].map { $0 + "\n" + css } ?? css
        }
        environment.engine.replaceCosmeticRules(rulesByHost)
        cosmeticRulesRevision += 1
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
        publishZoomDisplayChange()
        persistZoomForActivePage()
    }

    public func zoomOut() {
        guard let tabID = session.activeTabID else { return }
        environment.engine.adjustZoom(tabID: tabID, by: -0.1)
        publishZoomDisplayChange()
        persistZoomForActivePage()
    }

    public func resetZoom() {
        guard let tabID = session.activeTabID else { return }
        environment.engine.resetZoom(tabID: tabID)
        publishZoomDisplayChange()
        if let host = Self.zoomHost(of: activeTab?.lastCommittedURL ?? tabURLs[tabID]) {
            try? environment.sitePreferenceRepository.remove(origin: host, preference: "zoom")
        }
    }

    private func publishZoomDisplayChange() {
        zoomDisplayRevision &+= 1
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
            publishZoomDisplayChange()
            return
        }
        let saved = (try? environment.sitePreferenceRepository.value(origin: host, preference: "zoom"))
            .flatMap { Double($0) }
        environment.engine.setZoom(tabID: tabID, to: saved.map { CGFloat($0) } ?? 1)
        publishZoomDisplayChange()
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
        // The tab's own pane activates it: activating a split pane's tab in
        // the primary pane would suspend the page the user is still looking at.
        let pane = paneOrder.first { paneTabIDs[$0] == tabID } ?? activePaneID
        guard !environment.engine.isLive(tabID: tabID) else {
            Task { await environment.engine.activate(tabID: tabID, in: pane) }
            return
        }
        let url = tabURLs[tabID] ?? session.tabs.first { $0.id == tabID }?.lastCommittedURL
        guard let url else { return }
        tabURLs[tabID] = url
        Task {
            await environment.engine.activate(tabID: tabID, in: pane)
            try? await environment.engine.navigate(tabID: tabID, to: NavigationRequest(url: url))
        }
    }

    public func updateSettings(_ mutate: (inout BrowserSettings) -> Void) {
        var settings = environment.loadSettings()
        mutate(&settings)
        environment.saveSettings(settings)
        appearance = settings.appearance
        searchEngineTemplate = settings.searchEngineTemplate
        isAIDockVisible = settings.isAIDockEnabled
        tabLayout = settings.tabLayout
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

    /// Everything ⌘K searches, all local: the open/search intent, tabs, intent
    /// actions (switch space, move tab, split), commands, history, and
    /// bookmarks. Fuzzy-ranked, so a few letters of a title or host are enough.
    public func filteredCommands(query: String) -> [BrowserPaletteCommand] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return recentTabPaletteCommands(limit: 5) + paletteCommands
        }

        var results: [BrowserPaletteCommand] = []
        if let primary = primaryPaletteIntent(for: trimmedQuery) {
            results.append(primary)
        }
        results += rankedCommands(assistantSkillCommands(), query: trimmedQuery, limit: 4)
        results += rankedCommands(intentPaletteCommands(), query: trimmedQuery, limit: 6)
        results += rankedCommands(tabPaletteCommands(), query: trimmedQuery, limit: 8)
        results += rankedCommands(paletteCommands, query: trimmedQuery, limit: 8)
        results += historyPaletteCommands(matching: trimmedQuery)
        results += rankedCommands(bookmarkPaletteCommands(), query: trimmedQuery, limit: 5)
        return results
    }

    /// Saved skills as palette rows: ⌘K → the first words of a skill runs it.
    private func assistantSkillCommands() -> [BrowserPaletteCommand] {
        aiSkills.map { skill in
            BrowserPaletteCommand(
                id: "skill-\(skill.id.uuidString)",
                title: "Run Skill: \(skill.name)",
                shortcut: "",
                kind: .action,
                subtitle: String(skill.prompt.prefix(80)),
                command: .runAISkill(skill)
            )
        }
    }

    /// Fuzzy-ranks palette rows by their title and subtitle.
    private func rankedCommands(
        _ commands: [BrowserPaletteCommand],
        query: String,
        limit: Int
    ) -> [BrowserPaletteCommand] {
        commands
            .compactMap { command -> (BrowserPaletteCommand, Int)? in
                let best = [command.title, command.subtitle]
                    .compactMap { FuzzyMatcher.score(query: query, candidate: $0) }
                    .max()
                guard let best else { return nil }
                return (command, best)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// The first row: what pressing Return does with exactly this input —
    /// open a URL, or search — resolved the same way the address bar does,
    /// so the two can never disagree.
    private func primaryPaletteIntent(for query: String) -> BrowserPaletteCommand? {
        let template = URL(string: environment.loadSettings().searchEngineTemplate)
            ?? URL(string: SearchEnginePreset.google.template)!
        guard let request = try? NavigationResolver(searchURL: template).resolve(query) else {
            return nil
        }
        // Same heuristic the address bar uses to tell a URL from a search.
        let looksLikeURL = query.contains("://") || (query.contains(".") && !query.contains(" "))
        if looksLikeURL {
            return BrowserPaletteCommand(
                id: "open-url",
                title: "Open \(request.url.absoluteString)",
                shortcut: "↵",
                kind: .action,
                subtitle: "Open in a new tab",
                command: .openURLInNewTab(request.url)
            )
        }
        return BrowserPaletteCommand(
            id: "search",
            title: "Search for “\(query)”",
            shortcut: "↵",
            kind: .action,
            subtitle: "with \(activeSearchEngineName)",
            command: .searchFor(query)
        )
    }

    /// Intent rows: switching space, moving the active tab, tiling tabs in
    /// the split view. Each is a single, explicit action.
    private func intentPaletteCommands() -> [BrowserPaletteCommand] {
        var intents: [BrowserPaletteCommand] = []

        for space in session.spaces where space.id != session.activeSpaceID {
            intents.append(BrowserPaletteCommand(
                id: "switch-space-\(space.id.rawValue.uuidString)",
                title: "Switch to Space: \(space.name)",
                shortcut: "",
                kind: .action,
                subtitle: "Show this space's tabs",
                command: .switchSpace(space.id)
            ))
        }

        if let activeTab {
            for space in session.spaces where space.id != activeTab.spaceID {
                intents.append(BrowserPaletteCommand(
                    id: "move-to-space-\(space.id.rawValue.uuidString)",
                    title: "Move “\(activeTab.title)” to Space: \(space.name)",
                    shortcut: "",
                    kind: .action,
                    subtitle: "Move the active tab",
                    command: .moveTabToSpace(activeTab.id, space.id)
                ))
            }
            for folder in activeFolders where folder.id != activeTab.folderID {
                intents.append(BrowserPaletteCommand(
                    id: "move-to-folder-\(folder.id.rawValue.uuidString)",
                    title: "Move “\(activeTab.title)” to Folder: \(folder.name)",
                    shortcut: "",
                    kind: .action,
                    subtitle: "Move the active tab",
                    command: .assignTabToFolder(activeTab.id, folder.id)
                ))
            }
            if activeTab.folderID != nil {
                intents.append(BrowserPaletteCommand(
                    id: "leave-folder",
                    title: "Remove “\(activeTab.title)” from its Folder",
                    shortcut: "",
                    kind: .action,
                    subtitle: "Move the active tab",
                    command: .assignTabToFolder(activeTab.id, nil)
                ))
            }
        }

        if isSplitViewActive {
            intents.append(BrowserPaletteCommand(
                id: "close-split",
                title: "Close Split View",
                shortcut: "⇧⌘D",
                kind: .action,
                subtitle: "Keep the tabs open",
                command: .toggleSplitView
            ))
        } else {
            for tab in session.tabs
            where tab.spaceID == session.activeSpaceID && tab.id != session.activeTabID {
                intents.append(BrowserPaletteCommand(
                    id: "split-with-\(tab.id.rawValue.uuidString)",
                    title: "Open “\(tab.title)” in Split View",
                    shortcut: "",
                    kind: .action,
                    subtitle: tab.lastCommittedURL?.host ?? "Split view",
                    command: .openTabInSplit(tab.id)
                ))
            }
        }

        return intents
    }

    /// Open tabs as palette results, so ⌘K doubles as a tab switcher: type a
    /// few letters of a page title or address and jump straight to it. The
    /// active tab is never listed — jumping to where you already are is noise.
    /// Tabs in a locked, still-locked space are never listed either: their
    /// titles are exactly what the lock protects.
    private func tabPaletteCommands() -> [BrowserPaletteCommand] {
        session.tabs
            .filter { $0.id != session.activeTabID && isSpaceUnlocked($0.spaceID) }
            .map { tab in
            BrowserPaletteCommand(
                id: "tab-\(tab.id.rawValue.uuidString)",
                title: tab.title,
                shortcut: tab.lastCommittedURL?.host ?? "",
                kind: .tab,
                subtitle: tab.lastCommittedURL?.host ?? "Open tab",
                command: .selectTab(tab.id)
            )
        }
    }

    private func recentTabPaletteCommands(limit: Int) -> [BrowserPaletteCommand] {
        session.tabs
            .filter { $0.id != session.activeTabID && isSpaceUnlocked($0.spaceID) }
            .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
            .prefix(limit)
            .map { tab in
                BrowserPaletteCommand(
                    id: "tab-\(tab.id.rawValue.uuidString)",
                    title: tab.title,
                    shortcut: tab.lastCommittedURL?.host ?? "",
                    kind: .tab,
                    subtitle: tab.lastCommittedURL?.host ?? "Open tab",
                    command: .selectTab(tab.id)
                )
            }
    }

    /// Recent history, fuzzy-matched. Read from the local database only.
    private func historyPaletteCommands(matching query: String) -> [BrowserPaletteCommand] {
        let openTabURLs = Set(session.tabs.compactMap { tab -> String? in
            (tabURLs[tab.id] ?? tab.lastCommittedURL)?.absoluteString
        })
        var seen = openTabURLs
        return (try? environment.historyRepository.recent(limit: 200))?
            .compactMap { visit -> (BrowserPaletteCommand, Int)? in
                guard seen.insert(visit.url.absoluteString).inserted else { return nil }
                let title = visit.title.isEmpty ? (visit.url.host ?? visit.url.absoluteString) : visit.title
                let best = [title, visit.url.absoluteString]
                    .compactMap { FuzzyMatcher.score(query: query, candidate: $0) }
                    .max()
                guard let best else { return nil }
                return (BrowserPaletteCommand(
                    id: "history-\(visit.url.absoluteString)",
                    title: title,
                    shortcut: visit.url.host ?? "",
                    kind: .history,
                    subtitle: visit.url.host ?? visit.url.absoluteString,
                    command: .openURLInNewTab(visit.url)
                ), best)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map(\.0) ?? []
    }

    private func bookmarkPaletteCommands() -> [BrowserPaletteCommand] {
        bookmarks.map { bookmark in
            BrowserPaletteCommand(
                id: "bookmark-\(bookmark.url.absoluteString)",
                title: bookmark.title.isEmpty ? (bookmark.url.host ?? bookmark.url.absoluteString) : bookmark.title,
                shortcut: bookmark.url.host ?? "",
                kind: .bookmark,
                subtitle: bookmark.url.host ?? bookmark.url.absoluteString,
                command: .openURLInNewTab(bookmark.url)
            )
        }
    }

    /// Searches with the configured engine, in a new tab — the palette's
    /// fallback for input that is not a URL.
    public func searchInNewTab(_ query: String) {
        let template = URL(string: environment.loadSettings().searchEngineTemplate)
            ?? URL(string: SearchEnginePreset.google.template)!
        guard let detail = try? NavigationResolver(searchURL: template).resolveDetail(query) else { return }
        let tabID = newTab(url: detail.request.url)
        if detail.isSearch {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            searchDisplayByTab[tabID] = SearchDisplay(query: trimmed, url: detail.request.url)
            if session.activeTabID == tabID {
                addressText = trimmed
            }
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
        case .toggleTabLayout:
            toggleTabLayout()
        case .toggleSplitView:
            toggleSplitView()
        case .switchSpace(let spaceID):
            switchGroup(spaceID)
        case .openURLInNewTab(let url):
            _ = newTab(url: url)
        case .searchFor(let query):
            searchInNewTab(query)
        case .moveTabToSpace(let tabID, let spaceID):
            moveTab(tabID, toGroup: spaceID)
        case .assignTabToFolder(let tabID, let folderID):
            assignTab(tabID, toFolder: folderID)
        case .openTabInSplit(let tabID):
            openInSplitView(tabID)
        case .runAISkill(let skill):
            requestAssistantTask(.skill(skill))
        case .summarizeOpenTabs:
            requestAssistantTask(.summarizeOpenTabs)
        case .duplicateTab(let tabID):
            let target = session.tabs.contains(where: { $0.id == tabID }) ? tabID : session.activeTabID
            if let target { duplicateTab(target) }
        case .copyTabURL(let tabID):
            let target = session.tabs.contains(where: { $0.id == tabID }) ? tabID : session.activeTabID
            if let target { copyURL(of: target) }
        case .selectAdjacentTab(let forward):
            selectAdjacentTab(forward: forward)
        case .closeOtherTabs(let tabID):
            let target = session.tabs.contains(where: { $0.id == tabID }) ? tabID : session.activeTabID
            if let target { closeOtherTabs(around: target) }
        case .newPrivateWindow:
            // The palette view (which can open windows) intercepts this; the
            // model path just arms the request so the next window complies.
            PrivateWindowRequest.shared.arm()
        }
    }

    /// Flips the tab chrome between the top strip and the sidebar. Stored as
    /// a normal setting so the choice survives relaunches.
    public func toggleTabLayout() {
        updateSettings { $0.tabLayout = $0.tabLayout == .sidebar ? .top : .sidebar }
    }

    /// The engine new searches use, from settings.
    public var activeSearchEngine: SearchEnginePreset? {
        SearchEnginePreset.preset(for: searchEngineTemplate)
    }

    public var activeSearchEngineName: String {
        SearchEnginePreset.name(for: searchEngineTemplate)
    }

    public func selectSearchEngine(_ preset: SearchEnginePreset) {
        updateSettings { $0.searchEngineTemplate = preset.template }
        statusMessage = "Searches now use \(preset.name)"
    }

    /// What the address bar shows for this tab and URL: the typed query while
    /// the tab still sits on its search-results page, else the URL itself.
    /// A search engine may add parameters after load (DuckDuckGo appends
    /// `ia=web` from page JavaScript), so the match is scheme + host + path
    /// plus the `q` query item — not the full URL string.
    private func displayAddress(for url: URL?, tabID: TabID) -> String {
        guard let url else {
            searchDisplayByTab[tabID] = nil
            return ""
        }
        if let display = searchDisplayByTab[tabID],
           Self.isSameSearchPage(recorded: display.url, current: url, query: display.query) {
            return display.query
        }
        searchDisplayByTab[tabID] = nil
        return url.absoluteString
    }

    private static func isSameSearchPage(recorded: URL, current: URL, query: String) -> Bool {
        guard let recordedComponents = URLComponents(url: recorded, resolvingAgainstBaseURL: false),
              let currentComponents = URLComponents(url: current, resolvingAgainstBaseURL: false),
              recordedComponents.scheme?.lowercased() == currentComponents.scheme?.lowercased(),
              recordedComponents.host?.lowercased() == currentComponents.host?.lowercased(),
              recordedComponents.path == currentComponents.path else {
            return false
        }
        let wanted = normalizedSearchQuery(query)
        let recordedQuery = recordedComponents.queryItems?.first { $0.name == "q" }.flatMap(\.value)
            .map(normalizedSearchQuery)
        let currentQuery = currentComponents.queryItems?.first { $0.name == "q" }.flatMap(\.value)
            .map(normalizedSearchQuery)
        // The recorded URL always carries the query by construction; the live
        // page must still carry it. Extra parameters (like `ia=web`) are fine.
        return recordedQuery == wanted && currentQuery == wanted
    }

    private static func normalizedSearchQuery(_ value: String) -> String {
        value
            .replacingOccurrences(of: "+", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
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
            let detail = try resolver.resolveDetail(bangPreset == nil ? addressText : query)
            let request = detail.request
            // Typing a URL that is already open in this space switches to the
            // existing tab instead of stacking a duplicate. Navigations the
            // page itself triggers (target=_blank, redirects) are unaffected.
            if let existing = duplicateTab(of: request.url, excluding: tabID) {
                selectTab(existing)
                statusMessage = "Switched to the tab that already had this page open"
                return
            }
            if detail.isSearch {
                // `query` is the trimmed typed text, or the bang remainder —
                // either way it is what the bar should keep showing.
                searchDisplayByTab[tabID] = SearchDisplay(query: query, url: request.url)
                addressText = query
            } else {
                searchDisplayByTab[tabID] = nil
            }
            tabURLs[tabID] = request.url
            updateTab(tabID) { tab in
                tab.replaced(lastCommittedURL: .some(request.url), lifecycle: .loading, lastAccessedAt: Date())
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

    /// Collapses the sidebar tab list to a slim rail, or expands it back.
    /// Only the sidebar tab layout shows either; in top-strip mode this just
    /// records the preference for when the sidebar returns.
    public func toggleSidebarCollapsed() {
        isSidebarCollapsed.toggle()
        UserDefaults.standard.set(isSidebarCollapsed, forKey: "browsemium.sidebarCollapsed")
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
            refreshPausedBlockingHosts()
            if let tabID = session.activeTabID {
                environment.engine.setContentRulesPaused(tabID: tabID, paused: false)
            }
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
                updateHoverPeek(for: url)
            }
        case .elementPicked(let pick):
            guard session.activeTabID == tabID else { return }
            isPickingElement = false
            pendingElementPick = pick
            // Remember the site the pick came from: the user may switch tabs
            // before confirming, and the rule belongs to the picked page.
            pendingElementPickHost = Self.zoomHost(of: tabURLs[tabID])
            statusMessage = nil
            isSiteShieldPresented = true
        case .elementPickCancelled:
            guard session.activeTabID == tabID else { return }
            isPickingElement = false
            statusMessage = nil
        case .elementPickFailed:
            guard session.activeTabID == tabID else { return }
            isPickingElement = false
            statusMessage = "That element has no stable selector to save."
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
            if peek?.tabID == tabID {
                if let url {
                    peek?.url = url
                }
            } else if session.activeTabID == tabID {
                isLoading = true
                loadingProgress = 0.05
                statusMessage = nil
                hoveredLinkURL = nil
                // A navigation replaces the document the picker was armed on.
                isPickingElement = false
                pendingElementPick = nil
                pendingElementPickHost = nil
            }
            if peek?.tabID != tabID {
                updateTab(tabID) { tab in
                    tab.replaced(
                        lastCommittedURL: url.map(Optional.some),
                        lifecycle: .loading,
                        lastAccessedAt: Date()
                    )
                }
            }
        case .committed(let url):
            if peek?.tabID == tabID, let url {
                peek?.url = url
            }
            if let url {
                tabURLs[tabID] = url
                // Page zoom is per-webview, so a navigation keeps the last
                // site's level unless the destination's preference is applied.
                applySiteZoom(tabID: tabID, url: url)
                applySiteBlocking(tabID: tabID, url: url)
                if session.activeTabID == tabID {
                    addressText = displayAddress(for: url, tabID: tabID)
                    // Refresh now so the bookmark star follows the new page
                    // instead of the one that was open before it.
                    refreshNavigationState()
                }
            }
        case .finished(let title, let url):
            if peek?.tabID == tabID {
                // A preview updates the overlay's header but writes nothing:
                // no history entry, no session save, no tab record.
                if let url {
                    tabURLs[tabID] = url
                    peek?.url = url
                }
                peek?.title = title?.isEmpty == false ? title! : (url?.host ?? peek?.title ?? "Preview")
                return
            }
            updateTab(tabID) { tab in
                tab.replaced(
                    title: title?.isEmpty == false ? title! : (url?.host ?? tab.title),
                    lastCommittedURL: url.map(Optional.some),
                    lifecycle: .active,
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
                if let url {
                    addressText = displayAddress(for: url, tabID: tabID)
                }
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
            // A finished load is the right moment to refill the warm tab —
            // but never in a private window: a warm spare would pre-load a
            // page nobody asked for, on the ephemeral store or not.
            if !session.isPrivate {
                environment.engine.prepareWarmTab()
            }
        case .progressChanged(let progress):
            if session.activeTabID == tabID {
                loadingProgress = progress
            }
        case .failed(let message):
            if peek?.tabID == tabID {
                statusMessage = message
            } else if session.activeTabID == tabID {
                isLoading = false
                loadingProgress = 1
                statusMessage = message
            }
        case .cancelled:
            // Downloads, redirects, and user stops land here — clear the
            // spinner without putting an "error" in the status bar.
            if session.activeTabID == tabID {
                isLoading = false
                loadingProgress = 1
            }
        case .crashed:
            if peek?.tabID == tabID {
                closePeek()
                statusMessage = "The preview stopped responding"
                return
            }
            updateTab(tabID) { tab in
                tab.replaced(lifecycle: .crashed, lastAccessedAt: Date())
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
                tab.replaced(lifecycle: lifecycle)
            }
        case .requestedNewWindow(let url):
            _ = newTab(url: url)
        case .requestedPeek(let url):
            openPeek(url: url)
        case .requestedExternalScheme(let url):
            openExternally(url)
        case .downloadStarted, .downloadFinished, .downloadFailed:
            break
        }
    }

    /// Internal (not private) so tests can drive download reports directly.
    func handleDownload(_ info: DownloadInfo) {
        let state: DownloadState = info.failureMessage != nil ? .failed : (info.isFinished ? .finished : .inProgress)
        let progress = DownloadProgress(
            id: info.id,
            filename: info.suggestedFilename,
            destinationURL: info.destinationURL,
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
        // Only persist when the engine reported where the file came from —
        // writing the local destination (or file:///) as "source" corrupts
        // download history.
        if let sourceURL = info.sourceURL {
            let record = DownloadRecord(
                id: info.id,
                tabID: info.tabID,
                sourceURL: sourceURL,
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
        }

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
    public func deleteProfile(_ profile: BrowserProfile) async {
        guard deletingProfileID == nil else { return }
        deletingProfileID = profile.id
        defer { deletingProfileID = nil }

        let wasActive = profile.id == environment.activeProfile.id
        if wasActive {
            environment.engine.teardownForProfileSwitch()
            let fallback = environment.profiles.first(where: { $0.id != profile.id })
                ?? (try? environment.createProfile(name: ProfileStore.personalProfileName))
            if let fallback {
                do {
                    try environment.activate(fallback)
                } catch {
                    resetForActiveProfile()
                    statusMessage = "Could not prepare another profile: \(error.localizedDescription)"
                    return
                }
            }
            resetForActiveProfile()
        }

        do {
            try await environment.deleteProfile(profile)
        } catch {
            statusMessage = "Could not completely delete \(profile.name). Its profile record was kept so you can retry: \(error.localizedDescription)"
            profileSwitchToken += 1
            return
        }
        profileSwitchToken += 1
        statusMessage = "Deleted \(profile.name)"
    }

    /// Rebuilds window state around `environment.activeProfile`.
    private func resetForActiveProfile() {
        closeSplitView()
        // The peek tab's web view belonged to the previous profile's runtime
        // and is already gone; only the model's overlay state needs clearing.
        closePeek()
        // An extension permission prompt from the previous profile must be
        // answered — deny — or its WebKit completion handler hangs forever.
        if pendingExtensionPermission != nil {
            answerExtensionPermission(granted: false)
        }
        // Unlocks are per-profile sessions: profile B's spaces never inherit
        // profile A's Touch ID grants.
        unlockedSpaceIDs = []
        if let restored = try? environment.sessionRepository.load() {
            session = Self.sessionLandingUnlocked(restored)
        } else {
            let space = BrowserSpace(name: "Personal")
            let tab = BrowserTab(spaceID: space.id, title: "New Tab", position: 0)
            session = BrowserSessionState(
                spaces: [space],
                tabs: [tab],
                folders: [],
                activeSpaceID: space.id,
                activeTabID: tab.id
            )
        }
        tabURLs = Dictionary(uniqueKeysWithValues: session.tabs.compactMap { tab in
            tab.lastCommittedURL.map { (tab.id, $0) }
        })
        searchEngineTemplate = environment.loadSettings().searchEngineTemplate
        paneOrder = [paneID]
        paneTabIDs[paneID] = session.activeTabID
        activePaneID = paneID
        applyPrivateBrowsingModeToEngine()
        searchDisplayByTab.removeAll()
        webStoreOffer = nil
        dismissedWebStoreOffers.removeAll()
        hiddenExtensionActionIDs = Set(
            UserDefaults.standard.stringArray(forKey: Self.hiddenExtensionActionsKey(for: environment.activeProfile)) ?? []
        )
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
        // The profile switch rebuilt the extension host: without this the new
        // host has no bridge, loads nothing, and every extension API call —
        // tab creation, permission prompts, action popups — silently dies.
        refreshPausedBlockingHosts()
        refreshCosmeticRules()
        refreshExtensions()
        reloadExtensions()
        refreshAISkills()
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
        syncWebStoreOffer()
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

    // MARK: - Extensions

    /// Every extension this profile knows about, with its enablement and the
    /// last load error, if any.
    public private(set) var installedExtensions: [ExtensionRecord] = []

    /// Nil when extensions are supported; a sentence when they are not.
    public var extensionsUnavailableReason: String? {
        if #available(macOS 15.4, *) {
            return nil
        }
        return "Extensions need macOS 15.4 or newer — this Mac runs an older system."
    }

    /// An extension permission request waiting for the user's answer. While
    /// one is pending, the extension's API call is suspended.
    public private(set) var pendingExtensionPermission: ExtensionPermissionRequest?
    private var extensionPermissionContinuation: CheckedContinuation<Bool, Never>?

    public func refreshExtensions() {
        // The file store is the source of truth for what exists; the profile
        // database decides what runs. Reconciling here means an extension
        // installed under one profile shows up — disabled — in the others.
        let installed = (try? environment.extensionStore.installed()) ?? []
        let metadata = Dictionary(
            uniqueKeysWithValues: installed.map { ($0.id, (name: $0.name, version: $0.version)) }
        )
        try? environment.extensionRepository.reconcile(with: metadata)
        installedExtensions = (try? environment.extensionRepository.all()) ?? []
    }

    /// True while a Chrome Web Store install is downloading.
    public private(set) var isInstallingFromWebStore = false

    /// A Chrome Web Store listing the active tab is showing, offered as a
    /// one-click beta install. Nil when the tab is not on a listing, the user
    /// dismissed the offer, the extension is already installed, or the
    /// "Offer to install from the Chrome Web Store" setting is off.
    public struct WebStoreOffer: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let url: URL
        /// True when this listing is already in the profile. The banner then
        /// offers Settings instead of a second install.
        public let isInstalled: Bool
    }

    public private(set) var webStoreOffer: WebStoreOffer?
    /// Listings the user waved away this session. Kept in memory: a reinstall
    /// prompt on the next visit to the same listing would be nagging.
    private var dismissedWebStoreOffers: Set<String> = []

    public func dismissWebStoreOffer() {
        if let offer = webStoreOffer {
            dismissedWebStoreOffers.insert(offer.id)
        }
        webStoreOffer = nil
    }

    public func installWebStoreOffer() {
        guard let offer = webStoreOffer else { return }
        dismissedWebStoreOffers.insert(offer.id)
        webStoreOffer = nil
        installExtensionFromChromeWebStore(offer.id)
    }

    /// Recomputes the offer from the active tab. Called after navigation and
    /// tab changes so the banner always describes what is actually on screen.
    private func syncWebStoreOffer() {
        guard environment.loadSettings().offerWebStoreInstalls,
              !session.isPrivate,
              let tabID = session.activeTabID,
              let url = tabURLs[tabID] ?? activeTab?.lastCommittedURL else {
            webStoreOffer = nil
            return
        }
        if let reference = ChromeWebStoreReference.reference(in: url)
            ?? (try? ChromeWebStoreReference.parse(url.absoluteString)) {
            presentWebStoreOffer(reference, url: url)
            return
        }
        // The store is a single-page app: the listing can be on screen while
        // the committed URL is still the homepage. Read the page's own URL.
        guard ChromeWebStoreReference.isStoreHost(url) else {
            webStoreOffer = nil
            return
        }
        let engine = environment.engine
        Task { [weak self] in
            let found = try? await engine.evaluateJavaScript(
                tabID: tabID,
                script: """
                (function() {
                  var parts = (location.pathname || "").split("/");
                  for (var i = parts.length - 1; i >= 0; i--) {
                    if (/^[a-p]{32}$/.test(parts[i])) return parts[i];
                  }
                  var link = document.querySelector("link[rel=canonical]");
                  if (link && link.href) {
                    var bits = link.href.split("/");
                    for (var j = bits.length - 1; j >= 0; j--) {
                      var id = bits[j].split("?")[0];
                      if (/^[a-p]{32}$/.test(id)) return id;
                    }
                  }
                  return "";
                })()
                """
            )
            guard let self, self.session.activeTabID == tabID,
                  let id = found as? String,
                  let reference = try? ChromeWebStoreReference(extensionID: id) else { return }
            self.presentWebStoreOffer(reference, url: url)
        }
    }

    private func presentWebStoreOffer(_ reference: ChromeWebStoreReference, url: URL) {
        guard !dismissedWebStoreOffers.contains(reference.extensionID) else {
            webStoreOffer = nil
            return
        }
        let installed = installedExtensions.contains { $0.id == reference.extensionID }
        webStoreOffer = WebStoreOffer(
            id: reference.extensionID,
            name: Self.webStoreDisplayName(title: activeTab?.title, url: url),
            url: url,
            isInstalled: installed
        )
    }

    /// A friendly label for the banner: the page title without the store's
    /// own suffix, else the URL slug with dashes opened up.
    private static func webStoreDisplayName(title: String?, url: URL) -> String {
        if let title, !title.isEmpty {
            for suffix in [" - Chrome Web Store", " – Chrome Web Store", " — Chrome Web Store"] {
                if let range = title.range(of: suffix, options: [.backwards, .caseInsensitive]) {
                    let name = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { return name }
                }
            }
            return title
        }
        let components = url.pathComponents
        if let detail = components.firstIndex(of: "detail"), components.indices.contains(detail + 1) {
            let name = components[detail + 1].replacingOccurrences(of: "-", with: " ")
            if !name.isEmpty { return name.capitalized }
        }
        return "This extension"
    }

    /// Installs an extension from a Chrome Web Store link or extension id
    /// (beta). The package comes from Google's public update service, lands
    /// in the same store as a hand-picked .crx, and starts disabled like any
    /// other install.
    public func installExtensionFromChromeWebStore(_ input: String) {
        guard extensionsUnavailableReason == nil else {
            statusMessage = extensionsUnavailableReason
            return
        }
        let reference: ChromeWebStoreReference
        do {
            reference = try ChromeWebStoreReference.parse(input)
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        guard !isInstallingFromWebStore else { return }
        isInstallingFromWebStore = true
        statusMessage = "Downloading from the Chrome Web Store…"
        Task { [environment] in
            defer { isInstallingFromWebStore = false }
            do {
                let package = try await environment.chromeWebStore.downloadPackage(for: reference.extensionID)
                defer { try? FileManager.default.removeItem(at: package) }
                installExtension(from: package, preferredID: reference.extensionID)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    /// Installs an extension from a folder, .zip, .crx, or .appex. New
    /// extensions start disabled: nothing runs until the user enables it.
    public func installExtension(from url: URL, preferredID: String? = nil) {
        guard extensionsUnavailableReason == nil else {
            statusMessage = extensionsUnavailableReason
            return
        }
        do {
            let item = try environment.extensionStore.install(from: url, identifier: preferredID)
            try environment.extensionRepository.upsert(
                id: item.id,
                name: item.name,
                version: item.version,
                enabledByDefault: false,
                installedAt: item.installedAt
            )
            refreshExtensions()
            statusMessage = "Installed “\(item.name)” — enable it to run it"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func setExtensionEnabled(_ extensionID: String, isEnabled: Bool) {
        do {
            try environment.extensionRepository.setEnabled(id: extensionID, isEnabled: isEnabled)
            refreshExtensions()
            reloadExtensions()
            if let record = installedExtensions.first(where: { $0.id == extensionID }) {
                statusMessage = isEnabled ? "“\(record.name)” enabled" : "“\(record.name)” disabled"
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Removes an extension: its files, its registry row, and its loaded
    /// context. Extension storage in the profile's data store is left to the
    /// normal site-data tools, which is what WebKit keys it to.
    public func removeExtension(_ extensionID: String) {
        if #available(macOS 15.4, *) {
            environment.extensionHost?.unload(id: extensionID)
        }
        try? environment.extensionStore.remove(id: extensionID)
        try? environment.extensionRepository.remove(id: extensionID)
        refreshExtensions()
        statusMessage = "Extension removed"
    }

    /// Reloads enabled extensions and rebinds the host to this window. The
    /// most recently active window is the one extensions see.
    public func reloadExtensions() {
        if #available(macOS 15.4, *) {
            environment.extensionHost?.bridge = self
            environment.extensionHost?.permissionPrompter = self
            environment.extensionHost?.onActionsChanged = { [weak self] in
                self?.refreshExtensionActions()
            }
        }
        Task { [environment] in
            await environment.loadEnabledExtensions()
            refreshExtensions()
            refreshExtensionActions()
        }
    }

    // MARK: - Extension action buttons

    /// One toolbar button an extension exposes. The icon is resolved at the
    /// size the toolbar draws so WebKit picks the best asset.
    public struct ExtensionActionButton: Identifiable {
        public let id: String
        public let label: String
        public let badgeText: String?
        public let hasUnreadBadgeText: Bool
        public let isEnabled: Bool
        public let presentsPopup: Bool
        public let icon: NSImage?
    }

    /// The action buttons for the active tab, in a stable order.
    public private(set) var extensionActions: [ExtensionActionButton] = []

    public func refreshExtensionActions() {
        guard #available(macOS 15.4, *), let host = environment.extensionHost else {
            extensionActions = []
            return
        }
        let activeTabID = session.activeTabID
        extensionActions = host.contexts.keys.sorted().compactMap { id in
            guard !hiddenExtensionActionIDs.contains(id),
                  let action = host.action(for: id, tabID: activeTabID) else { return nil }
            let label = action.label.isEmpty ? (host.displayNames[id] ?? id) : action.label
            let icon = action.icon(for: CGSize(width: 16, height: 16))
            // An extension without an action page has nothing to show: skip
            // rows with neither a label nor an icon.
            guard icon != nil || !action.label.isEmpty else { return nil }
            return ExtensionActionButton(
                id: id,
                label: label,
                badgeText: action.badgeText.isEmpty ? nil : action.badgeText,
                hasUnreadBadgeText: action.hasUnreadBadgeText,
                isEnabled: action.isEnabled,
                presentsPopup: action.presentsPopup,
                icon: icon
            )
        }
    }

    /// Whether this extension's toolbar button is shown.
    public func isExtensionActionVisible(_ extensionID: String) -> Bool {
        !hiddenExtensionActionIDs.contains(extensionID)
    }

    /// Shows or hides an extension's toolbar button. Purely a chrome
    /// preference: the extension keeps running either way.
    public func setExtensionActionVisible(_ extensionID: String, isVisible: Bool) {
        if isVisible {
            hiddenExtensionActionIDs.remove(extensionID)
        } else {
            hiddenExtensionActionIDs.insert(extensionID)
        }
        UserDefaults.standard.set(
            Array(hiddenExtensionActionIDs),
            forKey: Self.hiddenExtensionActionsKey(for: environment.activeProfile)
        )
        refreshExtensionActions()
    }

    private static func hiddenExtensionActionsKey(for profile: BrowserProfile) -> String {
        "browsemium.hiddenExtensionActions.\(profile.id.uuidString)"
    }

    /// Runs an extension's action for the active tab. A popup action routes
    /// through the host's presenter, which the toolbar supplies.
    public func performExtensionAction(_ extensionID: String) {
        guard #available(macOS 15.4, *) else { return }
        environment.extensionHost?.performAction(for: extensionID, tabID: session.activeTabID)
    }

    /// Extension-supplied menu items for an action button, fetched on demand.
    public func extensionActionMenuItems(_ extensionID: String) -> [NSMenuItem] {
        guard #available(macOS 15.4, *) else { return [] }
        return environment.extensionHost?.actionMenuItems(for: extensionID, tabID: session.activeTabID) ?? []
    }

    public func openExtensionOptions(_ extensionID: String) {
        guard #available(macOS 15.4, *),
              let url = environment.extensionHost?.optionsPageURL(for: extensionID) else {
            statusMessage = "This extension has no options page"
            return
        }
        _ = newTab(url: url)
    }

    public func reloadExtension(_ extensionID: String) {
        reloadExtensions()
        statusMessage = "Extension reloaded"
    }

    @available(macOS 15.4, *)
    public func registerExtensionActionPresenter(_ presenter: any ExtensionActionPopupPresenting) {
        environment.extensionHost?.actionPresenter = presenter
    }

    @available(macOS 15.4, *)
    public func unregisterExtensionActionPresenter(_ presenter: any ExtensionActionPopupPresenting) {
        if environment.extensionHost?.actionPresenter === presenter {
            environment.extensionHost?.actionPresenter = nil
        }
    }

    @available(macOS 15.4, *)
    public func extensionID(for context: WKWebExtensionContext) -> String? {
        environment.extensionHost?.extensionID(for: context)
    }

    /// Tells the extension host the strip changed, so WebKit's view of the
    /// window's tabs stays current.
    private func notifyExtensionsOfStripChange(
        closed: TabID? = nil,
        activated: TabID? = nil,
        previous: TabID? = nil
    ) {
        guard #available(macOS 15.4, *), let host = environment.extensionHost else { return }
        host.stripDidChange(closedTabID: closed, activatedTabID: activated, previousTabID: previous)
        // Actions are tab-specific (badges, enabled state), so the toolbar
        // buttons follow the active tab.
        refreshExtensionActions()
    }

    // MARK: - Extension bridge

    public func extensionTabSnapshots() -> [ExtensionTabSnapshot] {
        visibleTabs.enumerated().map { index, tab in
            ExtensionTabSnapshot(
                id: tab.id,
                title: tab.title,
                url: tabURLs[tab.id] ?? tab.lastCommittedURL,
                isPinned: tab.isPinned,
                isActive: tab.id == session.activeTabID,
                isLoading: tab.lifecycle == .loading,
                index: index
            )
        }
    }

    public func extensionActivateTab(_ tabID: TabID) -> Bool {
        guard session.tabs.contains(where: { $0.id == tabID }) else { return false }
        selectTab(tabID)
        return true
    }

    public func extensionCloseTab(_ tabID: TabID) -> Bool {
        guard session.tabs.contains(where: { $0.id == tabID }) else { return false }
        closeTab(tabID)
        return true
    }

    public func extensionLoadURL(_ url: URL, in tabID: TabID) -> Bool {
        guard session.tabs.contains(where: { $0.id == tabID }) else { return false }
        tabURLs[tabID] = url
        updateTab(tabID) { tab in
            tab.replaced(lastCommittedURL: .some(url), lifecycle: .loading, lastAccessedAt: Date())
        }
        persistSession()
        Task { try? await environment.engine.navigate(tabID: tabID, to: NavigationRequest(url: url)) }
        return true
    }

    @discardableResult
    public func extensionCreateTab(url: URL?, active: Bool) -> TabID? {
        let previous = session.activeTabID
        let created = newTab(url: url)
        if !active, let previous, previous != created {
            selectTab(previous)
        }
        return created
    }

    public func extensionIsPrivateSession() -> Bool {
        session.isPrivate
    }

    /// The user's answer to an extension permission request.
    public func answerExtensionPermission(granted: Bool) {
        pendingExtensionPermission = nil
        extensionPermissionContinuation?.resume(returning: granted)
        extensionPermissionContinuation = nil
    }

    // MARK: - Assistant skills and multi-tab context

    /// Work the app shell hands to the assistant dock: run a saved skill, or
    /// summarize the open tabs. Consumed by `BrowsemiumAppView`.
    public enum PendingAssistantTask: Sendable {
        case skill(AISkill)
        case summarizeOpenTabs
    }

    public private(set) var aiSkills: [AISkill] = []
    public private(set) var pendingAssistantTask: PendingAssistantTask?
    public private(set) var assistantTaskToken = 0

    public func refreshAISkills() {
        aiSkills = (try? environment.aiSkillRepository.all()) ?? []
    }

    @discardableResult
    public func saveAISkill(name: String, prompt: String) -> AISkill? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else {
            statusMessage = "A skill needs a name and a prompt"
            return nil
        }
        guard let saved = try? environment.aiSkillRepository.save(name: trimmedName, prompt: trimmedPrompt) else {
            statusMessage = "The skill could not be saved"
            return nil
        }
        refreshAISkills()
        // Hand back the stored value, so callers hold exactly what a reload
        // would return.
        let canonical = aiSkills.first { $0.id == saved.id } ?? saved
        statusMessage = "Saved skill “\(canonical.name)”"
        return canonical
    }

    public func deleteAISkill(_ skill: AISkill) {
        _ = try? environment.aiSkillRepository.remove(id: skill.id)
        refreshAISkills()
        statusMessage = "Deleted skill “\(skill.name)”"
    }

    /// Hands work to the dock. The dock opens and the composer fills; nothing
    /// is sent — the user still writes or presses send.
    public func requestAssistantTask(_ task: PendingAssistantTask) {
        pendingAssistantTask = task
        assistantTaskToken += 1
        isAIDockVisible = true
    }

    public func consumePendingAssistantTask() -> PendingAssistantTask? {
        defer { pendingAssistantTask = nil }
        return pendingAssistantTask
    }

    /// Extracts readable text from other open tabs for the assistant. Only
    /// tabs with a live page can be read — waking a hibernated tab just to
    /// summarize it would be a surprise, and a tab that never loaded has
    /// nothing to read. The user picks the tabs; nothing here is automatic.
    public func captureTabsForAI(_ tabIDs: [TabID]) async -> [AIContextAttachment] {
        var attachments: [AIContextAttachment] = []
        var skipped = 0
        for tabID in tabIDs.prefix(Self.maximumAIContextTabs) {
            // A locked space's pages are never context: the lock hides their
            // content from every surface, the assistant included.
            guard let tab = session.tabs.first(where: { $0.id == tabID }),
                  isSpaceUnlocked(tab.spaceID),
                  environment.engine.isLive(tabID: tabID),
                  let captured = try? await environment.engine.capture(
                      tabID: tabID,
                      request: CaptureRequest(kinds: [.readablePage])
                  ) else {
                skipped += 1
                continue
            }
            attachments.append(contentsOf: captured.attachments.filter(\.isPageText))
        }
        if skipped > 0 {
            statusMessage = skipped == 1
                ? "1 tab had nothing to read — open it first"
                : "\(skipped) tabs had nothing to read — open them first"
        }
        return attachments
    }

    /// Tabs that could contribute context right now, for the attach menus.
    /// Locked spaces are excluded — even a tab's title in the menu would leak
    /// what the lock exists to hide.
    public func tabsAvailableForAIContext() -> [BrowserTab] {
        session.tabs.filter {
            $0.id != session.activeTabID && isSpaceUnlocked($0.spaceID) && environment.engine.isLive(tabID: $0.id)
        }
    }

    /// How many tabs one assistant request may draw context from. Each page
    /// is bounded and sanitized on its own; the cap keeps the prompt within
    /// every provider's window.
    private static let maximumAIContextTabs = 6

    private func updateTab(_ tabID: TabID, transform: (BrowserTab) -> BrowserTab) {
        guard let index = session.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        var tabs = session.tabs
        tabs[index] = transform(tabs[index])
        session = BrowserSessionState(
            spaces: session.spaces,
            tabs: tabs,
            folders: session.folders,
            activeSpaceID: session.activeSpaceID,
            activeTabID: session.activeTabID,
            isPrivate: session.isPrivate
        )
    }
}

// MARK: - Extensions

extension BrowserWindowModel: ExtensionHostBridging {}

extension BrowserWindowModel: ExtensionPermissionPrompting {
    /// Suspends the extension's API call until the user answers. A second
    /// request while one is pending denies the first rather than leaking it.
    public func promptForExtensionPermissions(_ request: ExtensionPermissionRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            if let existing = extensionPermissionContinuation {
                extensionPermissionContinuation = nil
                existing.resume(returning: false)
            }
            extensionPermissionContinuation = continuation
            pendingExtensionPermission = request
        }
    }
}
