import Foundation

enum ExtensionUpdateTransaction {
    struct RollbackFailure: Error, LocalizedError {
        let backup: URL

        var errorDescription: String? {
            "The extension update failed and could not be rolled back. The previous version is preserved in recovery folder \(backup.lastPathComponent) in the extension store."
        }
    }

    static func replace(
        staging: URL, destination: URL, backup: URL,
        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) throws {
        let fileManager = FileManager.default
        let hadExisting = fileManager.fileExists(atPath: destination.path)
        if hadExisting { try move(destination, backup) }
        do {
            try move(staging, destination)
        } catch {
            if hadExisting, !fileManager.fileExists(atPath: destination.path) {
                do {
                    try move(backup, destination)
                } catch {
                    throw RollbackFailure(backup: backup)
                }
            }
            throw error
        }
        // Only a committed update makes the old copy disposable.
        if hadExisting { try? fileManager.removeItem(at: backup) }
    }
}
