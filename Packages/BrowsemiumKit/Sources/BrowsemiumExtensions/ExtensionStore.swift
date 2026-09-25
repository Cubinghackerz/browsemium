import Foundation
import Security

/// The on-disk extension store: one directory per extension under
/// `~/Library/Application Support/Browsemium/Extensions` (inside the app
/// container when sandboxed). The store only manages files — enablement is
/// per profile and lives in the profile database.
///
/// Layout, one directory per extension:
///
/// ```
/// Extensions/<id>/unpacked/       an unpacked extension (manifest.json inside)
/// Extensions/<id>/extension.zip   a zip, or a crx with its header stripped
/// Extensions/<id>/<Name>.appex    a signed app extension bundle
/// ```
public final class ExtensionStore: @unchecked Sendable {
    public enum InstallError: Swift.Error, LocalizedError, Equatable {
        case unsupportedSource(String)
        case missingManifest
        case notFound(String)
        case invalidIdentifier(String)
        case symbolicLinkNotAllowed(String)
        case packageTooLarge
        case invalidCodeSignature

        public var errorDescription: String? {
            switch self {
            case .unsupportedSource(let name):
                "“\(name)” is not an extension folder, .zip, .crx, or .appex."
            case .missingManifest:
                "The extension folder has no manifest.json at its root."
            case .notFound(let id):
                "No installed extension with id “\(id)”."
            case .invalidIdentifier(let id):
                "“\(id)” is not a valid extension identifier."
            case .symbolicLinkNotAllowed(let name):
                "“\(name)” contains a symbolic link. Unpacked extensions must contain ordinary files only."
            case .packageTooLarge:
                "The extension package is larger than Chrome's 2 GB limit."
            case .invalidCodeSignature:
                "The app extension does not have a valid code signature."
            }
        }
    }

    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    /// The default store location. Lives beside the profile databases so a
    /// backup or removal of Browsemium's application support takes the
    /// extensions with it.
    public static func defaultRootDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("Browsemium", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)
    }

    // MARK: - Discovery

    /// Every extension directory the store can hand to WebKit.
    public func installed() throws -> [InstalledExtension] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return entries.compactMap { entry in
            guard Self.isValidIdentifier(entry.lastPathComponent) else { return nil }
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            return Self.extension(in: entry)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func extensionDirectory(id: String) throws -> URL {
        guard Self.isValidIdentifier(id) else { throw InstallError.invalidIdentifier(id) }
        let root = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(id, isDirectory: true).standardizedFileURL
        guard candidate.deletingLastPathComponent().path == root.path else {
            throw InstallError.invalidIdentifier(id)
        }
        return candidate
    }

    private static func `extension`(in directory: URL) -> InstalledExtension? {
        let fileManager = FileManager.default
        let id = directory.lastPathComponent
        let installedAt = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

        let unpacked = directory.appendingPathComponent("unpacked", isDirectory: true)
        if fileManager.fileExists(atPath: unpacked.appendingPathComponent("manifest.json").path) {
            let manifest = ExtensionManifest.read(fromDirectory: unpacked)
            return InstalledExtension(
                id: id,
                name: manifest?.name ?? id,
                version: manifest?.version ?? "",
                payload: .directory,
                resourceURL: unpacked,
                permissions: manifest?.permissions ?? [],
                hostPermissions: manifest?.hostPermissions ?? [],
                installedAt: installedAt
            )
        }

        let zip = directory.appendingPathComponent("extension.zip")
        if fileManager.fileExists(atPath: zip.path) {
            return InstalledExtension(
                id: id,
                name: id,
                version: "",
                payload: .zip,
                resourceURL: zip,
                installedAt: installedAt
            )
        }

        if let appex = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "appex" }) {
            return InstalledExtension(
                id: id,
                name: appex.deletingPathExtension().lastPathComponent,
                version: "",
                payload: .appExtension,
                resourceURL: appex,
                installedAt: installedAt
            )
        }

        return nil
    }

    // MARK: - Install / remove

    /// Copies an extension into the store. Accepts an unpacked folder, a
    /// `.zip`, a `.crx` (header stripped), or an `.appex` bundle. Installing
    /// over an existing id replaces it — that is how updates work.
    @discardableResult
    public func install(from sourceURL: URL, identifier preferredIdentifier: String? = nil) throws -> InstalledExtension {
        let fileManager = FileManager.default
        let id = preferredIdentifier ?? Self.identifier(for: sourceURL)
        guard Self.isValidIdentifier(id) else { throw InstallError.invalidIdentifier(id) }
        let destination = try extensionDirectory(id: id)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw InstallError.unsupportedSource(sourceURL.lastPathComponent)
        }

        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let staging = rootDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        let backup = rootDirectory.appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: backup)
        }

        let extensionPayload: InstalledExtension
        switch sourceURL.pathExtension.lowercased() {
        case "appex" where isDirectory.boolValue:
            try Self.validateCodeSignature(at: sourceURL)
            let appexDestination = staging.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
            try fileManager.copyItem(at: sourceURL, to: appexDestination)
            extensionPayload = InstalledExtension(
                id: id,
                name: sourceURL.deletingPathExtension().lastPathComponent,
                version: "",
                payload: .appExtension,
                resourceURL: appexDestination
            )

        case "zip" where !isDirectory.boolValue:
            try Self.validatePackageSize(at: sourceURL)
            let zipDestination = staging.appendingPathComponent("extension.zip")
            try fileManager.copyItem(at: sourceURL, to: zipDestination)
            extensionPayload = InstalledExtension(
                id: id,
                name: sourceURL.deletingPathExtension().lastPathComponent,
                version: "",
                payload: .zip,
                resourceURL: zipDestination
            )

        case "crx" where !isDirectory.boolValue:
            try Self.validatePackageSize(at: sourceURL)
            let zipDestination = staging.appendingPathComponent("extension.zip")
            try CRXContainer.copyZIPPayload(from: sourceURL, to: zipDestination)
            extensionPayload = InstalledExtension(
                id: id,
                name: sourceURL.deletingPathExtension().lastPathComponent,
                version: "",
                payload: .zip,
                resourceURL: zipDestination
            )

        case _ where isDirectory.boolValue:
            // Any remaining directory is treated as an unpacked extension:
            // the manifest check below is what actually decides.
            try Self.rejectSymbolicLinks(in: sourceURL)
            let unpackedDestination = staging.appendingPathComponent("unpacked", isDirectory: true)
            try fileManager.copyItem(at: sourceURL, to: unpackedDestination)
            guard ExtensionManifest.read(fromDirectory: unpackedDestination) != nil else {
                throw InstallError.missingManifest
            }
            let manifest = ExtensionManifest.read(fromDirectory: unpackedDestination)
            extensionPayload = InstalledExtension(
                id: id,
                name: manifest?.name ?? sourceURL.lastPathComponent,
                version: manifest?.version ?? "",
                payload: .directory,
                resourceURL: unpackedDestination,
                permissions: manifest?.permissions ?? [],
                hostPermissions: manifest?.hostPermissions ?? []
            )

        default:
            throw InstallError.unsupportedSource(sourceURL.lastPathComponent)
        }

        let hadExisting = fileManager.fileExists(atPath: destination.path)
        if hadExisting {
            try fileManager.moveItem(at: destination, to: backup)
        }
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            if hadExisting, !fileManager.fileExists(atPath: destination.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
        try? fileManager.removeItem(at: backup)

        let relativeResource = extensionPayload.resourceURL.path.replacingOccurrences(
            of: staging.path,
            with: destination.path,
            options: [.anchored]
        )
        return InstalledExtension(
            id: extensionPayload.id,
            name: extensionPayload.name,
            version: extensionPayload.version,
            payload: extensionPayload.payload,
            resourceURL: URL(fileURLWithPath: relativeResource),
            permissions: extensionPayload.permissions,
            hostPermissions: extensionPayload.hostPermissions,
            installedAt: extensionPayload.installedAt
        )
    }

    /// Updates the display name/version after WebKit has loaded an extension
    /// (zips and appex bundles carry no readable manifest on disk).
    public func updateMetadata(id: String, name: String, version: String) throws -> InstalledExtension {
        guard var record = try installed().first(where: { $0.id == id }) else {
            throw InstallError.notFound(id)
        }
        record = InstalledExtension(
            id: record.id,
            name: name,
            version: version,
            payload: record.payload,
            resourceURL: record.resourceURL,
            permissions: record.permissions,
            hostPermissions: record.hostPermissions,
            installedAt: record.installedAt
        )
        return record
    }

    public func remove(id: String) throws {
        let directory = try extensionDirectory(id: id)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw InstallError.notFound(id)
        }
        try FileManager.default.removeItem(at: directory)
    }

    /// A stable, filesystem-safe id derived from the source name. Reinstalling
    /// the same extension under the same name replaces it.
    public static func identifier(for sourceURL: URL) -> String {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let allowed = base.lowercased().map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let sanitized = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "extension" : sanitized
    }

    public static func isValidIdentifier(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128,
              (id.first?.isLetter == true || id.first?.isNumber == true) else { return false }
        return id.allSatisfy { character in
            character.isASCII && (character.isLowercase || character.isNumber || character == "-" || character == "_")
        }
    }

    private static let maximumPackageBytes: Int = 2 * 1024 * 1024 * 1024

    private static func validatePackageSize(at url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumPackageBytes else { throw InstallError.packageTooLarge }
    }

    private static func rejectSymbolicLinks(in directory: URL) throws {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey]
        if try directory.resourceValues(forKeys: keys).isSymbolicLink == true {
            throw InstallError.symbolicLinkNotAllowed(directory.lastPathComponent)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let item as URL in enumerator {
            if try item.resourceValues(forKeys: keys).isSymbolicLink == true {
                throw InstallError.symbolicLinkNotAllowed(item.lastPathComponent)
            }
        }
    }

    private static func validateCodeSignature(at url: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else {
            throw InstallError.invalidCodeSignature
        }
    }
}
