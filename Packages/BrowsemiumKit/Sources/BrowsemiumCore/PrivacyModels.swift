import Foundation

public enum ProtectionLevel: String, CaseIterable, Codable, Sendable {
    case off
    case standard
    case strict

    public var title: String {
        switch self {
        case .off: "Off"
        case .standard: "Balanced"
        case .strict: "Strict"
        }
    }

    public var summary: String {
        switch self {
        case .off:
            "No bundled blocking rules. WebKit's own tracking protection stays on."
        case .standard:
            "Blocks ads and trackers with the bundled rules. WebKit's own tracking protection stays on."
        case .strict:
            Self.strictSummary
        }
    }

    private static var strictSummary: String {
        var sentences = ["Strict upgrades http pages to https, except local addresses."]
        if #available(macOS 26.4, *) {
            sentences.append("Pages run with JavaScript JIT disabled, which can slow heavy web apps.")
        } else {
            sentences.append("JavaScript JIT hardening needs macOS 26.4 or newer.")
        }
        if #available(macOS 27.0, *) {
            sentences.insert("Strict sends the Global Privacy Control signal.", at: 0)
        } else {
            sentences.append("The Global Privacy Control signal needs macOS 27 or newer.")
        }
        return sentences.joined(separator: " ")
    }

    public var blocksContentRules: Bool {
        self != .off
    }

    public var sendsGlobalPrivacyControl: Bool {
        self == .strict
    }

    public var requiresHTTPS: Bool {
        self == .strict
    }

    public var hardensWebContent: Bool {
        self == .strict
    }

    public static let plaintextExemptHosts: Set<String> = [
        "localhost", "127.0.0.1", "::1", "[::1]"
    ]

    public static let blockingPreference = "blocking"
    public static let blockingPausedValue = "paused"

    public static func rulesEnabled(
        protectionBlocksContent: Bool,
        pausedHosts: Set<String>,
        host: String?
    ) -> Bool {
        guard protectionBlocksContent else { return false }
        guard let host else { return true }
        return !pausedHosts.contains(host.lowercased())
    }

    public func httpsUpgrade(of url: URL) -> URL? {
        guard requiresHTTPS, url.scheme?.lowercased() == "http" else { return nil }
        guard let host = url.host?.lowercased(), !Self.plaintextExemptHosts.contains(host) else {
            return nil
        }
        if let port = url.port, port != 80 { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = "https"
        components.port = nil
        return components.url
    }
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

/// Where open tabs live in the window. `top` is the classic strip; `sidebar`
/// is a vertical list down the leading edge, which scales to many tabs and
/// keeps full titles readable — the Arc/Zen/Firefox pattern.
public enum TabLayout: String, CaseIterable, Codable, Sendable {
    case top
    case sidebar

    public var title: String {
        switch self {
        case .top: "Top"
        case .sidebar: "Sidebar"
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
    public var protectionLevel: ProtectionLevel
    public var persistAIConversations: Bool
    public var isAIDockEnabled: Bool
    /// Adds sanitized page metadata and bounded readable page text to
    /// web-provider sends. Screenshots and files are always explicit user
    /// attachments.
    public var includePageMetadataInWebAI: Bool
    /// When on, an API send with no page context attached captures the
    /// readable page text first — the review sheet then shows it before
    /// anything is transmitted. Off by default: automatic capture should be
    /// a deliberate choice, not a surprise.
    public var includePageContextInAPIAI: Bool

    /// Memory saver unloads background tabs aggressively.
    public var memorySaverEnabled: Bool
    /// Minutes a background tab may sit idle before it is unloaded.
    public var tabSleepMinutes: Int
    /// Ceiling on simultaneously loaded tabs.
    public var maximumLiveTabs: Int
    /// Keeps one WebKit process warm so new tabs open faster.
    public var warmTabPreloading: Bool
    /// Whether tabs sit in a top strip or a leading sidebar.
    public var tabLayout: TabLayout
    /// Opens the peek overlay after the pointer rests on a link. Off by
    /// default: the preview loads the page, so hovering becomes a network
    /// request — that should be a deliberate choice.
    public var linkPreviewOnHover: Bool
    /// Offers one-click install when a Chrome Web Store extension listing is
    /// open in the active tab. On by default; turning it off keeps the store
    /// an ordinary web page.
    public var offerWebStoreInstalls: Bool

    public var contentBlockingEnabled: Bool {
        protectionLevel.blocksContentRules
    }

    public init(
        searchEngineTemplate: String = SearchEnginePreset.google.template,
        appearance: AppearancePreference = .system,
        historyRetentionDays: Int? = 90,
        clearOnQuit: Bool = false,
        protectionLevel: ProtectionLevel = .standard,
        persistAIConversations: Bool = false,
        isAIDockEnabled: Bool = true,
        includePageMetadataInWebAI: Bool = true,
        includePageContextInAPIAI: Bool = false,
        memorySaverEnabled: Bool = true,
        tabSleepMinutes: Int = 5,
        maximumLiveTabs: Int = 4,
        warmTabPreloading: Bool = true,
        tabLayout: TabLayout = .top,
        linkPreviewOnHover: Bool = false,
        offerWebStoreInstalls: Bool = true
    ) {
        self.searchEngineTemplate = searchEngineTemplate
        self.appearance = appearance
        self.historyRetentionDays = historyRetentionDays
        self.clearOnQuit = clearOnQuit
        self.protectionLevel = protectionLevel
        self.persistAIConversations = persistAIConversations
        self.isAIDockEnabled = isAIDockEnabled
        self.includePageMetadataInWebAI = includePageMetadataInWebAI
        self.includePageContextInAPIAI = includePageContextInAPIAI
        self.memorySaverEnabled = memorySaverEnabled
        self.tabSleepMinutes = tabSleepMinutes
        self.maximumLiveTabs = maximumLiveTabs
        self.warmTabPreloading = warmTabPreloading
        self.tabLayout = tabLayout
        self.linkPreviewOnHover = linkPreviewOnHover
        self.offerWebStoreInstalls = offerWebStoreInstalls
    }

    private enum CodingKeys: String, CodingKey {
        case searchEngineTemplate
        case appearance
        case historyRetentionDays
        case clearOnQuit
        case protectionLevel
        case persistAIConversations
        case isAIDockEnabled
        case includePageMetadataInWebAI
        case includePageContextInAPIAI
        case memorySaverEnabled
        case tabSleepMinutes
        case maximumLiveTabs
        case warmTabPreloading
        case contentBlockingEnabled
        case tabLayout
        case linkPreviewOnHover
        case offerWebStoreInstalls
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
        try container.encode(protectionLevel, forKey: .protectionLevel)
        try container.encode(persistAIConversations, forKey: .persistAIConversations)
        try container.encode(isAIDockEnabled, forKey: .isAIDockEnabled)
        try container.encode(includePageMetadataInWebAI, forKey: .includePageMetadataInWebAI)
        try container.encode(includePageContextInAPIAI, forKey: .includePageContextInAPIAI)
        try container.encode(memorySaverEnabled, forKey: .memorySaverEnabled)
        try container.encode(tabSleepMinutes, forKey: .tabSleepMinutes)
        try container.encode(maximumLiveTabs, forKey: .maximumLiveTabs)
        try container.encode(warmTabPreloading, forKey: .warmTabPreloading)
        try container.encode(tabLayout, forKey: .tabLayout)
        try container.encode(linkPreviewOnHover, forKey: .linkPreviewOnHover)
        try container.encode(offerWebStoreInstalls, forKey: .offerWebStoreInstalls)
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
        let storedLevel = try container.decodeIfPresent(ProtectionLevel.self, forKey: .protectionLevel)
        let legacyBlocking = try container.decodeIfPresent(Bool.self, forKey: .contentBlockingEnabled)
        if legacyBlocking == false {
            protectionLevel = .off
        } else if let storedLevel {
            protectionLevel = storedLevel
        } else {
            protectionLevel = defaults.protectionLevel
        }
        persistAIConversations = try container.decodeIfPresent(Bool.self, forKey: .persistAIConversations) ?? defaults.persistAIConversations
        isAIDockEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAIDockEnabled) ?? defaults.isAIDockEnabled
        includePageMetadataInWebAI = try container.decodeIfPresent(Bool.self, forKey: .includePageMetadataInWebAI) ?? defaults.includePageMetadataInWebAI
        includePageContextInAPIAI = try container.decodeIfPresent(Bool.self, forKey: .includePageContextInAPIAI) ?? defaults.includePageContextInAPIAI
        memorySaverEnabled = try container.decodeIfPresent(Bool.self, forKey: .memorySaverEnabled) ?? defaults.memorySaverEnabled
        tabSleepMinutes = try container.decodeIfPresent(Int.self, forKey: .tabSleepMinutes) ?? defaults.tabSleepMinutes
        maximumLiveTabs = try container.decodeIfPresent(Int.self, forKey: .maximumLiveTabs) ?? defaults.maximumLiveTabs
        warmTabPreloading = try container.decodeIfPresent(Bool.self, forKey: .warmTabPreloading) ?? defaults.warmTabPreloading
        tabLayout = try container.decodeIfPresent(TabLayout.self, forKey: .tabLayout) ?? defaults.tabLayout
        linkPreviewOnHover = try container.decodeIfPresent(Bool.self, forKey: .linkPreviewOnHover) ?? defaults.linkPreviewOnHover
        offerWebStoreInstalls = try container.decodeIfPresent(Bool.self, forKey: .offerWebStoreInstalls) ?? defaults.offerWebStoreInstalls
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
