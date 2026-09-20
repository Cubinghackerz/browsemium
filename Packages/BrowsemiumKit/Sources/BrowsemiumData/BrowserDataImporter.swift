import BrowsemiumCore
import Foundation
import GRDB

public enum BrowserImportSource: String, CaseIterable, Identifiable, Sendable {
    case chrome
    case brave
    case edge
    case vivaldi
    case arc
    case chromium
    case firefox
    case safari

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chrome: "Chrome"
        case .brave: "Brave"
        case .edge: "Microsoft Edge"
        case .vivaldi: "Vivaldi"
        case .arc: "Arc"
        case .chromium: "Chromium"
        case .firefox: "Firefox"
        case .safari: "Safari"
        }
    }

    /// Which reader and encryption scheme applies.
    public enum Family: Sendable {
        case chromium
        case firefox
        case safari
    }

    public var family: Family {
        switch self {
        case .chrome, .brave, .edge, .vivaldi, .arc, .chromium: .chromium
        case .firefox: .firefox
        case .safari: .safari
        }
    }

    /// The keychain item holding this browser's password-encryption key.
    /// Chromium-family browsers all use the same scheme with their own item.
    public var safeStorageService: String? {
        switch self {
        case .chrome: "Chrome Safe Storage"
        case .brave: "Brave Safe Storage"
        case .edge: "Microsoft Edge Safe Storage"
        case .vivaldi: "Vivaldi Safe Storage"
        case .arc: "Arc Safe Storage"
        case .chromium: "Chromium Safe Storage"
        case .firefox, .safari: nil
        }
    }

    /// Where this browser keeps its profiles, or nil when it does not use one.
    public var profileRoot: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        switch self {
        case .chrome: return base.appendingPathComponent("Google/Chrome", isDirectory: true)
        case .brave: return base.appendingPathComponent("BraveSoftware/Brave-Browser", isDirectory: true)
        case .edge: return base.appendingPathComponent("Microsoft Edge", isDirectory: true)
        case .vivaldi: return base.appendingPathComponent("Vivaldi", isDirectory: true)
        case .arc: return base.appendingPathComponent("Arc/User Data", isDirectory: true)
        case .chromium: return base.appendingPathComponent("Chromium", isDirectory: true)
        case .firefox: return base.appendingPathComponent("Firefox/Profiles", isDirectory: true)
        case .safari: return home.appendingPathComponent("Library/Safari", isDirectory: true)
        }
    }

    /// Chromium-family browsers that can have saved passwords read.
    public var supportsPasswordImport: Bool {
        safeStorageService != nil
    }
}

public struct BrowserImportResult: Sendable {
    public let bookmarks: Int
    public let historyVisits: Int
    /// Decrypted logins for the caller to store. Empty unless the user asked
    /// for passwords and granted keychain access.
    public let credentials: [ChromeLogin]
    /// The source browser's default search engine, when it could be converted.
    public let searchEngine: BrowserImportPreview.SearchEngine?

    public init(
        bookmarks: Int,
        historyVisits: Int,
        credentials: [ChromeLogin] = [],
        searchEngine: BrowserImportPreview.SearchEngine? = nil
    ) {
        self.bookmarks = bookmarks
        self.historyVisits = historyVisits
        self.credentials = credentials
        self.searchEngine = searchEngine
    }

    public var isEmpty: Bool {
        bookmarks == 0 && historyVisits == 0 && credentials.isEmpty && searchEngine == nil
    }
}

/// What a profile contains, before anything is written to Browsemium.
public struct BrowserImportPreview: Sendable {
    public struct Bookmark: Sendable, Hashable {
        public let url: URL
        public let title: String
        public let folder: String?
    }

    public struct Visit: Sendable, Hashable {
        public let url: URL
        public let title: String
        public let visitedAt: Date
    }

    /// A saved login, listed without its password. The password is only
    /// decrypted at import time, after the user grants keychain access.
    public struct Credential: Sendable, Hashable {
        public let url: URL
        public let username: String
    }

    public struct SearchEngine: Sendable, Hashable {
        public let name: String
        /// Browsemium's prefix form, e.g. "https://example.com/search?q=".
        public let template: String
    }

    public let source: BrowserImportSource
    public let bookmarks: [Bookmark]
    public let visits: [Visit]
    public let folders: [String]
    public let credentials: [Credential]
    public let searchEngine: SearchEngine?
    /// What this browser keeps encrypted and Browsemium will not touch.
    public let notImportable: [String]

