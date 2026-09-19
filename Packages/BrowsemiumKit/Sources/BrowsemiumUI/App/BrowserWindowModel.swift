import AppKit
import BrowsemiumCore
import BrowsemiumData
import BrowsemiumEngine
import Foundation
import Observation

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
public final class BrowserWindowModel {
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
    public private(set) var bookmarks: [Bookmark] = []
    public private(set) var savedCredentials: [SavedCredential] = []
    public private(set) var downloads: [DownloadProgress] = []
    private var bookmarkedURLs: Set<String> = []
    public var isBookmarksBarVisible: Bool = true

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

        environment.runtime.onEvent = { [weak self] tabID, event in
            self?.handle(event, for: tabID)
        }
        environment.runtime.downloads.onUpdate = { [weak self] info in
            self?.handleDownload(info)
        }
        environment.runtime.beginMemoryPressureMonitoring { [weak self] level in
            guard let self else { return }
            switch level {
            case .warning:
                self.applySleepPolicy()
            case .critical:
                self.environment.runtime.hibernateInactiveTabs()
                self.statusMessage = "Inactive tabs were unloaded to reduce memory use"
            }
        }
        environment.runtime.apply(storedSettings)
        applyAppearanceToApp()
        environment.runMaintenance()
        refreshBookmarks()
        refreshSavedCredentials()
        persistSession()
    }

    public var activeTab: BrowserTab? {
        guard let activeTabID = session.activeTabID else { return nil }
        return session.tabs.first { $0.id == activeTabID }
    }

    public var liveWebViewCount: Int {
        environment.runtime.liveWebViewCount
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

    /// Only reports figures WebKit actually exposes: whether this tab holds a
    /// live web view, and the browser's own measured footprint.
    public func tabStats(for tab: BrowserTab) -> TabStats {
        TabStats(
            isLive: environment.runtime.webView(for: tab.id) != nil,
            lifecycle: tab.lifecycle,
            liveTabs: liveWebViewCount,
            sleepingTabs: sleepingTabCount,
            footprint: ProcessMemory.formattedFootprint()
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
            Task { try? await environment.runtime.navigate(tabID: tab.id, to: NavigationRequest(url: url)) }
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
        environment.runtime.discard(tabID: targetID)
        tabURLs[targetID] = nil

        let closedIndex = session.tabs.firstIndex { $0.id == targetID } ?? 0
        var tabs = session.tabs.filter { $0.id != targetID }
        if tabs.isEmpty {
            let replacement = BrowserTab(spaceID: session.activeSpaceID, title: "New Tab")
            tabs = [replacement]
        }
        // Activate the tab that slid into the closed tab's place, falling back
        // to the one before it — the same behaviour as Chrome and Safari.
        let neighbourIndex = min(closedIndex, tabs.count - 1)
        let nextActiveID = session.activeTabID == targetID ? tabs[neighbourIndex].id : session.activeTabID
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
        addressText = tabURLs[tabID]?.absoluteString ?? activeTab?.lastCommittedURL?.absoluteString ?? ""
        refreshNavigationState()
        persistSession()
        Task { await environment.runtime.activate(tabID: tabID, in: paneID) }
    }

    public func moveTab(_ sourceID: TabID, before targetID: TabID) {
        guard sourceID != targetID,
              let sourceIndex = session.tabs.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = session.tabs.firstIndex(where: { $0.id == targetID }) else { return }
        var tabs = session.tabs
        let moved = tabs.remove(at: sourceIndex)
        let insertionIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        tabs.insert(moved, at: insertionIndex)
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

    public func focusAddress() {
        focusAddressToken += 1
    }

    public func showFindBar() {
        isFindBarVisible = true
    }

    public func dismissFindBar() {
        isFindBarVisible = false
        findStatus = nil
        findText = ""
        if let tabID = session.activeTabID {
            environment.runtime.clearFindHighlight(tabID: tabID)
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
            let found = await environment.runtime.find(tabID: tabID, query: query, backwards: backwards)
            findStatus = found ? nil : "No matches"
        }
    }

    public func zoomIn() {
        guard let tabID = session.activeTabID else { return }
        environment.runtime.adjustZoom(tabID: tabID, by: 0.1)
    }

    public func zoomOut() {
        guard let tabID = session.activeTabID else { return }
        environment.runtime.adjustZoom(tabID: tabID, by: -0.1)
    }

    public func resetZoom() {
        guard let tabID = session.activeTabID else { return }
        environment.runtime.resetZoom(tabID: tabID)
    }

    public func printPage() {
        guard let tabID = session.activeTabID else { return }
        environment.runtime.printPage(tabID: tabID)
    }

    public func ensureLoaded(_ tabID: TabID) {
        let runtime = environment.runtime.runtime(for: tabID, isPrivate: session.isPrivate)
        guard runtime.currentWebView == nil else {
            Task { await environment.runtime.activate(tabID: tabID, in: paneID) }
            return
        }
        let url = tabURLs[tabID] ?? session.tabs.first { $0.id == tabID }?.lastCommittedURL
        guard let url else { return }
        tabURLs[tabID] = url
        Task {
            await environment.runtime.activate(tabID: tabID, in: paneID)
            try? await environment.runtime.navigate(tabID: tabID, to: NavigationRequest(url: url))
        }
    }

    public func updateSettings(_ mutate: (inout BrowserSettings) -> Void) {
        var settings = environment.loadSettings()
        mutate(&settings)
        environment.saveSettings(settings)
        appearance = settings.appearance
        isAIDockVisible = settings.isAIDockEnabled
        environment.runtime.apply(settings)
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

    /// Unloads every background tab and drops the warm spare, then reports the
    /// measured change. Only real numbers.
    public func freeMemoryNow() {
        let before = ProcessMemory.footprintBytes()
        environment.runtime.hibernateInactiveTabs()
        let after = ProcessMemory.footprintBytes()
        let freed = before > after ? before - after : 0
        if freed > 0 {
            statusMessage = "Unloaded background tabs — freed \(ByteCountFormatter.string(fromByteCount: Int64(freed), countStyle: .memory))"
        } else {
            statusMessage = "Background tabs unloaded. Memory is released as WebKit shuts the pages down."
        }
    }

    public var currentMemoryFootprint: String {
        ProcessMemory.formattedFootprint()
    }

    public var contentRuleState: ContentRuleListManager.State {
        environment.runtime.contentRules.state
    }

    public var contentRuleCount: Int {
        environment.runtime.contentRules.ruleCount
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
        guard !trimmedQuery.isEmpty else { return paletteCommands }
        return paletteCommands.filter {
            $0.title.localizedCaseInsensitiveContains(trimmedQuery)
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
            Task { try? await environment.runtime.navigate(tabID: tabID, to: request) }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func reload() {
        guard let tabID = session.activeTabID else { return }
        environment.runtime.runtime(for: tabID, isPrivate: session.isPrivate).reload()
        isLoading = true
    }

    public func stopLoading() {
        guard let tabID = session.activeTabID else { return }
        environment.runtime.runtime(for: tabID, isPrivate: session.isPrivate).stopLoading()
        isLoading = false
    }

    public func goBack() {
        guard let tabID = session.activeTabID else { return }
        environment.runtime.runtime(for: tabID, isPrivate: session.isPrivate).goBack()
    }

    public func goForward() {
        guard let tabID = session.activeTabID else { return }
        environment.runtime.runtime(for: tabID, isPrivate: session.isPrivate).goForward()
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
                let filled = try await environment.runtime.fillCredential(
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

    public func clearBrowsingData() {
        do {
            try environment.privacyDataManager.clear(.everything)
            statusMessage = "Browsing data cleared"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func applySleepPolicy() {
        let tabs = session.tabs
        let runtime = environment.runtime
        Task {
            await runtime.applySleepPolicy(tabs: tabs, signals: [:])
        }
    }

    private func handle(_ event: TabRuntimeEvent, for tabID: TabID) {
        switch event {
        case .startedLoading(let url):
            if let url {
                tabURLs[tabID] = url
            }
            if session.activeTabID == tabID {
                isLoading = true
                loadingProgress = 0.05
                statusMessage = nil
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
                if let webView = environment.runtime.webView(for: tabID) {
                    // Icon discovery runs JavaScript and a network fetch. Let
                    // the page settle first so it never competes with loading.
                    Task { [favicons] in
                        try? await Task.sleep(for: .milliseconds(350))
                        favicons.fetchIcon(for: webView, pageURL: url)
                    }
                }
            }
            if session.activeTabID == tabID {
                isLoading = false
                loadingProgress = 1
                addressText = url?.absoluteString ?? addressText
                refreshNavigationState()
            }
            recordHistory(url: url, title: title)
            persistSession()
            applySleepPolicy()
            // A finished load is the right moment to refill the warm tab.
            environment.runtime.prepareWarmTab()
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
        case .requestedNewWindow(let url):
            _ = newTab(url: url)
        case .requestedExternalScheme(let url):
            openExternally(url)
        case .downloadStarted, .downloadFinished, .downloadFailed:
            break
        }
    }

    private func handleDownload(_ info: DownloadCoordinator.DownloadInfo) {
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

    private func refreshNavigationState() {
        guard let tabID = session.activeTabID else {
            canGoBack = false
            canGoForward = false
            isBookmarked = false
            return
        }
        let runtime = environment.runtime.runtime(for: tabID, isPrivate: session.isPrivate)
        canGoBack = runtime.canGoBack
        canGoForward = runtime.canGoForward
        isLoading = runtime.isLoading
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
        guard !session.isPrivate else { return }
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
