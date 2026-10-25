import Foundation

/// A rule that sends a site to a space: "github.com opens in Work".
///
/// Matching is exact on the host by default. A rule opts into subdomains
/// explicitly, and subdomain matching only ever happens on a label boundary,
/// so `notgithub.com` and `github.com.example.net` never match `github.com`.
public struct SpaceRoute: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    /// Lowercase ASCII (punycode) host. Never a URL, port, path or wildcard.
    public let host: String
    public let includesSubdomains: Bool
    public let spaceID: SpaceID
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        host: String,
        includesSubdomains: Bool = false,
        spaceID: SpaceID,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.host = host
        self.includesSubdomains = includesSubdomains
        self.spaceID = spaceID
        self.createdAt = createdAt
    }
}

public enum SpaceRouteHostError: Error, Equatable, Sendable {
    case empty
    case containsScheme
    case containsPort
    case containsPath
    case containsCredentials
    case wildcard
    case invalid
    /// Subdomain rules on a single label (`com`) would claim a whole TLD.
    case needsRegistrableDomain

    public var message: String {
        switch self {
        case .empty: "Enter a site, such as github.com."
        case .containsScheme: "Enter only the site name, without https://."
        case .containsPort: "Ports are not part of a routing rule."
        case .containsPath: "Enter only the site name, without a path."
        case .containsCredentials: "A routing rule cannot include a username."
        case .wildcard: "Wildcards are not supported. Turn on “include subdomains” instead."
        case .invalid: "That is not a valid site name."
        case .needsRegistrableDomain: "Include-subdomains needs a full site name like example.com."
        }
    }
}

public enum SpaceRouteHost {
    /// Longest host a rule may carry (DNS limit).
    public static let maximumLength = 253

    /// Normalises user input into the single form rules are stored and
    /// compared in. Everything ambiguous is rejected rather than guessed at.
    public static func normalize(
        _ input: String,
        includesSubdomains: Bool = false
    ) -> Result<String, SpaceRouteHostError> {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .failure(.empty) }
        if value.contains("://") { return .failure(.containsScheme) }
        if value.contains("@") { return .failure(.containsCredentials) }
        if value.contains("*") { return .failure(.wildcard) }
        if value.contains("/") || value.contains("?") || value.contains("#") { return .failure(.containsPath) }
        if value.contains(":") { return .failure(.containsPort) }
        if value.contains(where: { $0.isWhitespace }) { return .failure(.invalid) }
        // One trailing dot is the absolute form of the same name.
        if value.hasSuffix(".") { value.removeLast() }
        guard !value.isEmpty, !value.hasPrefix("."), !value.contains("..") else {
            return .failure(.invalid)
        }
        // `URL` converts Unicode names to their punycode form; URLComponents
        // keeps them as typed, which would let two spellings be two rules.
        guard let encoded = URL(string: "https://\(value)/")?.host?.lowercased(),
              !encoded.isEmpty,
              encoded.utf8.count <= maximumLength,
              encoded.utf8.allSatisfy({ $0 < 0x80 }) else {
            return .failure(.invalid)
        }
        let labels = encoded.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 }) else { return .failure(.invalid) }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard encoded.allSatisfy({ allowed.contains($0) || $0 == "." }),
              labels.allSatisfy({ !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else {
            return .failure(.invalid)
        }
        if includesSubdomains, labels.count < 2 { return .failure(.needsRegistrableDomain) }
        return .success(encoded)
    }

    /// The host a navigation is judged by, or nil for anything that is not an
    /// ordinary HTTP(S) page address.
    public static func routableHost(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }
}

/// Owns precedence: an exact-host rule beats any subdomain rule, a longer
/// subdomain suffix beats a shorter one, and ties go to the older rule so the
/// outcome never depends on dictionary or database ordering.
public enum SpaceRouteMatcher {
    public static func route(for url: URL, in routes: [SpaceRoute]) -> SpaceRoute? {
        guard let host = SpaceRouteHost.routableHost(of: url) else { return nil }
        return route(forHost: host, in: routes)
    }

    public static func route(forHost host: String, in routes: [SpaceRoute]) -> SpaceRoute? {
        let candidates = routes.filter { matches($0, host: host) }
        return candidates.min { lhs, rhs in
            // Every candidate matches by equality or as a label-boundary
            // suffix, so the longest rule host is the most specific: equality
            // always outranks a suffix.
            if lhs.host.count != rhs.host.count { return lhs.host.count > rhs.host.count }
            // For the same host, a rule that names only that host outranks
            // one that also claims its subdomains.
            if lhs.includesSubdomains != rhs.includesSubdomains { return !lhs.includesSubdomains }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func matches(_ route: SpaceRoute, host: String) -> Bool {
        if host == route.host { return true }
        return route.includesSubdomains && host.hasSuffix("." + route.host)
    }
}
