import Foundation

/// Removes well-known advertising and campaign identifiers from a link
/// before the page is requested. It is a fixed allowlist, never a pattern:
/// a parameter that is not named here is left exactly as it was, because
/// guessing wrong breaks a page and guessing right is not worth that.
///
/// Out of scope by design: any URL that looks like part of a sign-in flow
/// (the OAuth/SAML parameter names below) is returned untouched, so a
/// redirect target or state value is never altered.
public enum TrackingParameterStripper {
    public static let exactNames: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "mc_eid", "mc_cid",
        "igshid", "yclid", "twclid", "ttclid", "li_fat_id", "_hsenc", "_hsmi", "mkt_tok",
        "vero_id", "oly_enc_id", "oly_anon_id", "wickedid", "rb_clickid", "irclickid",
        "_ga", "_gl"
    ]

    public static let prefixes: [String] = ["utm_"]

    /// Names that mark a URL as an authentication request. Their presence
    /// switches stripping off for that URL.
    public static let authenticationMarkers: Set<String> = [
        "redirect_uri", "client_id", "response_type", "code_challenge", "id_token",
        "samlrequest", "samlresponse", "relaystate", "saml_request", "wa", "wresult"
    ]

    /// The URL without tracking parameters, or nil when there is nothing to
    /// remove (or the URL must not be touched).
    public static func stripped(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = components.percentEncodedQuery, !query.isEmpty else { return nil }

        let items = query.split(separator: "&", omittingEmptySubsequences: false).map(String.init)
        let names = items.map(Self.name(of:))
        if names.contains(where: { authenticationMarkers.contains($0) }) { return nil }

        var kept: [String] = []
        var removedAny = false
        for (item, name) in zip(items, names) {
            if isTracking(name) {
                removedAny = true
            } else {
                kept.append(item)
            }
        }
        guard removedAny else { return nil }

        components.percentEncodedQuery = kept.isEmpty ? nil : kept.joined(separator: "&")
        return components.url
    }

    private static func isTracking(_ name: String) -> Bool {
        if exactNames.contains(name) { return true }
        return prefixes.contains { name.hasPrefix($0) }
    }

    /// The decoded, lowercased parameter name of one `name=value` item.
    private static func name(of item: String) -> String {
        let raw = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? item
        return (raw.removingPercentEncoding ?? raw).lowercased()
    }
}
