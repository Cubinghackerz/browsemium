import BrowsemiumCore
import Foundation

/// State a page reports about itself: whether it is audible, whether the user
/// muted the tab, and whether it holds a live capture track.
public struct TabAudioState: Hashable, Sendable {
    public let isPlaying: Bool
    public let isMuted: Bool
    /// True while the page holds a live microphone, camera, or screen-share
    /// track. A call can be silent (muted mic) and still be in progress, so
    /// this is reported separately from `isPlaying`.
    public let isCapturingMedia: Bool

    public init(isPlaying: Bool, isMuted: Bool, isCapturingMedia: Bool = false) {
        self.isPlaying = isPlaying
        self.isMuted = isMuted
        self.isCapturingMedia = isCapturingMedia
    }
}

/// Everything a tab can tell its window. Both engines emit the same vocabulary
/// so the window model, the tab strip and the sleep policy stay engine-agnostic.
public enum TabRuntimeEvent: Sendable {
    case startedLoading(URL?)
    case committed(URL?)
    case finished(title: String?, url: URL?)
    case failed(String)
    /// A navigation ended in NSURLErrorCancelled — a download policy answer,
    /// a redirect, or the user pressing stop. Not an error worth showing, but
    /// the loading state still has to clear.
    case cancelled
    case crashed
    case progressChanged(Double)
    case requestedNewWindow(URL)
    /// A link was activated with the peek modifier (⌘- or ⌥-click): the
    /// window shows it in the preview overlay instead of a new tab.
    case requestedPeek(URL)
    case requestedExternalScheme(URL)
    case downloadStarted(UUID)
    case downloadFinished(UUID)
    case downloadFailed(UUID, String)
    case audioStateChanged(TabAudioState)
    /// The tab moved between load states without a navigation event, for
    /// example when it was suspended or hibernated. The model mirrors this so
    /// the UI and the sleep policy agree about what is actually loaded.
    case lifecycleChanged(TabLifecycle)
    /// The user chose "Ask Browsemium AI" from the page context menu.
    case requestedAISelection
    /// The pointer entered or left a link in the page. `nil` clears the
    /// status bar; only the active tab's events should be displayed.
    case linkHovered(URL?)
    /// The element picker resolved a page element the user clicked. The
    /// selector was verified against the live document before it left the
    /// page; `matchCount` is how many elements it matches there.
    case elementPicked(ElementPick)
    /// The user pressed Esc (or the page went away) during element picking.
    case elementPickCancelled
    /// The clicked element had no durable selector, so nothing was picked.
    case elementPickFailed
}

/// One element the user chose to hide. `selector` round-trips to the element
/// in the document it was picked from.
public struct ElementPick: Sendable, Equatable {
    public let selector: String
    public let label: String
    public let matchCount: Int

    public init(selector: String, label: String, matchCount: Int) {
        self.selector = selector
        self.label = label
        self.matchCount = matchCount
    }
}
