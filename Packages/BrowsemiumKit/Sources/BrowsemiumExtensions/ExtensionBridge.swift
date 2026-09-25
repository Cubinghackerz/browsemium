import BrowsemiumCore
import Foundation
import WebKit

/// A tab as extensions see it. The host snapshots the model's state on each
/// request, so extension `tabs.*` calls always reflect the live strip.
public struct ExtensionTabSnapshot: Sendable, Hashable {
    public let id: TabID
    public let title: String
    public let url: URL?
    public let isPinned: Bool
    public let isActive: Bool
    public let isLoading: Bool
    public let index: Int

    public init(
        id: TabID,
        title: String,
        url: URL?,
        isPinned: Bool,
        isActive: Bool,
        isLoading: Bool,
        index: Int
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.isPinned = isPinned
        self.isActive = isActive
        self.isLoading = isLoading
        self.index = index
    }
}

/// What the extension host needs from the browser window. Implemented by the
/// window model; the host never touches model state directly, and every
/// action an extension takes goes through the same code path as a user click.
@MainActor
public protocol ExtensionHostBridging: AnyObject {
    /// The tabs extensions may see, in strip order.
    func extensionTabSnapshots() -> [ExtensionTabSnapshot]
    func extensionActivateTab(_ tabID: TabID) -> Bool
    func extensionCloseTab(_ tabID: TabID) -> Bool
    func extensionLoadURL(_ url: URL, in tabID: TabID) -> Bool
    /// Opens a new tab; `active` follows the extension's request.
    @discardableResult
    func extensionCreateTab(url: URL?, active: Bool) -> TabID?
    /// Whether the window's session is private. Extensions use it to gate
    /// incognito access; defaulting to false keeps them conservative.
    func extensionIsPrivateSession() -> Bool
}

extension ExtensionHostBridging {
    public func extensionIsPrivateSession() -> Bool { false }
}

/// A permission request an extension made, waiting for the user's answer.
/// Denying is always safe: the extension keeps working without the grant.
public struct ExtensionPermissionRequest: Identifiable, Sendable {
    public enum Kind: Sendable, Hashable {
        /// API permissions, e.g. "storage", "alarms", "declarativeNetRequest".
        case apiPermissions([String])
        /// Host access, e.g. "https://*/*". These are the ones users should
        /// read carefully.
        case hostAccess([String])
    }

    public let id: UUID
    public let extensionID: String
    public let extensionName: String
    public let kind: Kind

    public init(id: UUID = UUID(), extensionID: String, extensionName: String, kind: Kind) {
        self.id = id
        self.extensionID = extensionID
        self.extensionName = extensionName
        self.kind = kind
    }

    /// Human-readable permission names for the prompt card.
    public var items: [String] {
        switch kind {
        case .apiPermissions(let permissions): permissions
        case .hostAccess(let patterns): patterns
        }
    }
}

/// Asks the user to grant or deny an extension permission request. The host
/// awaits the answer; a window that disappears answers deny.
@MainActor
public protocol ExtensionPermissionPrompting: AnyObject {
    func promptForExtensionPermissions(_ request: ExtensionPermissionRequest) async -> Bool
}

/// Presents an extension action's popover. Implemented by the toolbar, which
/// owns the button the popover anchors to; WebKit hands the app a preloaded
/// `NSPopover` and expects it on screen.
@available(macOS 15.4, *)
@MainActor
public protocol ExtensionActionPopupPresenting: AnyObject {
    func presentActionPopup(
        _ action: WKWebExtension.Action,
        completion: @escaping ((any Error)?) -> Void
    )
}
