import AppKit
import BrowsemiumCore
import Foundation

/// What a window needs from a web engine.
///
/// Browsemium ships two editions: one on WebKit, one on Chromium. The SwiftUI
/// chrome, the database, the importer and the assistant are shared, and this
/// protocol is the seam between them — the only surface a window is allowed to
/// use, so neither edition can grow a dependency on the other's engine.
@MainActor
public protocol BrowserEngine: AnyObject {
    // MARK: - Events

    /// Registers for tab events. Every window registers its own observer, so a
    /// second window cannot silence the first.
    @discardableResult
    func addEventObserver(_ handler: @escaping (TabID, TabRuntimeEvent) -> Void) -> UUID
    func removeEventObserver(_ token: UUID)

    /// Download progress, observed the same way.
    var downloads: DownloadReporting { get }

    // MARK: - Tab lifecycle

    func attach(tabID: TabID, to host: NSView)
    func detach(tabID: TabID)
    func discard(tabID: TabID)
    func activate(tabID: TabID, in pane: PaneID) async
    func deactivate(tabID: TabID) async
    /// Drops every web view, including the warm spare, because they belong to
    /// the previous profile's data store.
    func teardownForProfileSwitch()
    func isLive(tabID: TabID) -> Bool
    var liveTabCount: Int { get }

    // MARK: - Navigation

    func navigate(tabID: TabID, to request: NavigationRequest) async throws
    func goBack(tabID: TabID)
    func goForward(tabID: TabID)
    func reload(tabID: TabID)
    func stopLoading(tabID: TabID)
    func canGoBack(tabID: TabID) -> Bool
    func canGoForward(tabID: TabID) -> Bool
    func isLoading(tabID: TabID) -> Bool
    func currentURL(tabID: TabID) -> URL?

    // MARK: - Page features

    func find(tabID: TabID, query: String, backwards: Bool) async -> FindOutcome
    /// Clears the highlight a find leaves behind.
    func clearFindHighlight(tabID: TabID)
    func adjustZoom(tabID: TabID, by delta: CGFloat)
    func resetZoom(tabID: TabID)
    /// The page's live zoom factor (1 = 100%). Needed so the window can
    /// persist the value the user just dialed in.
    func currentZoom(tabID: TabID) -> CGFloat
    /// Applies an exact zoom factor, for restoring a per-site preference.
    func setZoom(tabID: TabID, to zoom: CGFloat)
    func printPage(tabID: TabID)
    /// The full scrollable page as PDF data.
    func pagePDF(tabID: TabID) async throws -> Data
    /// The visible viewport as PNG data.
    func pageScreenshot(tabID: TabID) async throws -> Data
    /// Toggles Picture in Picture for the page's first video.
    /// Returns whether the toggle was accepted.
    func togglePictureInPicture(tabID: TabID) async -> Bool
    func capture(tabID: TabID, request: CaptureRequest) async throws -> CapturedContext
    func extractArticle(tabID: TabID) async throws -> ReaderArticle
    func fillCredential(tabID: TabID, username: String, password: String) async throws -> Bool
    /// Runs a script in the page and returns its value. Used for the reader,
    /// favicon discovery, and context capture.
    func evaluateJavaScript(tabID: TabID, script: String) async throws -> Any?

    // MARK: - Audio

    func setMuted(tabID: TabID, muted: Bool)
    func audioState(tabID: TabID) -> TabAudioState?

    // MARK: - Blocking

    var blocking: BlockingState { get }
    /// Fired when blocking rules become usable, so open tabs can pick them up.
    var onBlockingActivated: (() -> Void)? { get set }

    // MARK: - Settings, permissions, memory

    func apply(_ settings: BrowserSettings)
    var permissionPrompter: PermissionPrompting? { get set }
    func applySleepPolicy(tabs: [BrowserTab], signals: [TabID: TabSleepSignals], now: Date) async
    func hibernateInactiveTabs()
    func beginMemoryPressureMonitoring(handler: @escaping @MainActor (MemoryPressureLevel) -> Void)
    func prepareWarmTab()
    var hasWarmTab: Bool { get }
    func setWarmTabPreloading(_ enabled: Bool)

    // MARK: - Profiles and site data

    func clearSiteData(dataStoreIdentifier: UUID, includeCache: Bool, modifiedSince: Date) async
    func clearCache(dataStoreIdentifier: UUID) async
    func removeAllData(dataStoreIdentifier: UUID) async
}

/// Download progress, reported to every window.
@MainActor
public protocol DownloadReporting: AnyObject {
    @discardableResult
    func addObserver(_ handler: @escaping (DownloadInfo) -> Void) -> UUID
    func removeObserver(_ token: UUID)
    func allDownloads() -> [DownloadInfo]
}

/// Result of a find-in-page request. WebKit reports only whether a match was
/// found; Chromium also reports how many, so the richer answer is the protocol.
public struct FindOutcome: Sendable, Equatable {
    public let found: Bool
    public let matchCount: Int?

    public init(found: Bool, matchCount: Int? = nil) {
        self.found = found
        self.matchCount = matchCount
    }

    public var describedResult: String? {
        guard found else { return nil }
        guard let matchCount else { return "Found" }
        return matchCount == 1 ? "1 match" : "\(matchCount) matches"
    }
}

/// Whether ad and tracker blocking is running. WebKit does not report how many
/// requests it stopped, so counts stay optional and are never invented.
public enum BlockingState: Sendable, Equatable {
    case inactive
    case compiling
    case active(ruleCount: Int)
    case failed(String)

    public var ruleCount: Int {
        if case .active(let count) = self { return count }
        return 0
    }

    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}
