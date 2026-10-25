import Compression
import Foundation

/// Reads open tabs out of a Firefox profile's session backup.
///
/// Format (the layout `SessionStoreUtils` writes): 8-byte magic `mozLz40\0`,
/// the uncompressed size as little-endian UInt32, then one raw LZ4 block.
/// Decoded with the system Compression framework; the declared size is capped
/// before anything is allocated, so a corrupt length cannot balloon memory.
/// The JSON holds `windows[].tabs[]` with `entries[{url,title}]`, a 1-based
/// `index` into the selected entry, and `pinned`. Only http(s) URLs are kept:
/// recovery files never contain private windows, and anything else (about:,
/// file:, data:) is not a page Browsemium would reopen.
public enum FirefoxSessionReader {
    public static let maxCompressedBytes = 64 * 1024 * 1024
    public static let maxDecompressedBytes = 64 * 1024 * 1024
    public static let maxWindows = 100
    public static let maxTabs = 2_000
    public static let maxEntriesPerTab = 50

    public struct SessionTab: Sendable, Hashable {
        public let url: URL
        public let title: String
        public let isPinned: Bool
    }

    public enum ReadError: Error, LocalizedError {
        case missing
        case tooLarge
        case corrupt(String)

        public var errorDescription: String? {
            switch self {
            case .missing:
                "No Firefox session backup was found."
            case .tooLarge:
                "The Firefox session backup exceeds the reader limit."
            case .corrupt(let detail):
                "The Firefox session backup could not be read: \(detail)"
            }
        }
    }

    /// Session backups live in `sessionstore-backups/` inside the profile.
    /// `recovery.jsonlz4` is the crash-recovery file; `sessionstore.jsonlz4`
    /// is the live one. Both share the format.
    public static func backupURL(in profile: URL) -> URL? {
        let directory = profile.appendingPathComponent("sessionstore-backups", isDirectory: true)
        for name in ["recovery.jsonlz4", "sessionstore.jsonlz4"] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    public static func readTabs(in profile: URL) throws -> [SessionTab] {
        guard let url = backupURL(in: profile) else { throw ReadError.missing }
        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? Int) ?? 0
            guard size <= maxCompressedBytes else { throw ReadError.tooLarge }
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch let error as ReadError {
            throw error
        } catch {
            throw ReadError.corrupt("the file could not be opened")
        }
        let json = try decompress(data)
        return try parse(json)
    }

    static func decompress(_ data: Data) throws -> Data {
        let magic = Data("mozLz40\0".utf8)
        guard data.count >= 12, data.prefix(8) == magic else {
            throw ReadError.corrupt("it is not a mozLz40 file")
        }
        let size = Int(data[8]) | (Int(data[9]) << 8) | (Int(data[10]) << 16) | (Int(data[11]) << 24)
        guard size > 0, size <= maxDecompressedBytes else { throw ReadError.tooLarge }
        let payload = data.dropFirst(12)
        guard !payload.isEmpty, payload.count <= maxCompressedBytes else {
            throw ReadError.corrupt("the compressed block is empty or oversized")
        }
        var output = Data(count: size)
        let decoded = output.withUnsafeMutableBytes { outputBuffer -> Int in
            payload.withUnsafeBytes { inputBuffer -> Int in
                compression_decode_buffer(
                    outputBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    size,
                    inputBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    payload.count,
                    nil,
                    COMPRESSION_LZ4
                )
            }
        }
        guard decoded == size else {
            throw ReadError.corrupt("LZ4 decompression failed")
        }
        return output
    }

    private static func parse(_ json: Data) throws -> [SessionTab] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: json, options: [])
        } catch {
            throw ReadError.corrupt("it is not valid JSON")
        }
        guard let top = root as? [String: Any],
              let windows = top["windows"] as? [Any] else {
            throw ReadError.corrupt("it has no session windows")
        }
        var tabs: [SessionTab] = []
        for window in windows.prefix(maxWindows) {
            guard let entries = (window as? [String: Any])?["tabs"] as? [Any] else { continue }
            for tab in entries {
                if tabs.count >= maxTabs { break }
                guard let tabDict = tab as? [String: Any],
                      let allEntries = tabDict["entries"] as? [Any],
                      !allEntries.isEmpty else { continue }
                let index = (tabDict["index"] as? Int ?? allEntries.count) - 1
                let bounded = allEntries.prefix(maxEntriesPerTab)
                guard index >= 0, index < bounded.count,
                      let selected = bounded[bounded.startIndex.advanced(by: index)] as? [String: Any],
                      let rawURL = selected["url"] as? String,
                      let url = webURL(rawURL) else { continue }
                let title = (selected["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? url.host ?? rawURL
                tabs.append(SessionTab(
                    url: url,
                    title: title,
                    isPinned: tabDict["pinned"] as? Bool ?? false
                ))
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
