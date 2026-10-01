import BrowsemiumCore
import Foundation
import GRDB

public enum BrowserImportSource: String, CaseIterable, Identifiable, Sendable {
    case chrome
    case brave
    case edge
    case vivaldi
    case arc
    case dia
    case helium
    case opera
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
        case .dia: "Dia"
        case .helium: "Helium"
        case .opera: "Opera"
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
        case .chrome, .brave, .edge, .vivaldi, .arc, .dia, .helium, .opera, .chromium: .chromium
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
        case .dia: "Dia Safe Storage"
        case .helium: "Helium Safe Storage"
        case .opera: "Opera Safe Storage"
        case .chromium: "Chromium Safe Storage"
        case .firefox, .safari: nil
        }
    }

    /// Where this browser keeps its profiles, or nil when it does not use one.
    public var profileRoot: URL? {
        profileRoot(relativeTo: BrowserImportHomeDirectory.current)
    }

    /// Pure path construction for source hints and generated fixtures. Unlike
    /// the app's own storage, browser sources use the account home, not the
    /// sandbox process home. This does not inspect or grant access to files.
    public func profileRoot(relativeTo home: URL) -> URL? {
        let base = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        switch self {
        case .chrome: return base.appendingPathComponent("Google/Chrome", isDirectory: true)
        case .brave: return base.appendingPathComponent("BraveSoftware/Brave-Browser", isDirectory: true)
        case .edge: return base.appendingPathComponent("Microsoft Edge", isDirectory: true)
        case .vivaldi: return base.appendingPathComponent("Vivaldi", isDirectory: true)
        case .arc: return base.appendingPathComponent("Arc/User Data", isDirectory: true)
        case .dia: return base.appendingPathComponent("Dia/User Data", isDirectory: true)
        case .helium: return base.appendingPathComponent("net.imput.helium", isDirectory: true)
        case .opera: return base.appendingPathComponent("com.operasoftware.Opera", isDirectory: true)
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
    public let report: BrowserImportReport
    public let bookmarks: Int
    public let historyVisits: Int
    /// Decrypted logins for the caller to store. Empty unless the user asked
    /// for passwords and granted keychain access.
    public let credentials: [ChromeLogin]
    /// Account-bearing cookies, held in memory until WebKit accepts them.
    public let cookies: [BrowserImportCookie]
    /// IDs to offer for reinstall. No extension is installed by this importer.
    public let extensionIDs: [String]
    /// The source browser's default search engine, when it could be converted.
    public let searchEngine: BrowserImportPreview.SearchEngine?

    public init(
        bookmarks: Int,
        historyVisits: Int,
        credentials: [ChromeLogin] = [],
        cookies: [BrowserImportCookie] = [],
        extensionIDs: [String] = [],
        searchEngine: BrowserImportPreview.SearchEngine? = nil,
        report: BrowserImportReport = BrowserImportReport()
    ) {
        self.bookmarks = bookmarks
        self.historyVisits = historyVisits
        self.credentials = credentials
        self.cookies = cookies
        self.extensionIDs = extensionIDs
        self.searchEngine = searchEngine
        self.report = report
    }

    public var isEmpty: Bool {
        bookmarks == 0 && historyVisits == 0 && credentials.isEmpty && cookies.isEmpty && extensionIDs.isEmpty && searchEngine == nil
    }
}

/// What a profile contains, before anything is written to Browsemium.
public struct BrowserImportPreview: Sendable {
    public internal(set) var report = BrowserImportReport()
    public struct Bookmark: Sendable, Hashable {
        let ordinal: Int
        public let url: URL
        public let title: String
        public let folder: String?
    }

    public struct Visit: Sendable, Hashable {
        let ordinal: Int
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
    /// Count only; values are read after explicit consent.
    public let cookieCount: Int
    public let extensionIDs: [String]
    public let searchEngine: SearchEngine?
    /// What this browser keeps encrypted and Browsemium will not touch.
    public let notImportable: [String]

    public var bookmarkCount: Int { bookmarks.count }
    public var historyCount: Int { visits.count }
    public var credentialCount: Int { credentials.count }

    public var earliestVisit: Date? { visits.map(\.visitedAt).min() }
    public var latestVisit: Date? { visits.map(\.visitedAt).max() }

    public var isEmpty: Bool {
        bookmarks.isEmpty && visits.isEmpty && credentials.isEmpty && cookieCount == 0 && extensionIDs.isEmpty && searchEngine == nil
    }
}

extension BrowserImportPreview: Identifiable {
    public var id: String {
        "\(source.rawValue)-\(bookmarkCount)-\(historyCount)-\(credentialCount)-\(cookieCount)"
    }
}

public struct BrowserImportOptions: Sendable {
    public var includesBookmarks: Bool
    public var includesHistory: Bool
    /// Decrypts and stores saved logins. Requires keychain access to the source
    /// browser's key, so this is off unless the user asks for it.
    public var includesPasswords: Bool
    /// Cookies can grant immediate account access; always off by default.
    public var includesCookies: Bool
    public var includesExtensions: Bool
    public var includesSearchEngine: Bool
    /// Only history at or after this date is imported.
    public var historySince: Date?
    public var historyLimit: Int

    public init(
        includesBookmarks: Bool = true,
        includesHistory: Bool = true,
        includesPasswords: Bool = false,
        includesCookies: Bool = false,
        includesExtensions: Bool = false,
        includesSearchEngine: Bool = false,
        historySince: Date? = nil,
        historyLimit: Int = 50_000
    ) {
        self.includesBookmarks = includesBookmarks
        self.includesHistory = includesHistory
        self.includesPasswords = includesPasswords
        self.includesCookies = includesCookies
        self.includesExtensions = includesExtensions
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
    public let email: String?
    public let profileName: String

    public init(source: BrowserImportSource, label: String, folder: URL, isReadable: Bool, email: String? = nil, profileName: String? = nil) {
        self.id = "\(source.rawValue)|\(folder.path)"
        self.source = source
        self.label = label
        self.folder = folder
        self.isReadable = isReadable
        self.email = email
        self.profileName = profileName ?? label.components(separatedBy: " — ").last ?? label
    }
}

public enum BrowserImportSourceDetector {
    /// Works out which browser a folder belongs to.
    ///
    /// The path is checked first because every Chromium-family browser stores
    /// the same file names but encrypts passwords with its own keychain item —
    /// guessing "Chrome" for a Brave profile would make decryption fail. The
    /// file names are the fallback for a folder that was moved elsewhere.
    public static func detect(in folder: URL, homeDirectory: URL? = nil) -> BrowserImportSource? {
        let home = homeDirectory ?? BrowserImportHomeDirectory.current
        let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let chromiumFamily = BrowserImportSource.allCases
            .filter { $0.family == .chromium }
            .sorted { ($0.profileRoot(relativeTo: home)?.path.count ?? 0) > ($1.profileRoot(relativeTo: home)?.path.count ?? 0) }
        for source in chromiumFamily {
            if let root = source.profileRoot(relativeTo: home)?.resolvingSymlinksInPath().standardizedFileURL.path,
               path == root || path.hasPrefix(root + "/") {
                return source
            }
        }
        if let firefoxRoot = BrowserImportSource.firefox.profileRoot(relativeTo: home)?.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL.path,
           path == firefoxRoot || path.hasPrefix(firefoxRoot + "/") {
            return .firefox
        }
        if let safariRoot = BrowserImportSource.safari.profileRoot(relativeTo: home)?.resolvingSymlinksInPath().standardizedFileURL.path,
           path == safariRoot || path.hasPrefix(safariRoot + "/") {
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
        // Chromium profiles share these filenames. A moved folder with no
        // known root cannot safely identify which Safe Storage key to use.
        if contents.contains("Bookmarks") || contents.contains("History") || contents.contains("Preferences") { return nil }
        return nil
    }
}

public enum BrowserProfileLocator {
    public static func candidates() -> [BrowserProfileCandidate] {
        chromiumCandidates() + firefoxCandidates() + (safariCandidate().map { [$0] } ?? [])
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
            let emails = chromiumEmails(in: root)
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            let names = entries
                .filter { name in
                    guard name == "Default" || name.hasPrefix("Profile ") else { return false }
                    guard BrowserImportPathPolicy.isDescendant(root.appendingPathComponent(name), of: root) else { return false }
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
                    isReadable: BrowserDataImporter.profileLooksValid(folder, source: source),
                    email: emails[name],
                    profileName: display ?? name
                )
            }
        case .firefox:
            let profilesDirectory = root.lastPathComponent == "Profiles"
                ? root
                : root.appendingPathComponent("Profiles", isDirectory: true)
            let profilesIniURL = profilesDirectory.deletingLastPathComponent()
                .appendingPathComponent("profiles.ini")
            // A selected Profiles directory does not grant access to the
            // sibling profiles.ini file. Only read names when that file is
            // inside the user-selected root.
            let displayNames = BrowserImportPathPolicy.isDescendant(profilesIniURL, of: root)
                ? firefoxDisplayNames(profilesIniURL: profilesIniURL)
                : [:]
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: profilesDirectory,
                includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []
            return entries
                .filter { BrowserImportPathPolicy.isDescendant($0, of: profilesDirectory) }
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { folder in
                    let display = displayNames[folder.lastPathComponent]
                    return BrowserProfileCandidate(
                        source: .firefox,
                        label: display.map { "Firefox — \($0)" } ?? "Firefox — \(folder.lastPathComponent)",
                        folder: folder,
                        isReadable: BrowserDataImporter.profileLooksValid(folder, source: .firefox),
                        profileName: display ?? folder.lastPathComponent
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

    /// Every Chromium-family browser keeps profiles in `Default` /
    /// `Profile N` folders. Display names come from the browser's
    /// `Local State` file so a profile named "Work" is offered as "Chrome —
    /// Work" instead of "Chrome — Profile 2".
    private static func chromiumCandidates() -> [BrowserProfileCandidate] {
        let probed = ["Default"] + (1...20).map { "Profile \($0)" }
        return BrowserImportSource.allCases
            .filter { $0.family == .chromium }
            .flatMap { source -> [BrowserProfileCandidate] in
                guard let root = source.profileRoot,
                      FileManager.default.fileExists(atPath: root.path) else { return [] }
                let displayNames = chromiumDisplayNames(in: root)
                let emails = chromiumEmails(in: root)
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
                    guard BrowserImportPathPolicy.isDescendant(folder, of: root) else { return nil }
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
                        isReadable: exists,
                        email: emails[name],
                        profileName: display ?? name
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
        guard BrowserImportPathPolicy.permitsArtifact(localStateURL, within: localStateURL.deletingLastPathComponent()) else { return [:] }
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

    /// Account email is only presentation metadata; it is never used to
    /// decide which source profile or destination data store to read.
    public static func chromiumEmails(in browserRoot: URL) -> [String: String] {
        let localStateURL = browserRoot.appendingPathComponent("Local State")
        guard BrowserImportPathPolicy.permitsArtifact(localStateURL, within: browserRoot) else { return [:] }
        guard let data = try? Data(contentsOf: localStateURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (folder, value) in cache {
            guard let entry = value as? [String: Any],
                  let email = entry["user_name"] as? String,
                  email.contains("@"), email.count <= 254 else { continue }
            result[folder] = email
        }
        return result
    }

    private static func firefoxCandidates() -> [BrowserProfileCandidate] {
        let root = BrowserImportSource.firefox.profileRoot
            ?? home().appendingPathComponent("Library/Application Support/Firefox/Profiles", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let displayNames = firefoxDisplayNames()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
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
            .filter { BrowserImportPathPolicy.isDescendant($0, of: root) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
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
        return firefoxDisplayNames(profilesIniURL: root.deletingLastPathComponent().appendingPathComponent("profiles.ini"))
    }

    public static func firefoxDisplayNames(profilesIniURL: URL) -> [String: String] {
        guard BrowserImportPathPolicy.permitsArtifact(profilesIniURL, within: profilesIniURL.deletingLastPathComponent()) else { return [:] }
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

    private static func safariCandidate() -> BrowserProfileCandidate? {
        let folder = BrowserImportSource.safari.profileRoot
            ?? home().appendingPathComponent("Library/Safari", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        return BrowserProfileCandidate(
            source: .safari,
            label: "Safari",
            folder: folder,
            isReadable: BrowserDataImporter.profileLooksValid(folder, source: .safari)
        )
    }

    private static func home() -> URL {
        BrowserImportHomeDirectory.current
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
                "\(browser) passwords and encrypted cookies need permission to read the source key in your macOS keychain. Nothing was imported. Allow access, or turn off password and cookie import and try again."
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
            BrowserImportPathPolicy.isDescendant($0, of: folder)
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
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
        let ordinal: Int
        let url: URL
        let title: String
        let folder: String?
    }

    private struct ImportedVisit {
        let ordinal: Int
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
        try BrowserImportPathPolicy.validate(profile, source: source)

        var recorder = ImportReportRecorder()
        let read: ([ImportedBookmark], [ImportedVisit])
        switch source.family {
        case .chromium:
            read = try readChromium(profile, recorder: &recorder)
        case .firefox:
            read = try readFirefox(profile, recorder: &recorder)
        case .safari:
            read = try readSafari(profile, recorder: &recorder)
        }

        let dedupedBookmarks = Self.dedupeBookmarks(read.0)
        let dedupedVisits = Self.dedupeVisits(read.1)
        let folders = Array(Set(dedupedBookmarks.compactMap(\.folder))).sorted()

        let credentials = credentialSummary(in: profile, source: source, report: &recorder.report)
        let cookies = cookieCount(in: profile, source: source, report: &recorder.report)
        let extensionIDs = Self.extensionIDs(in: profile, source: source)
        let engine = searchEngine(in: profile, source: source)
        for index in 0..<(source.family == .safari ? 0 : cookies) {
            recorder.report.record(.cookie, ordinal: index + 1, outcome: .accepted, reason: .parsed)
        }
        for index in extensionIDs.indices {
            recorder.report.record(.extension, ordinal: index + 1, outcome: .accepted, reason: .parsed)
        }
        if engine != nil {
            recorder.report.record(.searchEngine, ordinal: 1, outcome: .accepted, reason: .parsed)
        }
        return BrowserImportPreview(
            report: recorder.report,
            source: source,
            bookmarks: dedupedBookmarks.map {
                BrowserImportPreview.Bookmark(ordinal: $0.ordinal, url: $0.url, title: $0.title, folder: $0.folder)
            },
            visits: dedupedVisits.map {
                BrowserImportPreview.Visit(ordinal: $0.ordinal, url: $0.url, title: $0.title, visitedAt: $0.visitedAt)
            },
            folders: folders,
            credentials: credentials,
            cookieCount: cookies,
            extensionIDs: extensionIDs,
            searchEngine: engine,
            notImportable: Self.notImportable(for: source)
        )
    }

    /// Counts saved logins without decrypting them.
    private func credentialSummary(
        in profile: URL,
        source: BrowserImportSource,
        report: inout BrowserImportReport
    ) -> [BrowserImportPreview.Credential] {
        guard source.supportsPasswordImport else { return [] }
        let databaseURL = profile.appendingPathComponent("Login Data")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        let rows: [(url: URL, username: String)]
        do {
            rows = try readSQLite(databaseURL) { db in
                try ChromeLoginDataReader.summarize(database: db, report: &report)
            }
        } catch {
            report.record(.password, ordinal: 0, outcome: .failed, reason: .sourceUnreadable)
            return []
        }
        return rows.map { BrowserImportPreview.Credential(url: $0.url, username: $0.username) }
    }

    private func cookieCount(in profile: URL, source: BrowserImportSource, report: inout BrowserImportReport) -> Int {
        let count: Int
        do {
        switch source.family {
        case .chromium:
            guard let url = Self.chromiumCookieURL(in: profile) else { return 0 }
            count = try readSQLite(url) { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cookies WHERE length(value) > 0 OR length(encrypted_value) > 0") ?? 0
            }
        case .firefox:
            let url = profile.appendingPathComponent("cookies.sqlite")
            guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
            count = try readSQLite(url) { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM moz_cookies WHERE length(value) > 0") ?? 0
            }
        case .safari:
            guard let url = Self.safariCookieURL(in: profile) else { return 0 }
            var parsingReport = BrowserImportReport()
            count = SafariBinaryCookieReader.parse(try Data(contentsOf: url), report: &parsingReport).count
            // Preview exposes metadata, never a claim that cookie values were
            // transferred to WebKit.
            report.items += parsingReport.items.map {
                BrowserImportReport.Item(category: .cookie, ordinal: $0.ordinal, stage: .preview,
                                         outcome: $0.outcome, reason: $0.outcome == .accepted ? .parsed : $0.reason)
            }
        }
        } catch {
            report.record(.cookie, ordinal: 0, outcome: .failed, reason: .sourceUnreadable)
            return 0
        }
        if count > 50_000 {
            report.record(.cookie, ordinal: 0, outcome: .unsupported, reason: .limitExceeded)
        }
        return min(count, 50_000)
    }

    private static func extensionIDs(in profile: URL, source: BrowserImportSource) -> [String] {
        guard source.family == .chromium else { return [] }
        let folder = profile.appendingPathComponent("Extensions", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { name in
            name.count == 32 && name.unicodeScalars.allSatisfy { (97...112).contains($0.value) }
        }.sorted()
    }

    private static func chromiumCookieURL(in profile: URL) -> URL? {
        for path in ["Network/Cookies", "Cookies"] {
            let url = profile.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func safariCookieURL(in profile: URL) -> URL? {
        // Do not infer a grant for Safari's other stores from a selected profile.
        let candidate = profile.appendingPathComponent("Cookies.binarycookies")
        guard BrowserImportPathPolicy.permitsArtifact(candidate, within: profile),
              FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    private func searchEngine(in profile: URL, source: BrowserImportSource) -> BrowserImportPreview.SearchEngine? {
        guard source.family == .chromium else { return nil }
        let preferencesURL = profile.appendingPathComponent("Preferences")
        guard let data = try? Data(contentsOf: preferencesURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providerData = root["default_search_provider_data"] as? [String: Any],
              let templateURL = providerData["template_url_data"] as? [String: Any],
              let searchURL = templateURL["search_url"] as? String else {
            return nil
        }
        let name = (templateURL["short_name"] as? String) ?? (templateURL["keyword"] as? String) ?? "Default search"
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
            [
                "Site storage does not move; some accounts may still ask you to sign in again.",
                "Extensions can be offered for reinstall, but are never copied or enabled silently; autofill addresses need manual review."
            ]
        case .firefox:
            [
                "Passwords are stored in Firefox's own encrypted key database and are not imported.",
                "Site storage does not move; some accounts may still ask you to sign in again."
            ]
        case .safari:
            [
                "Apple Passwords cannot be read directly; export a CSV from Passwords to move them.",
                "Only Safari cookies in a readable Cookies.binarycookies file can be offered."
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
        if let profile { try BrowserImportPathPolicy.validate(profile, source: preview.source) }
        var report = preview.report
        var credentials: [ChromeLogin] = []
        var cookies: [BrowserImportCookie] = []
        let needsChromiumKey = preview.source.family == .chromium
            && ((options.includesPasswords && !preview.credentials.isEmpty)
                || (options.includesCookies && preview.cookieCount > 0))
        let key: Data?
        if needsChromiumKey {
            guard let unlocked = try keyProvider?.safeStorageKey(for: preview.source) else {
                throw ImportError.credentialsLocked(preview.source.displayName)
            }
            key = unlocked
        } else {
            key = nil
        }
        if options.includesPasswords, !preview.credentials.isEmpty {
            guard let key, let profile else {
                throw ImportError.credentialsLocked(preview.source.displayName)
            }
            let databaseURL = profile.appendingPathComponent("Login Data")
            credentials = try readSQLite(databaseURL) { db in
                try ChromeLoginDataReader.decryptLogins(database: db, key: key, report: &report)
            }
        }
        if options.includesCookies, preview.cookieCount > 0 {
            guard let profile else { throw ImportError.unreadableData("The source profile is unavailable.") }
            cookies = try readCookies(in: profile, source: preview.source, key: key, report: &report)
        }

        let selections: [(BrowserImportReport.Category, Bool)] = [
            (.password, options.includesPasswords), (.cookie, options.includesCookies),
            (.extension, options.includesExtensions), (.searchEngine, options.includesSearchEngine)
        ]
        for (category, selected) in selections {
            let entries = preview.report.items.filter { $0.category == category && $0.outcome == .accepted }
            for item in entries {
                if !selected {
                    report.record(category, ordinal: item.ordinal, stage: .transfer, outcome: .skipped, reason: .notSelected)
                } else if category == .extension || category == .searchEngine {
                    report.record(category, ordinal: item.ordinal, stage: .transfer, outcome: .accepted, reason: .preparedForTransfer)
                }
            }
        }
        var bookmarkCount = 0
        if options.includesBookmarks {
            let outcomes: [BrowserImportReport.Outcome]
            do {
                outcomes = try bookmarks.importMany(
                    preview.bookmarks.map { (url: $0.url, title: $0.title, folder: $0.folder) })
            } catch {
                outcomes = Array(repeating: .failed, count: preview.bookmarks.count)
            }
            bookmarkCount = outcomes.filter { $0 == .accepted }.count
            for (item, outcome) in zip(preview.bookmarks, outcomes) {
                report.record(.bookmark, ordinal: item.ordinal, stage: .persistence, outcome: outcome,
                              reason: Self.writeReason(outcome))
            }
        } else {
            for item in preview.bookmarks {
                report.record(.bookmark, ordinal: item.ordinal, stage: .persistence, outcome: .skipped, reason: .notSelected)
            }
        }

        var historyCount = 0
        if options.includesHistory {
            let cutoff = options.historySince
            var candidates = preview.visits
                .filter { cutoff == nil || $0.visitedAt >= cutoff! }
                .sorted { $0.visitedAt > $1.visitedAt }
            candidates = Array(candidates.prefix(max(0, options.historyLimit)))
            let selected = Set(candidates.map(\.ordinal))
            for item in preview.visits where !selected.contains(item.ordinal) {
                report.record(.history, ordinal: item.ordinal, stage: .persistence, outcome: .skipped, reason: .outsideSelection)
            }
            let outcomes: [BrowserImportReport.Outcome]
            do {
                outcomes = try history.importMany(
                    candidates.map { (url: $0.url, title: $0.title, visitedAt: $0.visitedAt) })
            } catch {
                outcomes = Array(repeating: .failed, count: candidates.count)
            }
            historyCount = outcomes.filter { $0 == .accepted }.count
            for (item, outcome) in zip(candidates, outcomes) {
                report.record(.history, ordinal: item.ordinal, stage: .persistence, outcome: outcome,
                              reason: Self.writeReason(outcome))
            }
        } else {
            for item in preview.visits {
                report.record(.history, ordinal: item.ordinal, stage: .persistence, outcome: .skipped, reason: .notSelected)
            }
        }

        return BrowserImportResult(
            bookmarks: bookmarkCount,
            historyVisits: historyCount,
            credentials: credentials,
            cookies: cookies,
            extensionIDs: options.includesExtensions ? preview.extensionIDs : [],
            searchEngine: options.includesSearchEngine ? preview.searchEngine : nil,
            report: report
        )
    }

    private static func writeReason(_ outcome: BrowserImportReport.Outcome) -> BrowserImportReport.Reason {
        switch outcome {
        case .accepted: .imported
        case .duplicate: .alreadyPresent
        default: .destinationWriteFailed
        }
    }

    private func readCookies(in profile: URL, source: BrowserImportSource, key: Data?, report: inout BrowserImportReport) throws -> [BrowserImportCookie] {
        switch source.family {
        case .chromium:
            guard let url = Self.chromiumCookieURL(in: profile), let key else { return [] }
            return try readSQLite(url) { db in
                let rows = try Row.fetchAll(db, sql: "SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly FROM cookies WHERE length(value) > 0 OR length(encrypted_value) > 0 ORDER BY rowid LIMIT 50000")
                return rows.enumerated().compactMap { index, row in
                    let plaintext = row["value"] as String? ?? ""
                    let encrypted = row["encrypted_value"] as Data? ?? Data()
                    let value = plaintext.isEmpty ? (try? ChromeCredentialCrypto.decrypt(encrypted, key: key)) : plaintext
                    let rawExpiry = row["expires_utc"] as Int64? ?? 0
                    let expiry = rawExpiry > 0 ? Date(timeIntervalSince1970: Double(rawExpiry) / 1_000_000 - 11_644_473_600) : nil
                    guard let value else {
                        report.record(.cookie, ordinal: index + 1, stage: .transfer, outcome: .failed, reason: .decryptionFailed)
                        return nil
                    }
                    let cookie = BrowserImportCookie(
                        domain: row["host_key"] as String? ?? "",
                        name: row["name"] as String? ?? "",
                        value: value,
                        path: row["path"] as String? ?? "/",
                        expires: expiry,
                        isSecure: (row["is_secure"] as Int? ?? 0) != 0,
                        isHTTPOnly: (row["is_httponly"] as Int? ?? 0) != 0
                    )
                    report.record(.cookie, ordinal: index + 1, stage: .transfer,
                                  outcome: cookie == nil ? .unsupported : .accepted,
                                  reason: cookie == nil ? .invalidItem : .preparedForTransfer)
                    return cookie
                }
            }
        case .firefox:
            let url = profile.appendingPathComponent("cookies.sqlite")
            return try readSQLiteIfPresent(url) { db in
                let rows = try Row.fetchAll(db, sql: "SELECT host, name, value, path, expiry, isSecure, isHttpOnly FROM moz_cookies WHERE length(value) > 0 ORDER BY rowid LIMIT 50000")
                return rows.enumerated().compactMap { index, row in
                    let rawExpiry = row["expiry"] as Int64? ?? 0
                    let cookie = BrowserImportCookie(
                        domain: row["host"] as String? ?? "",
                        name: row["name"] as String? ?? "",
                        value: row["value"] as String? ?? "",
                        path: row["path"] as String? ?? "/",
                        expires: rawExpiry > 0 ? Date(timeIntervalSince1970: TimeInterval(rawExpiry)) : nil,
                        isSecure: (row["isSecure"] as Int? ?? 0) != 0,
                        isHTTPOnly: (row["isHttpOnly"] as Int? ?? 0) != 0
                    )
                    report.record(.cookie, ordinal: index + 1, stage: .transfer,
                                  outcome: cookie == nil ? .unsupported : .accepted,
                                  reason: cookie == nil ? .invalidItem : .preparedForTransfer)
                    return cookie
                }
            }
        case .safari:
            guard let url = Self.safariCookieURL(in: profile) else { return [] }
            return SafariBinaryCookieReader.parse(try Data(contentsOf: url), report: &report)
        }
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

    /// Every Chromium-family browser shares this layout: Chrome, Brave, Edge,
    /// Vivaldi, Arc, Dia, Helium, Opera, and Chromium itself.
    private func readChromium(_ folder: URL, recorder: inout ImportReportRecorder) throws -> ([ImportedBookmark], [ImportedVisit]) {
        let bookmarksURL = folder.appendingPathComponent("Bookmarks")
        let historyURL = folder.appendingPathComponent("History")
        guard FileManager.default.fileExists(atPath: bookmarksURL.path) ||
                FileManager.default.fileExists(atPath: historyURL.path) ||
                FileManager.default.fileExists(atPath: folder.appendingPathComponent("Login Data").path) else {
            throw ImportError.unsupportedFolder("Chrome, Brave, Edge, Vivaldi, Arc, Dia, Helium, Opera, or Chromium")
        }

        var importedBookmarks: [ImportedBookmark] = []
        if let data = try? Data(contentsOf: bookmarksURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let roots = root["roots"] as? [String: Any] {
            for folderName in roots.keys.sorted() {
                if let value = roots[folderName] {
                    collectChromeBookmarks(value, folder: folderName, into: &importedBookmarks, recorder: &recorder)
                }
            }
        } else if FileManager.default.fileExists(atPath: bookmarksURL.path) {
            recorder.unreadable(.bookmark)
        }

        let visits = try readSQLiteIfPresent(historyURL) { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT url, title, last_visit_time
                    FROM urls
                    ORDER BY last_visit_time DESC
                    LIMIT 50000
                    """
            ).compactMap { row -> ImportedVisit? in
                guard let rawURL = row["url"] as String?, let url = Self.webURL(rawURL) else {
                    recorder.rejected(.history)
                    return nil
                }
                let micros = row["last_visit_time"] as Int64? ?? 0
                let seconds = Double(micros) / 1_000_000 - 11_644_473_600
                return ImportedVisit(
                    ordinal: recorder.parsed(.history, key: rawURL),
                    url: url,
                    title: row["title"] ?? (url.host ?? rawURL),
                    visitedAt: Date(timeIntervalSince1970: max(seconds, 0))
                )
            }
        }
        return (importedBookmarks, visits)
    }

    private func collectChromeBookmarks(_ value: Any, folder: String?, into output: inout [ImportedBookmark], recorder: inout ImportReportRecorder, depth: Int = 0) {
        guard depth < 128 else { recorder.rejected(.bookmark, reason: .invalidItem); return }
        guard let node = value as? [String: Any] else { return }
        let currentFolder = (node["name"] as? String).flatMap { $0.isEmpty ? folder : $0 } ?? folder
        if let rawURL = node["url"] as? String, let url = Self.webURL(rawURL) {
            output.append(ImportedBookmark(ordinal: recorder.parsed(.bookmark, key: rawURL), url: url, title: node["name"] as? String ?? url.host ?? rawURL, folder: folder))
        } else if node["url"] != nil || node["type"] as? String == "url" {
            recorder.rejected(.bookmark)
        }
        for child in node["children"] as? [Any] ?? [] {
            collectChromeBookmarks(child, folder: currentFolder, into: &output, recorder: &recorder, depth: depth + 1)
        }
    }

    private func readFirefox(_ folder: URL, recorder: inout ImportReportRecorder) throws -> ([ImportedBookmark], [ImportedVisit]) {
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
                    WHERE b.type = 1
                    ORDER BY b.dateAdded DESC
                    LIMIT 50000
                    """
            ).compactMap { row -> ImportedBookmark? in
                guard let rawURL = row["url"] as String?, let url = Self.webURL(rawURL) else {
                    recorder.rejected(.bookmark)
                    return nil
                }
                return ImportedBookmark(ordinal: recorder.parsed(.bookmark, key: rawURL), url: url, title: row["title"] ?? url.host ?? rawURL, folder: "Firefox")
            }

            let visits = try Row.fetchAll(
                db,
                sql: """
                    SELECT url, COALESCE(title, url) AS title, last_visit_date
                    FROM moz_places
                    WHERE last_visit_date IS NOT NULL
                    ORDER BY last_visit_date DESC
                    LIMIT 5000
                    """
            ).compactMap { row -> ImportedVisit? in
                guard let rawURL = row["url"] as String?, let url = Self.webURL(rawURL) else {
                    recorder.rejected(.history)
                    return nil
                }
                let micros = row["last_visit_date"] as Int64? ?? 0
                return ImportedVisit(
                    ordinal: recorder.parsed(.history, key: rawURL),
                    url: url,
                    title: row["title"] ?? url.host ?? rawURL,
                    visitedAt: Date(timeIntervalSince1970: Double(micros) / 1_000_000)
                )
            }
            return (importedBookmarks, visits)
        }
    }

    private func readSafari(_ folder: URL, recorder: inout ImportReportRecorder) throws -> ([ImportedBookmark], [ImportedVisit]) {
        let bookmarksURL = folder.appendingPathComponent("Bookmarks.plist")
        let historyURL = folder.appendingPathComponent("History.db")
        guard FileManager.default.fileExists(atPath: bookmarksURL.path) ||
                FileManager.default.fileExists(atPath: historyURL.path) else {
            throw ImportError.unsupportedFolder("Safari")
        }

        var importedBookmarks: [ImportedBookmark] = []
        if let data = try? Data(contentsOf: bookmarksURL),
           let root = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            collectSafariBookmarks(root, folder: "Safari", into: &importedBookmarks, recorder: &recorder)
        } else if FileManager.default.fileExists(atPath: bookmarksURL.path) {
            recorder.unreadable(.bookmark)
        }

        let visits = try readSQLiteIfPresent(historyURL) { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT i.url, COALESCE(i.title, i.url) AS title, v.visit_time
                    FROM history_visits v
                    JOIN history_items i ON i.id = v.history_item
                    ORDER BY v.visit_time DESC
                    LIMIT 5000
                    """
            ).compactMap { row -> ImportedVisit? in
                guard let rawURL = row["url"] as String?, let url = Self.webURL(rawURL) else {
                    recorder.rejected(.history)
                    return nil
                }
                let seconds = row["visit_time"] as Double? ?? 0
                return ImportedVisit(
                    ordinal: recorder.parsed(.history, key: rawURL),
                    url: url,
                    title: row["title"] ?? url.host ?? rawURL,
                    visitedAt: Date(timeIntervalSinceReferenceDate: seconds)
                )
            }
        }
        return (importedBookmarks, visits)
    }

    private func collectSafariBookmarks(_ value: Any, folder: String?, into output: inout [ImportedBookmark], recorder: inout ImportReportRecorder, depth: Int = 0) {
        guard depth < 128 else { recorder.rejected(.bookmark, reason: .invalidItem); return }
        guard let node = value as? [String: Any] else { return }
        let currentFolder = (node["Title"] as? String).flatMap { $0.isEmpty ? folder : $0 } ?? folder
        if let rawURL = node["URLString"] as? String, let url = Self.webURL(rawURL) {
            let dictionary = node["URIDictionary"] as? [String: Any]
            let title = dictionary?["title"] as? String ?? url.host ?? rawURL
            output.append(ImportedBookmark(ordinal: recorder.parsed(.bookmark, key: rawURL), url: url, title: title, folder: folder))
        } else if node["URLString"] != nil || node["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf" {
            recorder.rejected(.bookmark)
        }
        for child in node["Children"] as? [Any] ?? [] {
            collectSafariBookmarks(child, folder: currentFolder, into: &output, recorder: &recorder, depth: depth + 1)
        }
    }

    private func readSQLiteIfPresent<T>(_ url: URL, body: (Database) throws -> T) throws -> T where T: RangeReplaceableCollection {
        guard FileManager.default.fileExists(atPath: url.path) else { return T() }
        return try readSQLite(url, body: body)
    }

    /// Reads a browser's SQLite database from a private copy.
    ///
    /// Chrome and Firefox keep their databases open while they run, and a
    /// read-only open of a live database can fail. Copying the file with its
    /// WAL and shared-memory sidecars retains uncheckpointed writes without
    /// writing to the source. It is not an atomic snapshot of a concurrent
    /// writer; a source that changes during copying may require a retry.
    private func readSQLite<T>(_ url: URL, body: (Database) throws -> T) throws -> T {
        let workdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("browsemium-import-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: workdir, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ImportError.unreadableData("A private temporary directory could not be created.")
        }
        defer { try? FileManager.default.removeItem(at: workdir) }

        let copy = workdir.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: url.path + suffix)
                if FileManager.default.fileExists(atPath: sidecar.path) {
                    try FileManager.default.copyItem(
                        at: sidecar,
                        to: URL(fileURLWithPath: copy.path + suffix)
                    )
                }
            }
        } catch {
            throw ImportError.unreadableData("The source database could not be copied. Close the source browser and retry.")
        }

        do {
            var configuration = Configuration()
            configuration.readonly = true
            let queue = try DatabaseQueue(path: copy.path, configuration: configuration)
            return try queue.read(body)
        } catch {
            throw ImportError.unreadableData("The source database could not be read. Close the source browser and retry.")
        }
    }

    private static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }
}
