import Foundation

/// A selected folder authorizes its contents, not paths reached through links.
enum BrowserImportPathPolicy {
    static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let parent = root.resolvingSymlinksInPath().standardizedFileURL.path
        let child = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return parent != "/" && child.hasPrefix(parent + "/")
    }

    static func permitsArtifact(_ candidate: URL, within root: URL) -> Bool {
        let parent = root.path
        let child = candidate.path
        guard parent != "/", child.hasPrefix(parent + "/") else { return false }
        let components = child.dropFirst(parent.count + 1).split(separator: "/")
        guard !components.contains(".."), !components.contains(".") else { return false }
        // Resolve the existing root once, then inspect each relative component.
        // Foundation canonicalizes existing /private aliases differently from
        // missing optional files; comparing those two resolved paths is wrong.
        var cursor = root.resolvingSymlinksInPath().standardizedFileURL
        for component in components {
            cursor.appendPathComponent(String(component))
            if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                return false
            }
        }
        return true
    }

    static func validate(_ profile: URL, source: BrowserImportSource) throws {
        let files: [String]
        let databases: [String]
        switch source.family {
        case .chromium:
            files = ["Bookmarks", "Preferences", "Extensions", "Network"]
            databases = ["History", "Login Data", "Cookies", "Network/Cookies"]
        case .firefox:
            files = ["logins.json", "key4.db", "recovery.jsonlz4"]
            databases = ["places.sqlite", "cookies.sqlite", "formhistory.sqlite"]
        case .safari:
            files = ["Bookmarks.plist", "Cookies.binarycookies"]
            databases = ["History.db"]
        }
        let artifacts = files + databases.flatMap { [$0, $0 + "-wal", $0 + "-shm"] }
        for name in artifacts {
            guard permitsArtifact(profile.appendingPathComponent(name), within: profile) else {
                throw BrowserDataImporter.ImportError.unreadableData("The selected profile contains an unsafe linked data file (\(name)). Copy the profile into a regular folder and try again.")
            }
        }
    }
}
