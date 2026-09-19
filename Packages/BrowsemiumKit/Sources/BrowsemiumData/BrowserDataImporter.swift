import BrowsemiumCore
import Foundation
import GRDB

public enum BrowserImportSource: String, CaseIterable, Identifiable, Sendable {
    case chrome
    case firefox
    case safari

    public var id: String { rawValue }

    public var displayName: String {
        rawValue.capitalized
    }
}

public struct BrowserImportResult: Sendable {
    public let bookmarks: Int
    public let historyVisits: Int

    public init(bookmarks: Int, historyVisits: Int) {
        self.bookmarks = bookmarks
        self.historyVisits = historyVisits
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

    public let source: BrowserImportSource
    public let bookmarks: [Bookmark]
    public let visits: [Visit]
    public let folders: [String]

    public var bookmarkCount: Int { bookmarks.count }
    public var historyCount: Int { visits.count }

    public var earliestVisit: Date? { visits.map(\.visitedAt).min() }
    public var latestVisit: Date? { visits.map(\.visitedAt).max() }

    public var isEmpty: Bool { bookmarks.isEmpty && visits.isEmpty }
}

extension BrowserImportPreview: Identifiable {
    public var id: String {
        "\(source.rawValue)-\(bookmarkCount)-\(historyCount)"
    }
}

public struct BrowserImportOptions: Sendable {
    public var includesBookmarks: Bool
    public var includesHistory: Bool
    /// Only history at or after this date is imported.
    public var historySince: Date?
    public var historyLimit: Int

    public init(
        includesBookmarks: Bool = true,
        includesHistory: Bool = true,
        historySince: Date? = nil,
        historyLimit: Int = 5_000
    ) {
        self.includesBookmarks = includesBookmarks
        self.includesHistory = includesHistory
        self.historySince = historySince
        self.historyLimit = historyLimit
    }
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
    /// Works out which browser a folder belongs to from the files it holds, so
    /// a manually chosen folder can never be parsed with the wrong reader.
    public static func detect(in folder: URL) -> BrowserImportSource? {
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
        chromeCandidates() + firefoxCandidates() + [safariCandidate()]
    }

    private static func chromeCandidates() -> [BrowserProfileCandidate] {
        let root = home()
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        var profiles: [BrowserProfileCandidate] = []
        let names = ["Default"] + (1...8).map { "Profile \($0)" }
        for name in names {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            let exists = FileManager.default.fileExists(atPath: folder.appendingPathComponent("Bookmarks").path)
                || FileManager.default.fileExists(atPath: folder.appendingPathComponent("History").path)
            guard exists || name == "Default" else { continue }
            profiles.append(BrowserProfileCandidate(
                source: .chrome,
                label: name == "Default" ? "Chrome" : "Chrome — \(name)",
                folder: folder,
                isReadable: exists
            ))
        }
        return profiles
    }

    private static func firefoxCandidates() -> [BrowserProfileCandidate] {
        let root = home().appendingPathComponent("Library/Application Support/Firefox/Profiles", isDirectory: true)
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
                BrowserProfileCandidate(
                    source: .firefox,
                    label: "Firefox — \(folder.lastPathComponent)",
                    folder: folder,
                    isReadable: FileManager.default.fileExists(atPath: folder.appendingPathComponent("places.sqlite").path)
                )
            }
    }

    private static func safariCandidate() -> BrowserProfileCandidate {
        let folder = home().appendingPathComponent("Library/Safari", isDirectory: true)
        let readable = FileManager.default.fileExists(atPath: folder.appendingPathComponent("Bookmarks.plist").path)
            || FileManager.default.fileExists(atPath: folder.appendingPathComponent("History.db").path)
        return BrowserProfileCandidate(
            source: .safari,
            label: "Safari",
            folder: folder,
            isReadable: readable
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

        public var errorDescription: String? {
            switch self {
            case .unsupportedFolder(let browser):
                "The selected folder does not look like a \(browser) profile."
            case .unreadableData(let message):
                "Browser data could not be read: \(message)"
            }
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
        let read: ([ImportedBookmark], [ImportedVisit])
        switch source {
        case .chrome:
            read = try readChrome(folder)
        case .firefox:
            read = try readFirefox(folder)
        case .safari:
            read = try readSafari(folder)
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
            folders: folders
        )
    }

    /// Commits a preview using the user's choices. Re-running is safe: existing
    /// bookmarks and already-recorded history URLs are skipped, and duplicates
    /// inside the batch are dropped before anything is written.
    public func apply(
        _ preview: BrowserImportPreview,
        options: BrowserImportOptions = BrowserImportOptions()
    ) throws -> BrowserImportResult {
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

        return BrowserImportResult(bookmarks: bookmarkCount, historyVisits: historyCount)
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

    private func readChrome(_ folder: URL) throws -> ([ImportedBookmark], [ImportedVisit]) {
        let bookmarksURL = folder.appendingPathComponent("Bookmarks")
        let historyURL = folder.appendingPathComponent("History")
        guard FileManager.default.fileExists(atPath: bookmarksURL.path) ||
                FileManager.default.fileExists(atPath: historyURL.path) else {
            throw ImportError.unsupportedFolder("Chrome")
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
