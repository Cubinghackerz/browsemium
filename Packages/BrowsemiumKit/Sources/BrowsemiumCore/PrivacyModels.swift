import Foundation

public enum ProtectionLevel: String, CaseIterable, Codable, Sendable {
    case off
    case standard
    case strict
}

public enum AppearancePreference: String, CaseIterable, Codable, Sendable {
    case system
    case light
    case dark

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

public enum SitePermissionKind: String, CaseIterable, Codable, Sendable {
    case camera
    case microphone
    case location
    case notifications
    case popups
    case downloads
}

public struct SitePermissionRecord: Hashable, Codable, Sendable, Identifiable {
    public var id: String { "\(origin)|\(kind.rawValue)" }
    public let origin: String
    public let kind: SitePermissionKind
    public let decision: SitePermissionDecision
    public let updatedAt: Date

    public init(origin: String, kind: SitePermissionKind, decision: SitePermissionDecision, updatedAt: Date = Date()) {
        self.origin = origin
        self.kind = kind
        self.decision = decision
        self.updatedAt = updatedAt
    }
}

/// What the user chose in a permission prompt.
public enum SitePermissionAnswer: Sendable, Equatable {
    /// Allowed for this page load only; nothing is written down.
    case allowOnce
    /// Allowed and remembered for the origin.
    case allowAlways
    /// Denied and remembered for the origin.
    case block
}

public struct SearchEnginePreset: Hashable, Codable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let template: String

    public init(name: String, template: String) {
        self.name = name
        self.template = template
    }

    public static let google = SearchEnginePreset(name: "Google", template: "https://www.google.com/search?q=")
    public static let duckDuckGo = SearchEnginePreset(name: "DuckDuckGo", template: "https://duckduckgo.com/?q=")
    public static let bing = SearchEnginePreset(name: "Bing", template: "https://www.bing.com/search?q=")
    public static let brave = SearchEnginePreset(name: "Brave", template: "https://search.brave.com/search?q=")

    public static let all: [SearchEnginePreset] = [.google, .duckDuckGo, .bing, .brave]

    public static func name(for template: String) -> String {
        all.first { $0.template == template }?.name ?? "Custom"
    }

    public static func preset(for template: String) -> SearchEnginePreset? {
        all.first { $0.template == template }
    }

    /// Short prefix typed before a query to search with one engine only, e.g.
    /// "!d swift concurrency" searches DuckDuckGo without changing the default.
    public var bang: String {
        switch name {
        case "Google": "g"
        case "DuckDuckGo": "d"
        case "Bing": "b"
        case "Brave": "br"
        default: ""
        }
    }

    public static func preset(forBang bang: String) -> SearchEnginePreset? {
        all.first { $0.bang == bang.lowercased() }
    }
}

