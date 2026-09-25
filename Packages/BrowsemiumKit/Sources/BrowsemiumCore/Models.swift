import Foundation

public struct TabID: Hashable, Codable, Sendable, Identifiable {
    public let rawValue: UUID
    public var id: UUID { rawValue }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct SpaceID: Hashable, Codable, Sendable, Identifiable {
    public let rawValue: UUID
    public var id: UUID { rawValue }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct PaneID: Hashable, Codable, Sendable, Identifiable {
    public let rawValue: UUID
    public var id: UUID { rawValue }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct FolderID: Hashable, Codable, Sendable, Identifiable {
    public let rawValue: UUID
    public var id: UUID { rawValue }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ConversationID: Hashable, Codable, Sendable, Identifiable {
    public let rawValue: UUID
    public var id: UUID { rawValue }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum TabLifecycle: String, Codable, Sendable {
    case metadataOnly
    case loading
    case active
    case suspended
    case hibernated
    case crashed
}

public enum AIProviderID: String, CaseIterable, Codable, Sendable {
    case openAI
    case anthropic
    case gemini
    case xAI
    /// A local Ollama server. Needs no credential and never leaves the Mac.
    case ollama
    /// Vercel's v0 generative-UI API. BYOK: the user's own v0 API key, stored
    /// in the keychain like every other key.
    case vercelV0

    public var isLocal: Bool {
        self == .ollama
    }
}

public struct BrowserSpace: Hashable, Codable, Sendable, Identifiable {
    public let id: SpaceID
    public let name: String
    public let createdAt: Date
    /// Optional accent for tab groups. Hex string like "#5B8DEF".
    public let color: String?
    /// Locked spaces ask for Touch ID (or the login password) before their
    /// tabs are shown. The lock protects the window, not the disk: an
    /// unlocked Mac's files are still readable by anything running as the
    /// user, and Browsemium says so rather than implying encryption.
    public let isLocked: Bool

    public init(
        id: SpaceID = SpaceID(),
        name: String,
        createdAt: Date = Date(),
        color: String? = nil,
        isLocked: Bool = false
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.color = color
        self.isLocked = isLocked
    }

    public func renamed(_ name: String) -> BrowserSpace {
        BrowserSpace(id: id, name: name, createdAt: createdAt, color: color, isLocked: isLocked)
    }

    public func withLocked(_ isLocked: Bool) -> BrowserSpace {
        BrowserSpace(id: id, name: name, createdAt: createdAt, color: color, isLocked: isLocked)
    }

    /// Old rows and older exported sessions have no lock flag; decoding must
    /// not fail over a field that simply did not exist yet.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SpaceID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
    }
}

/// Asks the user to prove it is them before a locked space opens. Implemented
/// with `LocalAuthentication`; tests inject a fake so the gating logic is
/// exercised without a system prompt.
@MainActor
public protocol SpaceUnlockAuthenticating: AnyObject {
    /// Returns true when the user authenticated. `reason` is shown in the
    /// system prompt.
    func authenticate(reason: String) async -> Bool
}

/// A named, collapsible group of tabs inside one space — Firefox's tab
/// groups and Zen's folders. Membership lives on the tab (`folderID`); the
/// folder record only carries the label and the collapsed flag.
public struct TabFolder: Hashable, Codable, Sendable, Identifiable {
    public let id: FolderID
    public let spaceID: SpaceID
    public let name: String
    /// Optional accent, hex string like "#5B8DEF", matching BrowserSpace.
    public let color: String?
    /// Collapsed folders show as a single chip and hide their member tabs.
    public let isCollapsed: Bool
    public let createdAt: Date

    public init(
        id: FolderID = FolderID(),
        spaceID: SpaceID,
        name: String,
        color: String? = nil,
        isCollapsed: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.spaceID = spaceID
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
        self.createdAt = createdAt
    }

    public func renamed(_ name: String) -> TabFolder {
        TabFolder(id: id, spaceID: spaceID, name: name, color: color, isCollapsed: isCollapsed, createdAt: createdAt)
    }

    public func withCollapsed(_ isCollapsed: Bool) -> TabFolder {
        TabFolder(id: id, spaceID: spaceID, name: name, color: color, isCollapsed: isCollapsed, createdAt: createdAt)
    }
}

public struct BrowserTab: Hashable, Codable, Sendable, Identifiable {
    public let id: TabID
    public let spaceID: SpaceID
    public let title: String
    public let lastCommittedURL: URL?
    public let position: Int
    public let isPinned: Bool
    /// Folder membership inside the tab's space. Pinned tabs are never in a
    /// folder: pinning a tab clears this.
    public let folderID: FolderID?
    public let lifecycle: TabLifecycle
    public let createdAt: Date
    public let lastAccessedAt: Date

    public var url: URL? { lastCommittedURL }

    public init(
        id: TabID = TabID(),
        spaceID: SpaceID,
        title: String,
        lastCommittedURL: URL? = nil,
        position: Int = 0,
        isPinned: Bool = false,
        folderID: FolderID? = nil,
        lifecycle: TabLifecycle = .metadataOnly,
        createdAt: Date = Date(),
        lastAccessedAt: Date = Date()
    ) {
        self.id = id
        self.spaceID = spaceID
        self.title = title
        self.lastCommittedURL = lastCommittedURL
        self.position = position
        self.isPinned = isPinned
        self.folderID = folderID
        self.lifecycle = lifecycle
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
    }

    /// Field-by-field copies were dropping folder membership on every title
    /// or lifecycle update; `replaced` makes the carried fields explicit.
    /// Double-optional fields keep the existing value when omitted and clear
    /// when passed `.some(nil)`.
    public func replaced(
        spaceID: SpaceID? = nil,
        title: String? = nil,
        lastCommittedURL: URL?? = nil,
        position: Int? = nil,
        isPinned: Bool? = nil,
        folderID: FolderID?? = nil,
        lifecycle: TabLifecycle? = nil,
        lastAccessedAt: Date? = nil
    ) -> BrowserTab {
        BrowserTab(
            id: id,
            spaceID: spaceID ?? self.spaceID,
            title: title ?? self.title,
            lastCommittedURL: lastCommittedURL ?? self.lastCommittedURL,
            position: position ?? self.position,
            isPinned: isPinned ?? self.isPinned,
            folderID: folderID ?? self.folderID,
            lifecycle: lifecycle ?? self.lifecycle,
            createdAt: createdAt,
            lastAccessedAt: lastAccessedAt ?? self.lastAccessedAt
        )
    }
}

public struct BrowserSessionState: Hashable, Codable, Sendable {
    public let spaces: [BrowserSpace]
    public let tabs: [BrowserTab]
    /// Folder records for all spaces. Membership is on the tab (`folderID`);
    /// this list is the folders' names, colours, and collapsed flags.
    public let folders: [TabFolder]
    public let activeSpaceID: SpaceID
    public let activeTabID: TabID?
    public let isPrivate: Bool

    /// `folders` has no default: rebuilding the session without it would
    /// silently drop every folder the user created.
    public init(
        spaces: [BrowserSpace],
        tabs: [BrowserTab],
        folders: [TabFolder],
        activeSpaceID: SpaceID,
        activeTabID: TabID?,
        isPrivate: Bool = false
    ) {
        self.spaces = spaces
        self.tabs = tabs
        self.folders = folders
        self.activeSpaceID = activeSpaceID
        self.activeTabID = activeTabID
        self.isPrivate = isPrivate
    }
}

public struct NavigationRequest: Hashable, Codable, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }
}

public enum CaptureKind: String, Codable, Sendable {
    case selection
    case readablePage
    case viewportImage
    case fullPageImage
}

public struct CaptureRequest: Hashable, Codable, Sendable {
    public let kinds: Set<CaptureKind>

    public init(kinds: Set<CaptureKind>) {
        self.kinds = kinds
    }
}

public struct PageTextContext: Hashable, Codable, Sendable {
    public let url: URL?
    public let title: String?
    public let text: String
    public let isTruncated: Bool

    public init(url: URL? = nil, title: String? = nil, text: String, isTruncated: Bool = false) {
        self.url = url
        self.title = title
        self.text = text
        self.isTruncated = isTruncated
    }
}

/// The small, automatic context attached to web-provider messages. This is
/// intentionally separate from readable page text and screenshots: metadata
/// can be enabled by default, while richer page context always requires an
/// explicit user action.
public struct PageMetadataContext: Hashable, Codable, Sendable {
    public let title: String
    public let url: URL

    public init?(title: String?, url: URL?) {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        components?.fragment = nil
        // Query strings commonly contain search terms, tokens, and tracking
        // identifiers. The host and path identify the page without copying
        // those values into an AI prompt.
        components?.query = nil
        guard let safeURL = components?.url else { return nil }

        let trimmedTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = String(trimmedTitle.prefix(240))
        self.url = safeURL
    }

    public var asPageTextContext: PageTextContext {
        PageTextContext(url: url, title: title, text: "")
    }
}

public struct PageImageContext: Hashable, Codable, Sendable {
    public let data: Data
    public let mimeType: String
    public let width: Int
    public let height: Int

    public init(data: Data, mimeType: String, width: Int, height: Int) {
        self.data = data
        self.mimeType = mimeType
        self.width = width
        self.height = height
    }
}

/// A user-selected file staged inside Browsemium's private temporary area.
/// The URL is never persisted as conversation content; it is only resolved by
/// the active provider/runtime while the attachment is alive.
public struct AIFileAttachment: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let fileURL: URL
    public let filename: String
    public let mimeType: String
    public let byteCount: Int64

    public init(
        id: UUID = UUID(),
        fileURL: URL,
        filename: String,
        mimeType: String,
        byteCount: Int64
    ) {
        self.id = id
        self.fileURL = fileURL
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
    }
}

public enum AIContextAttachment: Sendable {
    case selection(PageTextContext)
    case readablePage(PageTextContext)
    case viewportImage(PageImageContext)
    case fullPageImage(PageImageContext)
    case file(AIFileAttachment)

