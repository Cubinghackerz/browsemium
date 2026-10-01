import BrowsemiumData
import Foundation
import BrowsemiumEngineKit

/// Remembers a browser-profile folder the user granted once, so later imports
/// are a single click instead of another folder picker. The app is sandboxed,
/// so this security-scoped bookmark is the only way to keep that access.
enum ImportAccessStore {
    private static let defaultsKey = "browsemium.importAccessBookmarks"

    static func save(folder: URL, for candidateID: String, defaults: UserDefaults = .standard) {
        guard let data = try? folder.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return
        }
        var stored = storedBookmarks(defaults: defaults)
        stored[candidateID] = data
        defaults.set(stored, forKey: defaultsKey)
    }

    /// Resolves the remembered folder without opening it. The caller is
    /// responsible for balancing `startAccessingSecurityScopedResource()` —
    /// doing it here as well leaked one grant per import.
    static func resolveURL(candidateID: String, defaults: UserDefaults = .standard) -> URL? {
        guard let data = storedBookmarks(defaults: defaults)[candidateID] else { return nil }
        return resolveFolder(data)
    }

    /// Returns only the locations the user previously selected. Callers must
    /// still open each security scope before inspecting browser files.
    static func resolvedFolders(defaults: UserDefaults = .standard) -> [(candidateID: String, folder: URL)] {
        storedBookmarks(defaults: defaults).compactMap { candidateID, data in
            guard let folder = resolveFolder(data) else { return nil }
            return (candidateID: candidateID, folder: folder)
        }
    }

    private static func resolveFolder(_ data: Data) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        guard !isStale else { return nil }
        return url
    }

    /// Finds a remembered grant that covers `folder` — a browser root the user
    /// allowed earlier, whose profiles are therefore importable without
    /// another prompt. The caller balances the access scope on the result.
    static func resolveAncestor(of folder: URL, defaults: UserDefaults = .standard) -> URL? {
        let target = folder.standardizedFileURL.path
        for data in storedBookmarks(defaults: defaults).values {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), !isStale else {
                continue
            }
            let root = url.standardizedFileURL.path
            if target == root || target.hasPrefix(root + "/") {
                return url
            }
        }
        return nil
    }

    private static func storedBookmarks(defaults: UserDefaults) -> [String: Data] {
        defaults.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }
}