/// Splits an address-bar entry into an optional per-query search engine and the
/// remaining query text.
public enum SearchBangParser {
    public static func parse(_ input: String) -> (preset: SearchEnginePreset?, query: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("!"),
              let space = trimmed.firstIndex(of: " ") else {
            return (nil, trimmed)
        }
        let bang = String(trimmed[trimmed.index(after: trimmed.startIndex)..<space])
        let remainder = String(trimmed[trimmed.index(after: space)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let preset = SearchEnginePreset.preset(forBang: bang), !remainder.isEmpty else {
            return (nil, trimmed)
        }
        return (preset, remainder)
    }
}

public struct BrowserSettings: Hashable, Codable, Sendable {
    public var searchEngineTemplate: String
    public var appearance: AppearancePreference
    public var historyRetentionDays: Int?
    public var clearOnQuit: Bool
    public var remoteSearchSuggestions: Bool
    public var protectionLevel: ProtectionLevel
    public var persistAIConversations: Bool
    public var isAIDockEnabled: Bool
    /// Adds sanitized page metadata and bounded readable page text to
    /// web-provider sends. Screenshots and files are always explicit user
    /// attachments.
    public var includePageMetadataInWebAI: Bool

    /// Memory saver unloads background tabs aggressively.
    public var memorySaverEnabled: Bool
    /// Minutes a background tab may sit idle before it is unloaded.
    public var tabSleepMinutes: Int
    /// Ceiling on simultaneously loaded tabs.
    public var maximumLiveTabs: Int
    /// Keeps one WebKit process warm so new tabs open faster.
    public var warmTabPreloading: Bool
    /// Applies compiled content rules to block ads and trackers.
    public var contentBlockingEnabled: Bool

    public init(
        searchEngineTemplate: String = SearchEnginePreset.google.template,
        appearance: AppearancePreference = .system,
        historyRetentionDays: Int? = 90,
        clearOnQuit: Bool = false,
        remoteSearchSuggestions: Bool = false,
        protectionLevel: ProtectionLevel = .standard,
        persistAIConversations: Bool = false,
        isAIDockEnabled: Bool = true,
        includePageMetadataInWebAI: Bool = true,
        memorySaverEnabled: Bool = true,
        tabSleepMinutes: Int = 5,
        maximumLiveTabs: Int = 4,
        warmTabPreloading: Bool = true,
        contentBlockingEnabled: Bool = true
    ) {
        self.searchEngineTemplate = searchEngineTemplate
        self.appearance = appearance
        self.historyRetentionDays = historyRetentionDays
        self.clearOnQuit = clearOnQuit
        self.remoteSearchSuggestions = remoteSearchSuggestions
        self.protectionLevel = protectionLevel
        self.persistAIConversations = persistAIConversations
        self.isAIDockEnabled = isAIDockEnabled
        self.includePageMetadataInWebAI = includePageMetadataInWebAI
        self.memorySaverEnabled = memorySaverEnabled
        self.tabSleepMinutes = tabSleepMinutes
        self.maximumLiveTabs = maximumLiveTabs
        self.warmTabPreloading = warmTabPreloading
        self.contentBlockingEnabled = contentBlockingEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case searchEngineTemplate
        case appearance
        case historyRetentionDays
        case clearOnQuit
        case remoteSearchSuggestions
        case protectionLevel
        case persistAIConversations
        case isAIDockEnabled
        case includePageMetadataInWebAI
        case memorySaverEnabled
        case tabSleepMinutes
        case maximumLiveTabs
        case warmTabPreloading
        case contentBlockingEnabled
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(searchEngineTemplate, forKey: .searchEngineTemplate)
        try container.encode(appearance, forKey: .appearance)
        if let historyRetentionDays {
            try container.encode(historyRetentionDays, forKey: .historyRetentionDays)
        } else {
            try container.encodeNil(forKey: .historyRetentionDays)
        }
        try container.encode(clearOnQuit, forKey: .clearOnQuit)
        try container.encode(remoteSearchSuggestions, forKey: .remoteSearchSuggestions)
        try container.encode(protectionLevel, forKey: .protectionLevel)
        try container.encode(persistAIConversations, forKey: .persistAIConversations)
        try container.encode(isAIDockEnabled, forKey: .isAIDockEnabled)
        try container.encode(includePageMetadataInWebAI, forKey: .includePageMetadataInWebAI)
        try container.encode(memorySaverEnabled, forKey: .memorySaverEnabled)
        try container.encode(tabSleepMinutes, forKey: .tabSleepMinutes)
        try container.encode(maximumLiveTabs, forKey: .maximumLiveTabs)
        try container.encode(warmTabPreloading, forKey: .warmTabPreloading)
        try container.encode(contentBlockingEnabled, forKey: .contentBlockingEnabled)
    }

    /// Settings written by older builds must still decode; any key that did
    /// not exist falls back to the current default rather than failing.
    public init(from decoder: Decoder) throws {
        let defaults = BrowserSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        searchEngineTemplate = try container.decodeIfPresent(String.self, forKey: .searchEngineTemplate) ?? defaults.searchEngineTemplate
        appearance = try container.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? defaults.appearance
        historyRetentionDays = container.contains(.historyRetentionDays)
            ? try container.decodeIfPresent(Int.self, forKey: .historyRetentionDays)
            : defaults.historyRetentionDays
        clearOnQuit = try container.decodeIfPresent(Bool.self, forKey: .clearOnQuit) ?? defaults.clearOnQuit
        remoteSearchSuggestions = try container.decodeIfPresent(Bool.self, forKey: .remoteSearchSuggestions) ?? defaults.remoteSearchSuggestions
        protectionLevel = try container.decodeIfPresent(ProtectionLevel.self, forKey: .protectionLevel) ?? defaults.protectionLevel
        persistAIConversations = try container.decodeIfPresent(Bool.self, forKey: .persistAIConversations) ?? defaults.persistAIConversations
        isAIDockEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAIDockEnabled) ?? defaults.isAIDockEnabled
        includePageMetadataInWebAI = try container.decodeIfPresent(Bool.self, forKey: .includePageMetadataInWebAI) ?? defaults.includePageMetadataInWebAI
        memorySaverEnabled = try container.decodeIfPresent(Bool.self, forKey: .memorySaverEnabled) ?? defaults.memorySaverEnabled
        tabSleepMinutes = try container.decodeIfPresent(Int.self, forKey: .tabSleepMinutes) ?? defaults.tabSleepMinutes
        maximumLiveTabs = try container.decodeIfPresent(Int.self, forKey: .maximumLiveTabs) ?? defaults.maximumLiveTabs
        warmTabPreloading = try container.decodeIfPresent(Bool.self, forKey: .warmTabPreloading) ?? defaults.warmTabPreloading
        contentBlockingEnabled = try container.decodeIfPresent(Bool.self, forKey: .contentBlockingEnabled) ?? defaults.contentBlockingEnabled
    }

    /// Idle seconds before a background tab may be unloaded.
    public var tabSleepInterval: TimeInterval {
        TimeInterval(max(tabSleepMinutes, 1) * 60)
    }
}

public struct ClearScope: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let history = ClearScope(rawValue: 1 << 0)
    public static let downloads = ClearScope(rawValue: 1 << 1)
    public static let sitePermissions = ClearScope(rawValue: 1 << 2)
    public static let sitePreferences = ClearScope(rawValue: 1 << 3)
    public static let aiConversations = ClearScope(rawValue: 1 << 4)
    public static let closedTabs = ClearScope(rawValue: 1 << 5)

    public static let everything: ClearScope = [
        .history, .downloads, .sitePermissions, .sitePreferences, .aiConversations, .closedTabs
    ]
}