    /// Text drawn from the page itself — what "include page context"
    /// settings mean. Images and user-picked files are never automatic.
    public var isPageText: Bool {
        switch self {
        case .selection, .readablePage: true
        case .viewportImage, .fullPageImage, .file: false
        }
    }
}

public struct CapturedContext: Sendable {
    public let attachments: [AIContextAttachment]

    public init(attachments: [AIContextAttachment]) {
        self.attachments = attachments
    }
}

public enum SitePermissionDecision: String, Hashable, Codable, Sendable {
    case ask
    case allow
    case deny
}

public enum BrowserCommand: Hashable, Sendable {
    case newTab
    case closeTab(TabID)
    case selectTab(TabID)
    case toggleAIDock
    case toggleCommandPalette
    case reload
    case stopLoading
    case goBack
    case goForward
    case toggleBookmark
    case reopenClosedTab
    case openHistory
    case openBookmarks
    case openDownloads
    case openSettings
    case clearBrowsingData
    case aiQuickAction(AIQuickAction)
    case zoomIn
    case zoomOut
    case resetZoom
    case savePageAsPDF
    case savePageScreenshot
    case togglePictureInPicture
    case toggleTabLayout
    case toggleSplitView
    case switchSpace(SpaceID)
    case openURLInNewTab(URL)
    case searchFor(String)
    case moveTabToSpace(TabID, SpaceID)
    case assignTabToFolder(TabID, FolderID?)
    case openTabInSplit(TabID)
    case runAISkill(AISkill)
    case summarizeOpenTabs
    case duplicateTab(TabID)
    case copyTabURL(TabID)
    case selectAdjacentTab(forward: Bool)
    case closeOtherTabs(TabID)
    case newPrivateWindow
}

/// One-tap assistant workflows. Each bundles a context capture with a canned
/// instruction; the send still passes through the review sheet, so nothing
/// reaches a provider without an explicit confirm.
public enum AIQuickAction: String, Hashable, Sendable, CaseIterable {
    case summarizePage
    case keyPoints
    case explainSelection
    case rewriteSelection
    case shortenSelection
    case bulletPoints

