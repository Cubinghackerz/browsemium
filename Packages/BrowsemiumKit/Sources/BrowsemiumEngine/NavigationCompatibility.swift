import Foundation

/// Narrow compatibility rewrites for sites that otherwise retain stale,
/// account-independent browser state. These never override an explicit site
/// choice made by the user.
public enum NavigationCompatibility {
    public static func chromeWebStoreURL(
        from url: URL,
        preferredLanguages: [String]
    ) -> URL? {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "chromewebstore.google.com",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              !(components.queryItems ?? []).contains(where: { $0.name.lowercased() == "hl" }) else {
            return nil
        }

        let language = normalizedLanguage(preferredLanguages.first) ?? "en-US"
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "hl", value: language))
        components.queryItems = items
        guard let rewritten = components.url, rewritten != url else { return nil }
        return rewritten
    }

    private static func normalizedLanguage(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let identifier = Locale(identifier: raw).identifier.replacingOccurrences(of: "_", with: "-")
        return identifier.isEmpty ? nil : identifier
    }
}
