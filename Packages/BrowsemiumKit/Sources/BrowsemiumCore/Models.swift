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
}

public struct BrowserSpace: Hashable, Codable, Sendable, Identifiable {
    public let id: SpaceID
    public let name: String
    public let createdAt: Date
    /// Optional accent for tab groups. Hex string like "#5B8DEF".
    public let color: String?

    public init(id: SpaceID = SpaceID(), name: String, createdAt: Date = Date(), color: String? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.color = color
    }
}

public struct BrowserTab: Hashable, Codable, Sendable, Identifiable {
    public let id: TabID
    public let spaceID: SpaceID
    public let title: String
    public let lastCommittedURL: URL?
    public let position: Int
    public let isPinned: Bool
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
        self.lifecycle = lifecycle
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
    }
}

public struct BrowserSessionState: Hashable, Codable, Sendable {
    public let spaces: [BrowserSpace]
    public let tabs: [BrowserTab]
    public let activeSpaceID: SpaceID
    public let activeTabID: TabID?
    public let isPrivate: Bool

    public init(
        spaces: [BrowserSpace],
        tabs: [BrowserTab],
        activeSpaceID: SpaceID,
        activeTabID: TabID?,
        isPrivate: Bool = false
    ) {
        self.spaces = spaces
        self.tabs = tabs
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

public enum AIContextAttachment: Sendable {
    case selection(PageTextContext)
    case readablePage(PageTextContext)
    case viewportImage(PageImageContext)
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
}

public enum BrowserPanel: Hashable, Sendable {
    case none
    case history
    case bookmarks
    case downloads
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
        }
    }
}