    public var bookmarkCount: Int { bookmarks.count }
    public var historyCount: Int { visits.count }
    public var credentialCount: Int { credentials.count }

    public var earliestVisit: Date? { visits.map(\.visitedAt).min() }
    public var latestVisit: Date? { visits.map(\.visitedAt).max() }

    public var isEmpty: Bool {
        bookmarks.isEmpty && visits.isEmpty && credentials.isEmpty && searchEngine == nil
    }
}

extension BrowserImportPreview: Identifiable {
    public var id: String {
        "\(source.rawValue)-\(bookmarkCount)-\(historyCount)-\(credentialCount)"
    }
}

public struct BrowserImportOptions: Sendable {
    public var includesBookmarks: Bool
    public var includesHistory: Bool
    /// Decrypts and stores saved logins. Requires keychain access to the source
    /// browser's key, so this is off unless the user asks for it.
    public var includesPasswords: Bool
    public var includesSearchEngine: Bool
    /// Only history at or after this date is imported.
    public var historySince: Date?
    public var historyLimit: Int

    public init(
        includesBookmarks: Bool = true,
        includesHistory: Bool = true,
        includesPasswords: Bool = false,
        includesSearchEngine: Bool = false,
        historySince: Date? = nil,
        historyLimit: Int = 5_000
    ) {
        self.includesBookmarks = includesBookmarks
        self.includesHistory = includesHistory
        self.includesPasswords = includesPasswords
        self.includesSearchEngine = includesSearchEngine
        self.historySince = historySince
        self.historyLimit = historyLimit
    }
}

/// Supplies the key that unlocks a source browser's encrypted data.
///
/// Implemented by the app with a keychain read; tests supply a fixed key. The
/// importer never reads a keychain itself, so nothing is decrypted unless the
/// caller was able to obtain the key with the user's permission.
public protocol BrowserCredentialKeyProviding: Sendable {
    func safeStorageKey(for source: BrowserImportSource) throws -> Data?
}

/// Where an import should land.
public enum BrowserImportDestination: Hashable, Sendable {
    /// The profile that is currently active.
    case currentProfile
    /// A profile created from the import, named after the source.
    case newProfile
}

/// A browser profile Browsemium can read, with the standard location it lives
/// in. Profiles are outside the app sandbox, so the folder still has to be
/// granted by the user once — after that the grant is remembered.
public struct BrowserProfileCandidate: Identifiable, Sendable, Hashable {
    public let id: String
    public let source: BrowserImportSource
    public let label: String
    public let folder: URL
    public let isReadable: Bool

    public init(source: BrowserImportSource, label: String, folder: URL, isReadable: Bool) {
        self.id = "\(source.rawValue)|\(folder.path)"
        self.source = source
        self.label = label
        self.folder = folder
        self.isReadable = isReadable
    }
}

public enum BrowserImportSourceDetector {
    /// Works out which browser a folder belongs to.
    ///
    /// The path is checked first because every Chromium-family browser stores
    /// the same file names but encrypts passwords with its own keychain item —
    /// guessing "Chrome" for a Brave profile would make decryption fail. The
    /// file names are the fallback for a folder that was moved elsewhere.
    public static func detect(in folder: URL) -> BrowserImportSource? {
        let path = folder.standardizedFileURL.path
        let chromiumFamily = BrowserImportSource.allCases
            .filter { $0.family == .chromium }
            .sorted { ($0.profileRoot?.path.count ?? 0) > ($1.profileRoot?.path.count ?? 0) }
        for source in chromiumFamily {
            if let root = source.profileRoot?.standardizedFileURL.path, path.hasPrefix(root) {
                return source
            }
        }
        if let firefoxRoot = BrowserImportSource.firefox.profileRoot?.standardizedFileURL.path,
           path.hasPrefix(firefoxRoot) {
            return .firefox
        }
        if let safariRoot = BrowserImportSource.safari.profileRoot?.standardizedFileURL.path,
           path.hasPrefix(safariRoot) {
            return .safari
        }

        let contents = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        )
        if contents.contains("places.sqlite") {
            return .firefox
        }
        if contents.contains("Bookmarks.plist") || contents.contains("History.db") {
            return .safari
        }
        if contents.contains("Bookmarks") || contents.contains("History") || contents.contains("Preferences") {
            return .chrome
        }
        return nil
    }
}

