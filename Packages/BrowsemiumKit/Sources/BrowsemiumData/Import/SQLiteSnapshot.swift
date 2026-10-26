import Foundation

/// A private copy of a browser's SQLite database that was verified not to have
/// changed while it was being copied.
///
/// Chrome and Firefox keep their databases open while they run. Copying the
/// file with its write-ahead log keeps writes that were not yet checkpointed,
/// but the copy is only trustworthy if neither file moved underneath it. Each
/// attempt records size and modification time of the database and its log,
/// copies, and records them again; a difference means a writer was active and
/// the copy is thrown away. After the last attempt the import reports the
/// problem instead of reading a torn copy.
enum SQLiteSnapshot {
    static let defaultAttempts = 3

    private struct Fingerprint: Equatable {
        let size: Int64
        let modified: Date?
    }

    /// `afterCopy` runs after each copy and before it is verified; tests use it
    /// to simulate a concurrent writer.
    static func copy(
        _ url: URL,
        into directory: URL,
        attempts: Int = defaultAttempts,
        afterCopy: (Int) -> Void = { _ in }
    ) throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw BrowserDataImporter.ImportError.unreadableData("The source database could not be found.")
        }
        let copy = directory.appendingPathComponent(url.lastPathComponent)
        let sources = [url, URL(fileURLWithPath: url.path + "-wal")]
        for attempt in 1...max(attempts, 1) {
            let before = sources.map(fingerprint)
            try? fileManager.removeItem(at: copy)
            try? fileManager.removeItem(at: URL(fileURLWithPath: copy.path + "-wal"))
            try? fileManager.removeItem(at: URL(fileURLWithPath: copy.path + "-shm"))
            do {
                try fileManager.copyItem(at: url, to: copy)
                for suffix in ["-wal", "-shm"] {
                    let sidecar = URL(fileURLWithPath: url.path + suffix)
                    if fileManager.fileExists(atPath: sidecar.path) {
                        try fileManager.copyItem(at: sidecar, to: URL(fileURLWithPath: copy.path + suffix))
                    }
                }
            } catch {
                throw BrowserDataImporter.ImportError.unreadableData(
                    "The source database could not be copied. Quit the source browser and retry."
                )
            }
            afterCopy(attempt)
            if sources.map(fingerprint) == before { return copy }
        }
        throw BrowserDataImporter.ImportError.unreadableData(
            "The source browser changed its data while it was being copied. Quit the source browser and retry; nothing was imported."
        )
    }

    /// `attributesOfItem` reads the file system every time; `URL.resourceValues`
    /// caches per URL object and would report a stale size for a moving file.
    private static func fingerprint(_ url: URL) -> Fingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return Fingerprint(size: size.int64Value, modified: attributes[.modificationDate] as? Date)
    }
}
