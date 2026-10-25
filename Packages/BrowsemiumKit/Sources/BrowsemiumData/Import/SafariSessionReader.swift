import Foundation

/// Reads open tabs out of Safari's `LastSession.plist`.
///
/// Only the documented subset is read: the root dictionary's `SessionWindows`
/// array, each window's `Tabs` array, and each tab's `URLString`/`Title`.
/// Unknown keys are ignored. Window, tab, and string sizes are bounded, and
/// only http(s) URLs are kept. A missing file means "no session", not a
/// failure; anything else wrong fails before any write.
public enum SafariSessionReader {
    public static let maxWindows = 100
    public static let maxTabs = 2_000
    public static let maxStringLength = 8_192

    public struct SessionTab: Sendable, Hashable {
        public let url: URL
        public let title: String
    }

    public enum ReadError: Error, LocalizedError {
        case missing
        case corrupt(String)

        public var errorDescription: String? {
            switch self {
            case .missing:
                "No Safari session was found."
            case .corrupt(let detail):
                "The Safari session could not be read: \(detail)"
            }
        }
    }

    public static func sessionURL(in profile: URL) -> URL {
        profile.appendingPathComponent("LastSession.plist")
    }

    public static func readTabs(in profile: URL) throws -> [SessionTab] {
        let url = sessionURL(in: profile)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ReadError.missing }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ReadError.corrupt("the file could not be opened")
        }
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw ReadError.corrupt("it is not a property list")
        }
        guard let root = plist as? [String: Any],
              let windows = root["SessionWindows"] as? [Any] else {
            throw ReadError.corrupt("it has no session windows")
        }
        var tabs: [SessionTab] = []
        for window in windows.prefix(maxWindows) {
            guard let entries = (window as? [String: Any])?["Tabs"] as? [Any] else { continue }
            for tab in entries {
                if tabs.count >= maxTabs { break }
                guard let tabDict = tab as? [String: Any],
                      let rawURL = tabDict["URLString"] as? String,
                      rawURL.count <= maxStringLength,
                      let url = webURL(rawURL) else { continue }
                let title = (tabDict["Title"] as? String)
                    .flatMap { $0.isEmpty || $0.count > maxStringLength ? nil : $0 }
                    ?? url.host ?? rawURL
                tabs.append(SessionTab(url: url, title: title))
            }
        }
        return tabs
    }

    private static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              url.scheme == "https" || url.scheme == "http",
              url.host?.isEmpty == false else { return nil }
        return url
    }
}
