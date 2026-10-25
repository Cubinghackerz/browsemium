import Foundation

/// What may leave the browser for Spotlight. Pure, so every rule is a test.
///
/// Only bookmarks: a title, an address and the host. Never history, page text,
/// private windows, locked spaces or separate-data spaces. Eligibility for the
/// last three is decided when the bookmark is saved (`creationEligible`) and
/// is never recomputed, so a bookmark cannot become visible later.
public enum SpotlightPolicy {
    /// One domain for the active profile's items, so turning the feature off,
    /// switching profile or quitting can clear exactly what Browsemium added.
    public static let domainIdentifier = "com.browsemium.bookmarks"
    public static let maxItems = 2_000

    public static func isEligible(url: URL, creationEligible: Bool) -> Bool {
        guard creationEligible,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return false }
        return true
    }
}

/// What may be offered to the person's other devices through Handoff: the
/// active tab's https address, and only from an ordinary window on a space
/// that is not locked (even one the person unlocked this run) and uses the
/// profile's own data. The fragment is dropped;
/// the query stays, because without it many pages would not reopen.
public enum HandoffPolicy {
    public static func shareableURL(
        _ url: URL?,
        isPrivate: Bool,
        isSpaceLocked: Bool,
        hasSeparateData: Bool
    ) -> URL? {
        guard let url, !isPrivate, !isSpaceLocked, !hasSeparateData,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        parts.fragment = nil
        return parts.url
    }

    /// An address arriving by Handoff opens only if it is plain https.
    public static func isAcceptableIncoming(_ url: URL?) -> Bool {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme?.lowercased() == "https" && !(parts.host ?? "").isEmpty
            && parts.user == nil && parts.password == nil
    }
}
