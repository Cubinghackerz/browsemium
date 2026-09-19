import Foundation

public struct DownloadDestinationPolicy: Sendable {
    public enum PolicyError: Error, LocalizedError {
        case invalidFilename
        case destinationUnavailable

        public var errorDescription: String? {
            switch self {
            case .invalidFilename: "The download filename is not usable."
            case .destinationUnavailable: "No writable downloads location is available."
            }
        }
    }

    private let directoryOverride: URL?

    public init(directoryOverride: URL? = nil) {
        self.directoryOverride = directoryOverride
    }

    public func sanitizedFilename(_ suggested: String) -> String? {
        let trimmed = suggested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}")
        let scalars = trimmed.unicodeScalars.map { scalar -> Character in
            if forbidden.contains(scalar) || scalar.properties.generalCategory == .control {
                return "_"
            }
            return Character(scalar)
        }
        var name = String(scalars).trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        name = String(name.prefix(180))
        guard !name.isEmpty else { return nil }
        return name
    }

    public func destination(forSuggestedFilename suggested: String) throws -> URL {
        guard let filename = sanitizedFilename(suggested) else {
            throw PolicyError.invalidFilename
        }
        guard let directory = try baseDirectory() else {
            throw PolicyError.destinationUnavailable
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var candidate = directory.appendingPathComponent(filename)
        var counter = 1
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            let nextName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(nextName)
            counter += 1
        }
        return candidate
    }

    private func baseDirectory() throws -> URL? {
        if let directoryOverride {
            return directoryOverride
        }
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            return downloads
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
}