public enum BrowserProfileLocator {
    public static func candidates() -> [BrowserProfileCandidate] {
        chromiumCandidates() + firefoxCandidates() + [safariCandidate()]
    }

    /// Every profile inside a browser's root folder. Used once the user has
    /// granted access to the root (for example `…/Google/Chrome`): browsers
    /// commonly hold several profiles, and each is offered separately so it
    /// can be imported into its own Browsemium profile.
    public static func profiles(
        insideBrowserRoot root: URL,
        source: BrowserImportSource
    ) -> [BrowserProfileCandidate] {
        switch source.family {
        case .chromium:
            let displayNames = chromiumDisplayNames(in: root)
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            let names = entries
                .filter { name in
                    guard name == "Default" || name.hasPrefix("Profile ") else { return false }
                    var isDirectory: ObjCBool = false
                    let exists = FileManager.default.fileExists(
                        atPath: root.appendingPathComponent(name).path,
                        isDirectory: &isDirectory
                    )
                    return exists && isDirectory.boolValue
                }
                .sorted { first, second in
                    if first == "Default" { return true }
                    if second == "Default" { return false }
                    return first.localizedStandardCompare(second) == .orderedAscending
                }
            return names.map { name in
                let folder = root.appendingPathComponent(name, isDirectory: true)
                let display = displayNames[name]
                let label: String
                if let display, display != name {
                    label = "\(source.displayName) — \(display)"
                } else if name == "Default" {
                    label = "\(source.displayName) — Default"
                } else {
                    label = "\(source.displayName) — \(name)"
                }
                return BrowserProfileCandidate(
                    source: source,
                    label: label,
                    folder: folder,
                    isReadable: BrowserDataImporter.profileLooksValid(folder, source: source)
                )
            }
        case .firefox:
            let profilesDirectory = root.lastPathComponent == "Profiles"
                ? root
                : root.appendingPathComponent("Profiles", isDirectory: true)
            let displayNames = firefoxDisplayNames(
                profilesIniURL: root.appendingPathComponent("profiles.ini")
            )
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: profilesDirectory,
                includingPropertiesForKeys: nil
            )) ?? []
            return entries
                .filter { $0.pathExtension.hasPrefix("default") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { folder in
                    let display = displayNames[folder.lastPathComponent]
                    return BrowserProfileCandidate(
                        source: .firefox,
                        label: display.map { "Firefox — \($0)" } ?? "Firefox — \(folder.lastPathComponent)",
                        folder: folder,
                        isReadable: BrowserDataImporter.profileLooksValid(folder, source: .firefox)
                    )
                }
        case .safari:
            return [BrowserProfileCandidate(
                source: .safari,
                label: "Safari",
                folder: root,
                isReadable: BrowserDataImporter.profileLooksValid(root, source: .safari)
            )]
        }
    }

    /// Chrome, Brave, Edge, Vivaldi, Arc, and Chromium all keep profiles in
    /// `Default` / `Profile N` folders. Display names come from the browser's
    /// `Local State` file so a profile named "Work" is offered as "Chrome —
    /// Work" instead of "Chrome — Profile 2".
    private static func chromiumCandidates() -> [BrowserProfileCandidate] {
        let probed = ["Default"] + (1...20).map { "Profile \($0)" }
        return BrowserImportSource.allCases
            .filter { $0.family == .chromium }
            .flatMap { source -> [BrowserProfileCandidate] in
                guard let root = source.profileRoot else { return [] }
                let displayNames = chromiumDisplayNames(in: root)
                var names = probed
                // When the folder is listable (the user granted access), pick
                // up any profile folder beyond the probed names.
                if let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
                    let extra = entries.filter { entry in
                        guard entry.hasPrefix("Profile ") || entry == "Default" else { return false }
                        return !names.contains(entry)
                    }
                    names.append(contentsOf: extra.sorted())
                }
                return names.compactMap { name in
                    let folder = root.appendingPathComponent(name, isDirectory: true)
                    let exists = BrowserDataImporter.profileLooksValid(folder, source: source)
                    // Only offer the default profile of a browser that is not
                    // installed when nothing else was found for it.
                    guard exists || name == "Default" else { return nil }
                    let display = displayNames[name]
                    let label: String
                    if !exists {
                        label = source.displayName
                    } else if let display, display != name {
                        label = "\(source.displayName) — \(display)"
                    } else {
                        label = name == "Default" ? source.displayName : "\(source.displayName) — \(name)"
                    }
                    return BrowserProfileCandidate(
                        source: source,
                        label: label,
                        folder: folder,
                        isReadable: exists
                    )
                }
            }
    }

    /// Reads `profile.info_cache` from a Chromium `Local State` file, mapping
    /// folder names ("Default", "Profile 1") to user-visible names.
    public static func chromiumDisplayNames(in browserRoot: URL) -> [String: String] {
        chromiumDisplayNames(localStateURL: browserRoot.appendingPathComponent("Local State"))
    }

    public static func chromiumDisplayNames(localStateURL: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: localStateURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infoCache = root["profile"] as? [String: Any],
              let cache = infoCache["info_cache"] as? [String: Any] else {
            return [:]
        }
        var names: [String: String] = [:]
        for (folder, value) in cache {
            if let entry = value as? [String: Any], let name = entry["name"] as? String, !name.isEmpty {
                names[folder] = name
            }
        }
        return names
    }

    private static func firefoxCandidates() -> [BrowserProfileCandidate] {
        let root = BrowserImportSource.firefox.profileRoot
            ?? home().appendingPathComponent("Library/Application Support/Firefox/Profiles", isDirectory: true)
        let displayNames = firefoxDisplayNames()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            // The sandbox blocks listing here until the user grants access, so
            // still offer the standard location as a one-click candidate.
            return [BrowserProfileCandidate(
                source: .firefox,
                label: "Firefox",
                folder: root,
                isReadable: false
            )]
        }
        return entries
            .filter { $0.pathExtension == "default-release" || $0.pathExtension == "default" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { folder in
                let display = displayNames[folder.lastPathComponent]
                return BrowserProfileCandidate(
                    source: .firefox,
                    label: display.map { "Firefox — \($0)" } ?? "Firefox — \(folder.lastPathComponent)",
                    folder: folder,
                    isReadable: BrowserDataImporter.profileLooksValid(folder, source: .firefox)
                )
            }
    }

    /// Reads `profiles.ini` and maps profile directory names to the names the
    /// user gave them in Firefox.
    public static func firefoxDisplayNames() -> [String: String] {
        let root = BrowserImportSource.firefox.profileRoot
            ?? home().appendingPathComponent("Library/Application Support/Firefox", isDirectory: true)
        return firefoxDisplayNames(profilesIniURL: root.appendingPathComponent("profiles.ini"))
    }

    public static func firefoxDisplayNames(profilesIniURL: URL) -> [String: String] {
        guard let contents = try? String(contentsOf: profilesIniURL, encoding: .utf8) else { return [:] }
        var names: [String: String] = [:]
        var currentName: String?
        var currentPath: String?
        func commit() {
            if let currentName, let currentPath {
                names[(currentPath as NSString).lastPathComponent] = currentName
            }
            currentName = nil
            currentPath = nil
        }
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                commit()
            } else if trimmed.hasPrefix("Name=") {
                currentName = String(trimmed.dropFirst("Name=".count))
            } else if trimmed.hasPrefix("Path=") {
                currentPath = String(trimmed.dropFirst("Path=".count))
            }
        }
        commit()
        return names
    }

    private static func safariCandidate() -> BrowserProfileCandidate {
        let folder = BrowserImportSource.safari.profileRoot
            ?? home().appendingPathComponent("Library/Safari", isDirectory: true)
        return BrowserProfileCandidate(
            source: .safari,
            label: "Safari",
            folder: folder,
            isReadable: BrowserDataImporter.profileLooksValid(folder, source: .safari)
        )
    }

    private static func home() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
    }
}

