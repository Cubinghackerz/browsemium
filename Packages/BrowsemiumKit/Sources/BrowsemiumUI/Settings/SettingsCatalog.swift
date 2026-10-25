import Foundation

/// The sections of Settings, in sidebar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, tabs, privacy, passwords, assistant, extensions, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .tabs: "Tabs & Spaces"
        case .privacy: "Privacy & Security"
        case .passwords: "Passwords"
        case .assistant: "Assistant"
        case .extensions: "Extensions"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .tabs: "rectangle.stack"
        case .privacy: "hand.raised"
        case .passwords: "key"
        case .assistant: "sparkles"
        case .extensions: "puzzlepiece.extension"
        case .about: "info.circle"
        }
    }
}

/// Every Settings card, once.
enum SettingsCardID: String, CaseIterable, Identifiable {
    case general, profiles, importGuide, systemIntegration
    case browsing, performance, routing, pageWatch
    case privacy, filterLists, sitePermissions, pageIndex
    case passwords
    case assistant, agent
    case extensions
    case about

    var id: String { rawValue }
}

/// Which section holds each card, and the words that should find it.
enum SettingsCatalog {
    struct Entry {
        let card: SettingsCardID
        let pane: SettingsPane
        let title: String
        let keywords: [String]
    }

    static let entries: [Entry] = [
        Entry(card: .general, pane: .general, title: "General",
              keywords: ["appearance", "dark", "light", "tab layout", "sidebar", "toolbar size", "compact", "default browser", "screenshot", "watermark"]),
        Entry(card: .profiles, pane: .general, title: "Profiles",
              keywords: ["profile", "account", "switch", "work", "personal"]),
        Entry(card: .importGuide, pane: .general, title: "Move to Browsemium",
              keywords: ["import", "chrome", "firefox", "safari", "bookmarks", "migrate", "switch"]),
        Entry(card: .systemIntegration, pane: .general, title: "Spotlight & Handoff",
              keywords: ["spotlight", "search", "handoff", "iphone", "ipad", "continuity", "bookmarks", "other devices", "system"]),
        Entry(card: .browsing, pane: .tabs, title: "Browsing",
              keywords: ["search engine", "history", "retention", "clear on quit", "hover", "preview", "developer tools", "inspector", "web store"]),
        Entry(card: .performance, pane: .tabs, title: "Performance & Memory",
              keywords: ["memory", "saver", "unload", "sleep", "archive", "warm", "battery", "speed"]),
        Entry(card: .routing, pane: .tabs, title: "Site routing",
              keywords: ["route", "space", "group", "domain", "work", "send site"]),
        Entry(card: .pageWatch, pane: .tabs, title: "Page watches",
              keywords: ["watch", "notify", "change", "alert", "notification"]),
        Entry(card: .privacy, pane: .privacy, title: "Privacy & Blocking",
              keywords: ["blocking", "protection", "tracking", "ads", "https", "cookies", "clear", "history", "global privacy control", "strict"]),
        Entry(card: .filterLists, pane: .privacy, title: "User filter lists",
              keywords: ["filter", "list", "adblock", "block", "rules", "import list"]),
        Entry(card: .sitePermissions, pane: .privacy, title: "Site permissions",
              keywords: ["camera", "microphone", "location", "permission", "allow", "block"]),
        Entry(card: .pageIndex, pane: .privacy, title: "Page text index",
              keywords: ["index", "full text", "search pages", "page text", "resume topics", "clear index", "exclude site"]),
        Entry(card: .passwords, pane: .passwords, title: "Passwords",
              keywords: ["password", "keychain", "login", "credentials", "csv", "export", "save"]),
        Entry(card: .assistant, pane: .assistant, title: "Assistant",
              keywords: ["ai", "api key", "openai", "claude", "gemini", "ollama", "apple intelligence", "dock", "context"]),
        Entry(card: .agent, pane: .assistant, title: "External agents",
              keywords: ["mcp", "agent", "automation", "endpoint", "token", "claude code", "grant"]),
        Entry(card: .extensions, pane: .extensions, title: "Extensions",
              keywords: ["extension", "chrome web store", "install", "crx", "toolbar", "add-on"]),
        Entry(card: .about, pane: .about, title: "About",
              keywords: ["version", "update", "licence", "license", "credits", "privacy policy"])
    ]

    static func cards(in pane: SettingsPane) -> [SettingsCardID] {
        entries.filter { $0.pane == pane }.map(\.card)
    }

    /// Cards whose title or keywords contain every word of the query,
    /// ignoring case and diacritics, in sidebar order.
    static func cards(matching query: String) -> [SettingsCardID] {
        let words = query.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return entries.filter { entry in
            let haystack = ([entry.title] + entry.keywords + [entry.pane.title]).joined(separator: " ")
                .lowercased().folding(options: .diacriticInsensitive, locale: nil)
            return words.allSatisfy { haystack.contains($0) }
        }
        .sorted { lhs, rhs in
            let order = SettingsPane.allCases
            return order.firstIndex(of: lhs.pane)! < order.firstIndex(of: rhs.pane)!
        }
        .map(\.card)
    }
}