    public var title: String {
        switch self {
        case .summarizePage: "Summarize this page"
        case .keyPoints: "Extract key points"
        case .explainSelection: "Explain the selection"
        case .rewriteSelection: "Rewrite the selection"
        case .shortenSelection: "Shorten the selection"
        case .bulletPoints: "Turn the selection into bullets"
        }
    }

    /// The prompt sent for the action when the composer is empty.
    public var prompt: String {
        switch self {
        case .summarizePage:
            "Summarize this page in a few short paragraphs."
        case .keyPoints:
            "List the key points of this page as bullets."
        case .explainSelection:
            "Explain the selected text."
        case .rewriteSelection:
            "Rewrite the selected text so it is clearer, keeping its meaning and tone."
        case .shortenSelection:
            "Shorten the selected text without losing meaning."
        case .bulletPoints:
            "Turn the selected text into a short bullet list."
        }
    }

    /// The page context the action captures before the review sheet opens.
    public var captureKind: CaptureKind {
        switch self {
        case .summarizePage, .keyPoints: .readablePage
        case .explainSelection, .rewriteSelection, .shortenSelection, .bulletPoints: .selection
        }
    }

    /// Writing assists put text in the composer for the user to copy; they
    /// never type into the page.
    public var isWritingAssist: Bool {
        switch self {
        case .rewriteSelection, .shortenSelection, .bulletPoints: true
        case .summarizePage, .keyPoints, .explainSelection: false
        }
    }
}

/// A saved prompt the user can re-run from the palette or the assistant.
/// Skills are local rows in the profile database — never uploaded, never
/// shared, and never sent anywhere until the user sends a message.
public struct AISkill: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let prompt: String
    public let createdAt: Date

