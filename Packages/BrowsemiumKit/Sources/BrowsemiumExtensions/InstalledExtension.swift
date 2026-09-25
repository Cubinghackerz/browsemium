import Foundation

/// One installed extension, as it exists on disk. Enablement and load errors
/// live in the per-profile registry, not here.
public struct InstalledExtension: Identifiable, Hashable, Sendable {
    public enum Payload: String, Sendable, Hashable {
        /// An unpacked directory with manifest.json at its root.
        case directory
        /// A ZIP archive (or a CRX whose header was stripped on install).
        case zip
        /// A signed .appex bundle.
        case appExtension
    }

    public let id: String
    public let name: String
    public let version: String
    public let payload: Payload
    /// What WebKit is handed: a directory, a zip, or an appex bundle.
    public let resourceURL: URL
    /// Manifest permissions, when they could be read at install time.
    public let permissions: [String]
    public let hostPermissions: [String]
    public let installedAt: Date

    public init(
        id: String,
        name: String,
        version: String,
        payload: Payload,
        resourceURL: URL,
        permissions: [String] = [],
        hostPermissions: [String] = [],
        installedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.payload = payload
        self.resourceURL = resourceURL
        self.permissions = permissions
        self.hostPermissions = hostPermissions
        self.installedAt = installedAt
    }
}

/// The parts of a WebExtension manifest Browsemium shows before WebKit
/// loads the extension. Parsing is deliberately forgiving: an unreadable
/// manifest is not an install failure — WebKit reports the real error.
public struct ExtensionManifest: Sendable {
    public let name: String?
    public let version: String?
    public let manifestVersion: Int?
    public let permissions: [String]
    public let hostPermissions: [String]
    public let optionsPage: String?

    public init(
        name: String?,
        version: String?,
        manifestVersion: Int?,
        permissions: [String],
        hostPermissions: [String],
        optionsPage: String?
    ) {
        self.name = name
        self.version = version
        self.manifestVersion = manifestVersion
        self.permissions = permissions
        self.hostPermissions = hostPermissions
        self.optionsPage = optionsPage
    }

    /// Reads `manifest.json` from an unpacked extension directory. Returns
    /// nil when there is no readable manifest there.
    public static func read(fromDirectory directory: URL) -> ExtensionManifest? {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // MV2 declares host permissions inside `permissions`; MV3 splits
        // them into `host_permissions`. The split is done by shape, not by
        // manifest version, so a sloppy manifest still displays correctly.
        let rawPermissions = object["permissions"] as? [String] ?? []
        let rawHostPermissions = object["host_permissions"] as? [String] ?? []
        let isMatchPattern: (String) -> Bool = { value in
            value.contains("://") || value.contains("*")
        }

        var permissions = rawPermissions
        var hostPermissions = rawHostPermissions
        if rawHostPermissions.isEmpty {
            hostPermissions = rawPermissions.filter(isMatchPattern)
            permissions = rawPermissions.filter { !isMatchPattern($0) }
        }

        var optionsPage = object["options_page"] as? String
        if optionsPage == nil,
           let optionsUI = object["options_ui"] as? [String: Any] {
            optionsPage = optionsUI["page"] as? String
        }

        return ExtensionManifest(
            name: (object["name"] as? String).map { resolvePlaceholders($0, in: directory) },
            version: object["version"] as? String,
            manifestVersion: object["manifest_version"] as? Int,
            permissions: permissions,
            hostPermissions: hostPermissions,
            optionsPage: optionsPage
        )
    }

    /// Chrome-style `__MSG_key__` placeholders, resolved from
    /// `_locales/en/messages.json` when present. Unresolvable placeholders
    /// keep their raw form rather than inventing a name.
    private static func resolvePlaceholders(_ value: String, in directory: URL) -> String {
        guard value.contains("__MSG_") else { return value }
        let messagesURL = directory.appendingPathComponent("_locales/en/messages.json")
        guard let data = try? Data(contentsOf: messagesURL),
              let messages = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return value
        }
        var resolved = value
        for (key, entry) in messages {
            guard let message = entry["message"] as? String else { continue }
            resolved = resolved.replacingOccurrences(of: "__MSG_\(key)__", with: message)
        }
        return resolved
    }
}

/// CRX containers are a short header followed by a plain ZIP. WebKit only
/// understands the ZIP, so installs strip the header.
public enum CRXContainer {
    public enum Error: Swift.Error, Equatable {
        case notACRX
        case truncated
        case unsupportedVersion(UInt32)
    }

    /// The byte offset where the embedded ZIP starts.
    public static func zipPayloadOffset(in data: Data) throws -> Int {
        // "Cr24" + version, the smallest possible container header.
        guard data.count >= 8 else { throw Error.truncated }
        guard data[0] == 0x43, data[1] == 0x72, data[2] == 0x32, data[3] == 0x34 else {
            throw Error.notACRX
        }
        let version = data.readLittleEndianUInt32(at: 4)
        switch version {
        case 3:
            guard data.count >= 12 else { throw Error.truncated }
            let headerLength = Int(data.readLittleEndianUInt32(at: 8))
            let offset = 12 + headerLength
            guard offset < data.count else { throw Error.truncated }
            return offset
        case 2:
            guard data.count >= 16 else { throw Error.truncated }
            let publicKeyLength = Int(data.readLittleEndianUInt32(at: 8))
            let signatureLength = Int(data.readLittleEndianUInt32(at: 12))
            let offset = 16 + publicKeyLength + signatureLength
            guard offset < data.count else { throw Error.truncated }
            return offset
        default:
            throw Error.unsupportedVersion(version)
        }
    }

    /// The ZIP payload of a CRX file. The signature is not verified — WebKit
    /// does not require one for locally installed extensions, and claiming
    /// verification we do not perform would be dishonest.
    public static func zipPayload(from data: Data) throws -> Data {
        let offset = try zipPayloadOffset(in: data)
        return data.subdata(in: offset..<data.count)
    }

    /// Copies only the embedded ZIP without loading a potentially multi-GB
    /// package into memory.
    public static func copyZIPPayload(from source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let offset = try zipPayloadOffset(inFileAt: source)
        try input.seek(toOffset: UInt64(offset))
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
    }

    public static func zipPayloadOffset(inFileAt source: URL) throws -> Int {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let prefix = try input.read(upToCount: 16) ?? Data()
        return try zipPayloadOffset(inPrefix: prefix, fileSize: input.seekToEnd())
    }

    private static func zipPayloadOffset(inPrefix data: Data, fileSize: UInt64) throws -> Int {
        guard data.count >= 8 else { throw Error.truncated }
        guard data[0] == 0x43, data[1] == 0x72, data[2] == 0x32, data[3] == 0x34 else {
            throw Error.notACRX
        }
        let version = data.readLittleEndianUInt32(at: 4)
        let offset: Int
        switch version {
        case 3:
            guard data.count >= 12 else { throw Error.truncated }
            offset = 12 + Int(data.readLittleEndianUInt32(at: 8))
        case 2:
            guard data.count >= 16 else { throw Error.truncated }
            offset = 16 + Int(data.readLittleEndianUInt32(at: 8)) + Int(data.readLittleEndianUInt32(at: 12))
        default:
            throw Error.unsupportedVersion(version)
        }
        guard offset < fileSize else { throw Error.truncated }
        return offset
    }
}

private extension Data {
    func readLittleEndianUInt32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return UInt32(self[start])
            | (UInt32(self[start + 1]) << 8)
            | (UInt32(self[start + 2]) << 16)
            | (UInt32(self[start + 3]) << 24)
    }
}
