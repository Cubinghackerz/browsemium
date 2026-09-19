import Foundation

public enum OriginNormalizer {
    public static func normalize(_ url: URL?) -> String? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        var origin = "\(scheme)://\(host)"
        if let port = url.port {
            origin += ":\(port)"
        }
        return origin
    }

    public static func normalize(_ value: String) -> String? {
        guard let url = URL(string: value) else { return nil }
        return normalize(url)
    }
}
