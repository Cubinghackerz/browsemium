import Foundation

/// Per-extension, per-host page-access policy.
///
/// Stored in the profile database (`extension_site_policies`); enforced by
/// applying the choice to WebKit's `WKWebExtensionContext` permission state.
/// Pure and UI-testable: no WebKit import.
///
/// Semantics, verified by the SDK spike (see Plans/2.4-extension-site-controls.md):
/// - `deny` blocks content-script injection. Already-injected page code keeps
///   running until the page reloads or navigates; the denial takes effect on
///   the next load. Denial wins over broader `<all_urls>` grants and over
///   activeTab user gestures.
/// - `allow` grants the host without prompting.
/// - `ask` (and the absence of a row) leaves WebKit's default: the extension
///   prompts the first time it wants the host.
public enum ExtensionSiteAccessMode: String, Codable, Sendable, CaseIterable {
    case allow
    case ask
    case deny

    public var title: String {
        switch self {
        case .allow: "Allow"
        case .ask: "Ask"
        case .deny: "Deny"
        }
    }
}

/// One stored choice: this extension may (`allow`), must ask for (`ask`), or
/// may never (`deny`) access pages on this host.
public struct ExtensionSitePolicy: Hashable, Codable, Sendable, Identifiable {
    public var id: String { "\(extensionID)\0\(host)" }
    public let extensionID: String
    /// Lower-cased exact HTTP(S) host, no port, no scheme, no path.
    public let host: String
    public let mode: ExtensionSiteAccessMode

    public init(extensionID: String, host: String, mode: ExtensionSiteAccessMode) {
        self.extensionID = extensionID
        self.host = Self.normalizeHost(host) ?? host.lowercased()
        self.mode = mode
    }

    /// Normalizes a host or URL string to a bare lower-cased host.
    /// Returns nil for values that are not usable as a site key (empty,
    /// non-HTTP(S) URLs, hosts with paths are reduced to the host part).
    public static func normalizeHost(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"),
           let host = url.host?.lowercased(), !host.isEmpty {
            return host
        }
        // Bare host without dots is still a host (e.g. localhost, intranet).
        // Reject anything with spaces, slashes, or scheme-like leftovers.
        guard !trimmed.contains(" "), !trimmed.contains("/"), !trimmed.contains(":") else { return nil }
        return trimmed
    }

    /// The match patterns WebKit is given for this host. Both schemes:
    /// a page served over either one must follow the same stored choice.
    public var matchPatternStrings: [String] {
        ["https://\(host)/*", "http://\(host)/*"]
    }
}