    public init(id: UUID = UUID(), name: String, prompt: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.createdAt = createdAt
    }

    // Identity is the row's id, not its fields: a skill that has been through
    // the database and back must still equal the value the caller saved.
    // SQLite does not preserve `Date` to the microsecond, and synthesized
    // equality made the same skill compare unequal after a reload.
    public static func == (lhs: AISkill, rhs: AISkill) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public enum BrowserPanel: Hashable, Sendable {
    case none
    case history
    case bookmarks
    case downloads
    case recentlyClosed
    case settings
}

public struct AIModel: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let providerID: AIProviderID

    public init(id: String, name: String, providerID: AIProviderID) {
        self.id = id
        self.name = name
        self.providerID = providerID
    }
}

public enum AIMessageRole: String, Hashable, Codable, Sendable {
    case system
    case user
    case assistant
}

public struct AIMessage: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let role: AIMessageRole
    public let content: String
    public let createdAt: Date

    public init(id: UUID = UUID(), role: AIMessageRole, content: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

public struct AIConversation: Hashable, Codable, Sendable, Identifiable {
    public let id: ConversationID
    public let title: String
    public let messages: [AIMessage]
    public let createdAt: Date

    public init(
        id: ConversationID = ConversationID(),
        title: String,
        messages: [AIMessage] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
    }
}

public struct AIRequest: Sendable {
    public let model: AIModel
    public let messages: [AIMessage]
    public let attachments: [AIContextAttachment]

    public init(model: AIModel, messages: [AIMessage], attachments: [AIContextAttachment] = []) {
        self.model = model
        self.messages = messages
        self.attachments = attachments
    }
}

public enum AIEvent: Sendable {
    case textDelta(String)
    case completed(AIMessage)
}

public enum BrowsemiumError: Error, Equatable, Sendable {
    case emptyNavigationInput
    case blockedScheme(String)
    case unsupportedScheme(String)
    case malformedURL(String)
    case credentialsNotAllowed
    case privateSessionPersistenceUnsupported
    case invalidCredential
    case providerUnavailable(AIProviderID)
    case databaseFailure(String)
    case webContentUnavailable
    case captureUnavailable(String)
    case captureFailed(String)
    case fileNotAllowed(String)
    case fileTooLarge(String)
    case fileUnavailable(String)
    case providerUploadFailed(String)
}

extension BrowsemiumError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyNavigationInput:
            "Enter an address or search term."
        case .blockedScheme(let scheme):
            "The \(scheme) URL scheme is blocked."
        case .unsupportedScheme(let scheme):
            "The \(scheme) URL scheme is not supported."
        case .malformedURL(let value):
            "The address is malformed: \(value)"
        case .credentialsNotAllowed:
            "Addresses containing credentials are not allowed."
        case .privateSessionPersistenceUnsupported:
            "Private browsing sessions cannot be persisted."
        case .invalidCredential:
            "The provider credential is invalid."
        case .providerUnavailable(let provider):
            "The \(provider.rawValue) provider is unavailable."
        case .databaseFailure(let message):
            message
        case .webContentUnavailable:
            "The page is not loaded yet."
        case .captureUnavailable(let message):
            message
        case .captureFailed(let message):
            message
        case .fileNotAllowed(let message):
            message
        case .fileTooLarge(let message):
            message
        case .fileUnavailable(let message):
            message
        case .providerUploadFailed(let message):
            message
        }
    }
}
