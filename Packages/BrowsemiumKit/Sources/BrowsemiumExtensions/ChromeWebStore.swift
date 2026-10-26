import Foundation

/// A reference to a listing on the Chrome Web Store: just the extension id.
///
/// Chrome Web Store ids are 32 lowercase letters in the range `a`–`p`
/// (Chrome's base-16 alphabet, not hex). Accepts a bare id or a detail URL in
/// either the current or legacy shape:
///
/// ```
/// chromewebstore.google.com/detail/<slug>/<id>
/// chrome.google.com/webstore/detail/<slug>/<id>
/// ```
public struct ChromeWebStoreReference: Sendable, Hashable {
    public let extensionID: String

    public enum ParseError: Swift.Error, LocalizedError {
        case notAReference

        public var errorDescription: String? {
            "That is not a Chrome Web Store link or extension id."
        }
    }

    public init(extensionID: String) throws {
        guard Self.isValidID(extensionID) else { throw ParseError.notAReference }
        self.extensionID = extensionID
    }

    /// Parses a bare id or a store URL. Scheme is optional in the input;
    /// anything that is not a recognizable store reference throws.
    public static func parse(_ input: String) throws -> ChromeWebStoreReference {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isValidID(trimmed) {
            return try ChromeWebStoreReference(extensionID: trimmed)
        }
        let urlString = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            ? trimmed
            : "https://\(trimmed)"
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased(),
              Self.storeHosts.contains(host) else {
            throw ParseError.notAReference
        }
        // The id is always the final path component; the slug between
        // "detail" and it is ignored.
        guard let id = url.pathComponents.last?.lowercased(),
              isValidID(id) else {
            throw ParseError.notAReference
        }
        return try ChromeWebStoreReference(extensionID: id)
    }

    public static func isStoreHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return storeHosts.contains(host)
    }

    /// The extension id anywhere in the path, not only as the final component.
    /// Store listings put the id last, but localized or rewritten URLs sometimes
    /// do not.
    public static func reference(in url: URL) -> ChromeWebStoreReference? {
        guard isStoreHost(url) else { return nil }
        for part in url.pathComponents.reversed() {
            if let reference = try? ChromeWebStoreReference(extensionID: part.lowercased()) {
                return reference
            }
        }
        return nil
    }

    private static let storeHosts: Set<String> = [
        "chromewebstore.google.com",
        "chrome.google.com"
    ]

    static func isValidID(_ candidate: String) -> Bool {
        candidate.count == 32 && candidate.allSatisfy { ("a"..."p").contains($0) }
    }
}

/// Downloads Chrome Web Store packages through Google's public update
/// endpoint — the same `clients2` service Chromium browsers use for
/// extension installs and update checks. The request carries only the
/// extension id and a Chrome version hint; no browsing data is sent.
public protocol ChromeWebStoreDownloading: Sendable {
    /// Fetches the extension's package to a local file — `.crx` when the
    /// service returns a CRX container, `.zip` when it returns a bare
    /// archive. Callers pass the file to `ExtensionStore.install(from:)`.
    func downloadPackage(for extensionID: String) async throws -> URL

    /// Same, asking the service for a package compatible with the given Chrome
    /// version (the version of the browser the extension came from). Nil or a
    /// malformed version means "use the built-in fallback".
    func downloadPackage(for extensionID: String, chromeVersion: String?) async throws -> URL
}

public extension ChromeWebStoreDownloading {
    func downloadPackage(for extensionID: String, chromeVersion: String?) async throws -> URL {
        try await downloadPackage(for: extensionID)
    }
}

public struct ChromeWebStoreDownloader: ChromeWebStoreDownloading {
    public enum DownloadError: Swift.Error, LocalizedError {
        case unavailable
        case notAPackage
        case unsafeRedirect
        case packageTooLarge

        public var errorDescription: String? {
            switch self {
            case .unavailable:
                "The Chrome Web Store did not provide that extension. Check the link or id and try again."
            case .notAPackage:
                "The Chrome Web Store answered, but not with an extension package."
            case .unsafeRedirect:
                "The extension download was redirected outside Google's approved update service."
            case .packageTooLarge:
                "The extension package exceeds Chrome's 2 GB limit."
            }
        }
    }

    /// Injectable for tests; production uses `URLSession.shared.download`.
    private let fetch: @Sendable (URL) async throws -> (URL, URLResponse)

    public init(fetch: (@Sendable (URL) async throws -> (URL, URLResponse))? = nil) {
        self.fetch = fetch ?? { url in try await URLSession.shared.download(from: url) }
    }

    /// The update2 endpoint request for one extension. `prodversion` is a
    /// Chrome version hint the service needs to pick a compatible package;
    /// `x` is `id=<id>&uc`, the "user-initiated install" marker.
    public static func updateURL(for extensionID: String) -> URL {
        updateURL(for: extensionID, chromeVersion: nil)
    }

    /// Used when the source browser's version is unknown. It is an old release,
    /// so a package that needs a newer Chrome can come back unavailable.
    public static let fallbackChromeVersion = "131.0.6778.86"

    /// A Chrome version is two to four dot-separated numbers. Anything else is
    /// dropped rather than placed in a request.
    public static func normalizedChromeVersion(_ candidate: String?) -> String? {
        guard let candidate,
              candidate.range(of: #"^[0-9]{1,4}(\.[0-9]{1,6}){1,3}$"#, options: .regularExpression) != nil
        else { return nil }
        return candidate
    }

    public static func updateURL(for extensionID: String, chromeVersion: String?) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "clients2.google.com"
        components.path = "/service/update2/crx"
        components.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: normalizedChromeVersion(chromeVersion) ?? fallbackChromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(extensionID)&uc")
        ]
        // The URL is constructed from fixed parts and a validated id, so
        // component assembly cannot fail.
        return components.url!
    }

    public func downloadPackage(for extensionID: String) async throws -> URL {
        try await downloadPackage(for: extensionID, chromeVersion: nil)
    }

    public func downloadPackage(for extensionID: String, chromeVersion: String?) async throws -> URL {
        _ = try ChromeWebStoreReference(extensionID: extensionID)
        let (tempURL, response) = try await fetch(Self.updateURL(for: extensionID, chromeVersion: chromeVersion))
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw DownloadError.unavailable
        }
        guard let finalURL = response.url,
              finalURL.scheme?.lowercased() == "https",
              let host = finalURL.host?.lowercased(),
              Self.allowedDownloadHosts.contains(host) else {
            throw DownloadError.unsafeRedirect
        }
        let size = try tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maximumPackageBytes else { throw DownloadError.packageTooLarge }
        guard (try? CRXContainer.zipPayloadOffset(inFileAt: tempURL)) != nil else {
            throw DownloadError.notAPackage
        }
        try CRXVerifier.verify(fileAt: tempURL, expectedExtensionID: extensionID)
        let named = FileManager.default.temporaryDirectory
            .appendingPathComponent("browsemium-\(extensionID)-\(UUID().uuidString)")
            .appendingPathExtension("crx")
        try FileManager.default.copyItem(at: tempURL, to: named)
        return named
    }

    private static let maximumPackageBytes = 2 * 1024 * 1024 * 1024
    private static let allowedDownloadHosts: Set<String> = [
        "clients2.google.com",
        "clients2.googleusercontent.com",
        "redirector.gvt1.com"
    ]
}
