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
    case crashed
    case progressChanged(Double)
    case requestedNewWindow(URL)
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
}
