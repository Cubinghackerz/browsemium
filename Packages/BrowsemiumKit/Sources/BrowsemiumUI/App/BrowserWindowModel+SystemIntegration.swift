import BrowsemiumCore
import Foundation

extension BrowserWindowModel {
    /// The address Handoff may offer for this window's active tab, or nil.
    /// Nil whenever the setting is off, the window is private, the space is
    /// locked or keeps its own data, or the page is not plain https. The
    /// rules live in `HandoffPolicy`; this only gathers the inputs.
    public var handoffURL: URL? {
        guard isHandoffEnabled, let tabID = session.activeTabID else { return nil }
        let space = session.spaces.first { $0.id == session.activeSpaceID }
        return HandoffPolicy.shareableURL(
            tabURLs[tabID] ?? activeTab?.lastCommittedURL,
            isPrivate: session.isPrivate,
            isSpaceLocked: isSpaceLocked(session.activeSpaceID),
            hasSeparateData: space?.hasSeparateData ?? false
        )
    }

    /// Opens a Spotlight result. The identifier must still name an eligible
    /// bookmark and the feature must still be on; otherwise nothing opens.
    public func openSpotlightResult(identifier: String) {
        guard !session.isPrivate, let url = environment.spotlight.resolve(identifier: identifier) else {
            statusMessage = "That bookmark is no longer available."
            return
        }
        newTab(url: url)
    }

    /// Opens an address handed off from another device. Only plain https, and
    /// only while the Handoff setting is on.
    public func openHandedOff(_ url: URL?) {
        guard isHandoffEnabled, !session.isPrivate, HandoffPolicy.isAcceptableIncoming(url), let url else { return }
        newTab(url: url)
    }
}