public final class BrowserDataImporter: @unchecked Sendable {
    public enum ImportError: Error, LocalizedError {
        case unsupportedFolder(String)
        case unreadableData(String)
        case credentialsLocked(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFolder(let browser):
                "That folder does not contain \(browser) data. Pick the profile folder itself — for example \(BrowserDataImporter.expectedPathHint(for: browser))."
            case .unreadableData(let message):
                "Browser data could not be read: \(message)"
            case .credentialsLocked(let browser):
                "\(browser) passwords are encrypted with a key in your macOS keychain, and macOS did not allow Browsemium to read it. Everything else was imported."
            }
        }
    }

    /// Tells the user where the profile actually lives, so a wrong pick is
    /// self-correcting instead of a dead end.
    static func expectedPathHint(for browser: String) -> String {
        switch browser {
        case "Chrome":
            "~/Library/Application Support/Google/Chrome/Default"
        case "Firefox":
            "~/Library/Application Support/Firefox/Profiles"
        case "Safari":
            "~/Library/Safari"
        default:
            "the browser's profile folder"
        }
    }

    /// Accepts either the profile itself or a parent folder that contains one,
    /// so choosing `…/Google/Chrome` works as well as `…/Chrome/Default`.
    static func resolveProfileFolder(_ folder: URL, source: BrowserImportSource) -> URL? {
        if profileLooksValid(folder, source: source) {
            return folder
        }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let directories = children.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        switch source.family {
        case .chromium:
            let preferred = ["Default"] + (1...12).map { "Profile \($0)" }
            let ordered = directories.sorted { lhs, rhs in
                let left = preferred.firstIndex(of: lhs.lastPathComponent) ?? Int.max
                let right = preferred.firstIndex(of: rhs.lastPathComponent) ?? Int.max
                return left < right
            }
            return ordered.first { profileLooksValid($0, source: source) }
        case .firefox:
            // A Firefox install keeps its profiles one level deeper.
            if let nested = directories.first(where: { $0.lastPathComponent == "Profiles" }),
               let profile = resolveProfileFolder(nested, source: .firefox) {
                return profile
            }
            return directories
                .filter { profileLooksValid($0, source: .firefox) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .first
        case .safari:
            return directories.first { profileLooksValid($0, source: .safari) }
        }
    }

    public static func profileLooksValid(_ folder: URL, source: BrowserImportSource) -> Bool {
        let contents = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        switch source.family {
        case .chromium:
            return contents.contains("Bookmarks")
                || contents.contains("History")
                || contents.contains("Login Data")
        case .firefox:
            return contents.contains("places.sqlite")
        case .safari:
            return contents.contains("Bookmarks.plist") || contents.contains("History.db")
        }
    }

    private struct ImportedBookmark {
        let url: URL
        let title: String
        let folder: String?
    }

    private struct ImportedVisit {
        let url: URL
        let title: String
        let visitedAt: Date
    }

    private let bookmarks: BookmarkRepository
    private let history: HistoryRepository

    public init(bookmarks: BookmarkRepository, history: HistoryRepository) {
        self.bookmarks = bookmarks
        self.history = history
    }

    /// Reads the profile without writing anything, so the user can see exactly
    /// what would be imported before it happens.
    public func preview(at folder: URL, source: BrowserImportSource) throws -> BrowserImportPreview {
        // Accept a parent folder as well as the profile itself.
        guard let profile = Self.resolveProfileFolder(folder, source: source) else {
            throw ImportError.unsupportedFolder(source.displayName)
        }

        let read: ([ImportedBookmark], [ImportedVisit])
        switch source.family {
        case .chromium:
            read = try readChromium(profile)
        case .firefox:
            read = try readFirefox(profile)
        case .safari:
            read = try readSafari(profile)
        }

        let dedupedBookmarks = Self.dedupeBookmarks(read.0)
        let dedupedVisits = Self.dedupeVisits(read.1)
        let folders = Array(Set(dedupedBookmarks.compactMap(\.folder))).sorted()

        return BrowserImportPreview(
            source: source,
            bookmarks: dedupedBookmarks.map {
                BrowserImportPreview.Bookmark(url: $0.url, title: $0.title, folder: $0.folder)
            },
            visits: dedupedVisits.map {
                BrowserImportPreview.Visit(url: $0.url, title: $0.title, visitedAt: $0.visitedAt)
            },
            folders: folders,
            credentials: credentialSummary(in: profile, source: source),
            searchEngine: searchEngine(in: profile, source: source),
            notImportable: Self.notImportable(for: source)
        )
    }

    /// Counts saved logins without decrypting them.
    private func credentialSummary(
        in profile: URL,
        source: BrowserImportSource
    ) -> [BrowserImportPreview.Credential] {
        guard source.supportsPasswordImport else { return [] }
        let databaseURL = profile.appendingPathComponent("Login Data")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        let rows = (try? readSQLite(databaseURL) { db in
            try ChromeLoginDataReader.summarize(database: db)
        }) ?? []
        return rows.map { BrowserImportPreview.Credential(url: $0.url, username: $0.username) }
    }

    private func searchEngine(in profile: URL, source: BrowserImportSource) -> BrowserImportPreview.SearchEngine? {
        guard source == .chrome else { return nil }
        let preferencesURL = profile.appendingPathComponent("Preferences")
        guard let data = try? Data(contentsOf: preferencesURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providerData = root["default_search_provider_data"] as? [String: Any],
              let templateURL = providerData["template_url_data"] as? [String: Any],
              let searchURL = templateURL["search_url"] as? String else {
            return nil
        }
        let name = (templateURL["short_name"] as? String) ?? (templateURL["keyword"] as? String) ?? "Chrome default"
        // Browsemium stores the query prefix; only a trailing placeholder can be
        // converted without guessing.
        guard searchURL.hasSuffix("{searchTerms}") else { return nil }
        let template = String(searchURL.dropLast("{searchTerms}".count))
        guard let url = URL(string: template + "test"), url.scheme == "https" else { return nil }
        return BrowserImportPreview.SearchEngine(name: name, template: template)
    }

    /// States plainly what each browser encrypts and Browsemium will not move.
    static func notImportable(for source: BrowserImportSource) -> [String] {
        switch source.family {
        case .chromium:
            ["Cookies are encrypted per profile and are not imported."]
        case .firefox:
            [
                "Passwords are stored in Firefox's own encrypted key database and are not imported.",
                "Cookies are encrypted per profile and are not imported."
            ]
        case .safari:
            [
                "Passwords live in your iCloud Keychain and are only readable by Safari.",
                "Cookies are encrypted per profile and are not imported."
            ]
        }
    }

    /// Commits a preview using the user's choices. Re-running is safe: existing
    /// bookmarks and already-recorded history URLs are skipped, and duplicates
    /// inside the batch are dropped before anything is written.
    public func apply(
        _ preview: BrowserImportPreview,
        options: BrowserImportOptions = BrowserImportOptions(),
        keyProvider: BrowserCredentialKeyProviding? = nil,
        profile: URL? = nil
    ) throws -> BrowserImportResult {
        var credentials: [ChromeLogin] = []
        if options.includesPasswords, !preview.credentials.isEmpty {
            guard let key = try keyProvider?.safeStorageKey(for: preview.source) else {
                throw ImportError.credentialsLocked(preview.source.displayName)
            }
            guard let profile else {
                throw ImportError.credentialsLocked(preview.source.displayName)
            }
            let databaseURL = profile.appendingPathComponent("Login Data")
            credentials = try readSQLite(databaseURL) { db in
                try ChromeLoginDataReader.decryptLogins(database: db, key: key)
            }
        }

        var bookmarkCount = 0
        if options.includesBookmarks {
            bookmarkCount = try bookmarks.addMany(
                preview.bookmarks.map { (url: $0.url, title: $0.title, folder: $0.folder) }
            )
        }

        var historyCount = 0
        if options.includesHistory {
            let cutoff = options.historySince
            var candidates = preview.visits
                .filter { cutoff == nil || $0.visitedAt >= cutoff! }
                .sorted { $0.visitedAt > $1.visitedAt }
            if candidates.count > options.historyLimit {
                candidates = Array(candidates.prefix(options.historyLimit))
            }

            // Skip anything already in history so importing twice does not
            // double the timeline.
            let existing = (try? history.existingURLs(among: candidates.map(\.url))) ?? []
            let fresh = candidates.filter { !existing.contains($0.url.absoluteString) }
            historyCount = try history.recordMany(
                fresh.map { (url: $0.url, title: $0.title, visitedAt: $0.visitedAt) }
            )
        }

        return BrowserImportResult(
            bookmarks: bookmarkCount,
            historyVisits: historyCount,
            credentials: credentials,
            searchEngine: options.includesSearchEngine ? preview.searchEngine : nil
        )
    }

    /// Convenience for callers that want the old one-shot behaviour.
    public func importProfile(
        at folder: URL,
        source: BrowserImportSource,
        options: BrowserImportOptions = BrowserImportOptions()
    ) throws -> BrowserImportResult {
        try apply(preview(at: folder, source: source), options: options)
    }

    /// Keeps the newest occurrence of each URL.
    private static func dedupeBookmarks(_ input: [ImportedBookmark]) -> [ImportedBookmark] {
        var seen = Set<String>()
        var output: [ImportedBookmark] = []
        for bookmark in input {
            let key = bookmark.url.absoluteString
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(bookmark)
        }
        return output
    }

    private static func dedupeVisits(_ input: [ImportedVisit]) -> [ImportedVisit] {
        var newest: [String: ImportedVisit] = [:]
        for visit in input {
            let key = visit.url.absoluteString
            if let existing = newest[key], existing.visitedAt >= visit.visitedAt { continue }
            newest[key] = visit
        }
        return newest.values.sorted { $0.visitedAt > $1.visitedAt }
    }

    /// Chrome, Brave, Edge, Vivaldi, Arc, and Chromium share this layout.
    private func readChromium(_ folder: URL) throws -> ([ImportedBookmark], [ImportedVisit]) {
        let bookmarksURL = folder.appendingPathComponent("Bookmarks")
        let historyURL = folder.appendingPathComponent("History")
        guard FileManager.default.fileExists(atPath: bookmarksURL.path) ||
                FileManager.default.fileExists(atPath: historyURL.path) ||
                FileManager.default.fileExists(atPath: folder.appendingPathComponent("Login Data").path) else {
            throw ImportError.unsupportedFolder("Chrome, Brave, Edge, Vivaldi, Arc, or Chromium")
        }

        var importedBookmarks: [ImportedBookmark] = []
        if let data = try? Data(contentsOf: bookmarksURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let roots = root["roots"] as? [String: Any] {
            for (folderName, value) in roots {
                collectChromeBookmarks(value, folder: folderName, into: &importedBookmarks)
            }
        }

        let visits = try readSQLiteIfPresent(historyURL) { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT url, title, last_visit_time
                    FROM urls
                    WHERE url LIKE 'http%'
                    ORDER BY last_visit_time DESC
                    LIMIT 5000
                    """
            ).compactMap { row -> ImportedVisit? in
                guard let rawURL = row["url"] as String?, let url = Self.webURL(rawURL) else { return nil }
                let micros = row["last_visit_time"] as Int64? ?? 0
                let seconds = Double(micros) / 1_000_000 - 11_644_473_600
                return ImportedVisit(
                    url: url,
                    title: row["title"] ?? (url.host ?? rawURL),
                    visitedAt: Date(timeIntervalSince1970: max(seconds, 0))
                )
            }
        }
        return (importedBookmarks, visits)
    }

    private func collectChromeBookmarks(_ value: Any, folder: String?, into output: inout [ImportedBookmark]) {
        guard let node = value as? [String: Any] else { return }
        let currentFolder = (node["name"] as? String).flatMap { $0.isEmpty ? folder : $0 } ?? folder
        if let rawURL = node["url"] as? String, let url = Self.webURL(rawURL) {
            output.append(ImportedBookmark(url: url, title: node["name"] as? String ?? url.host ?? rawURL, folder: folder))
        }
        for child in node["children"] as? [Any] ?? [] {
            collectChromeBookmarks(child, folder: currentFolder, into: &output)
        }
    }

    private func readFirefox(_ folder: URL) throws -> ([ImportedBookmark], [ImportedVisit]) {
        let databaseURL = folder.appendingPathComponent("places.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw ImportError.unsupportedFolder("Firefox")
        }

        return try readSQLite(databaseURL) { db in
            let importedBookmarks = try Row.fetchAll(
                db,
                sql: """
                    SELECT p.url, COALESCE(b.title, p.title, p.url) AS title
                    FROM moz_bookmarks b
                    JOIN moz_places p ON p.id = b.fk
                    WHERE b.type = 1 AND p.url LIKE 'http%'
                    ORDER BY b.dateAdded DESC
                    """
            ).compactMap { row -> ImportedBookmark? in
                guard let rawURL = row["url"] as String?, let url = Self.webURL(rawURL) else { return nil }
                return ImportedBookmark(url: url, title: row["title"] ?? url.host ?? rawURL, folder: "Firefox")
            }

            let visits = try Row.fetchAll(
                db,
                sql: """
                    SELECT url, COALESCE(title, url) AS title, last_visit_date
                    FROM moz_places
                    WHERE url LIKE 'http%' AND last_visit_date IS NOT NULL
                    ORDER BY last_visit_date DESC
                    LIMIT 5000
                    """
            ).compactMap { row -> ImportedVisit? in
                guard let rawURL = row["url"] as String?, let url = Self.webURL(rawURL) else { return nil }
                let micros = row["last_visit_date"] as Int64? ?? 0
                return ImportedVisit(
                    url: url,
                    title: row["title"] ?? url.host ?? rawURL,
                    visitedAt: Date(timeIntervalSince1970: Double(micros) / 1_000_000)
                )
            }
            return (importedBookmarks, visits)
        }
    }

    private func readSafari(_ folder: URL) throws -> ([ImportedBookmark], [ImportedVisit]) {
        let bookmarksURL = folder.appendingPathComponent("Bookmarks.plist")
        let historyURL = folder.appendingPathComponent("History.db")
        guard FileManager.default.fileExists(atPath: bookmarksURL.path) ||
                FileManager.default.fileExists(atPath: historyURL.path) else {
            throw ImportError.unsupportedFolder("Safari")
        }

        var importedBookmarks: [ImportedBookmark] = []
        if let data = try? Data(contentsOf: bookmarksURL),
           let root = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            collectSafariBookmarks(root, folder: "Safari", into: &importedBookmarks)
        }

        let visits = try readSQLiteIfPresent(historyURL) { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT i.url, COALESCE(i.title, i.url) AS title, v.visit_time
                    FROM history_visits v
                    JOIN history_items i ON i.id = v.history_item
                    WHERE i.url LIKE 'http%'
                    ORDER BY v.visit_time DESC
                    LIMIT 5000
                    """
            ).compactMap { row -> ImportedVisit? in
                guard let rawURL = row["url"] as String?, let url = Self.webURL(rawURL) else { return nil }
                let seconds = row["visit_time"] as Double? ?? 0
                return ImportedVisit(
                    url: url,
                    title: row["title"] ?? url.host ?? rawURL,
                    visitedAt: Date(timeIntervalSinceReferenceDate: seconds)
                )
            }
        }
        return (importedBookmarks, visits)
    }

    private func collectSafariBookmarks(_ value: Any, folder: String?, into output: inout [ImportedBookmark]) {
        guard let node = value as? [String: Any] else { return }
        let currentFolder = (node["Title"] as? String).flatMap { $0.isEmpty ? folder : $0 } ?? folder
        if let rawURL = node["URLString"] as? String, let url = Self.webURL(rawURL) {
            let dictionary = node["URIDictionary"] as? [String: Any]
            let title = dictionary?["title"] as? String ?? url.host ?? rawURL
            output.append(ImportedBookmark(url: url, title: title, folder: folder))
        }
        for child in node["Children"] as? [Any] ?? [] {
            collectSafariBookmarks(child, folder: currentFolder, into: &output)
        }
    }

    private func readSQLiteIfPresent<T>(_ url: URL, body: (Database) throws -> T) throws -> T where T: RangeReplaceableCollection {
        guard FileManager.default.fileExists(atPath: url.path) else { return T() }
        return try readSQLite(url, body: body)
    }

    /// Reads a browser's SQLite database from a private copy.
    ///
    /// Chrome and Firefox keep their databases open while they run, and a
    /// read-only open of a live database fails or returns partial data. Copying
    /// the file (plus its WAL and shared-memory sidecars) is the only reliable
    /// way to read it, and it never writes to the source browser.
    private func readSQLite<T>(_ url: URL, body: (Database) throws -> T) throws -> T {
        let workdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("browsemium-import-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workdir) }

        let copy = workdir.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: url.path + suffix)
                if FileManager.default.fileExists(atPath: sidecar.path) {
                    try? FileManager.default.copyItem(
                        at: sidecar,
                        to: URL(fileURLWithPath: copy.path + suffix)
                    )
                }
            }
        } catch {
            throw ImportError.unreadableData(error.localizedDescription)
        }

        do {
            var configuration = Configuration()
            configuration.readonly = true
            let queue = try DatabaseQueue(path: copy.path, configuration: configuration)
            return try queue.read(body)
        } catch {
            throw ImportError.unreadableData(error.localizedDescription)
        }
    }

    private static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }
}
