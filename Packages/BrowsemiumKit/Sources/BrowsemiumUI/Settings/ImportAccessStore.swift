import BrowsemiumData
import Foundation

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

    /// Returns a URL that is already open for access, or nil when there is no
    /// usable grant. Callers must call `stopAccessingSecurityScopedResource`.
    static func resolve(candidateID: String) -> URL? {
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
        guard url.startAccessingSecurityScopedResource() else { return nil }
        return url
    }

    private static func storedBookmarks() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }
}
