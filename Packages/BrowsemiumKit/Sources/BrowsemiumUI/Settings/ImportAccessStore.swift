import BrowsemiumData
import Foundation
import BrowsemiumEngineKit

/// Remembers a browser-profile folder the user granted once, so later imports
/// are a single click instead of another folder picker. The app is sandboxed,
/// so this security-scoped bookmark is the only way to keep that access.
enum ImportAccessStore {
    private static let defaultsKey = "browsemium.importAccessBookmarks"

    static func save(folder: URL, for candidateID: String) {
        guard let data = try? folder.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return
        }
        var stored = storedBookmarks()
        stored[candidateID] = data
        UserDefaults.standard.set(stored, forKey: defaultsKey)
    }

    /// Resolves the remembered folder without opening it. The caller is
    /// responsible for balancing `startAccessingSecurityScopedResource()` —
    /// doing it here as well leaked one grant per import.
    static func resolveURL(candidateID: String) -> URL? {
        guard let data = storedBookmarks()[candidateID] else { return nil }
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
    static func resolveAncestor(of folder: URL) -> URL? {
        let target = folder.standardizedFileURL.path
        for data in storedBookmarks().values {
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

    private static func storedBookmarks() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }
}
