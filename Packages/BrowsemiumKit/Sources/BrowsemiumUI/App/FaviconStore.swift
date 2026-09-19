import AppKit
import BrowsemiumCore
import Foundation
import Observation
import WebKit

/// Host-keyed favicon cache. Icons come from the site itself — the page's
/// declared icon link is fetched over the same connection the user already
/// opened, so nothing is sent to a third-party icon service. Anything that
/// fails to fetch or decode falls back to the tab's letter monogram.
@MainActor
@Observable
public final class FaviconStore {
    public private(set) var images: [String: NSImage] = [:]
    private var attempted: Set<String> = []

    public init() {}

    public func image(for url: URL?) -> NSImage? {
        guard let host = url?.host?.lowercased() else { return nil }
        return images[host]
    }

    public func fetchIcon(for webView: WKWebView, pageURL: URL) {
        guard let host = pageURL.host?.lowercased(),
              pageURL.scheme == "https" || pageURL.scheme == "http",
              !attempted.contains(host) else {
            return
        }
        attempted.insert(host)

        let script = """
        (() => {
          const icons = [...document.querySelectorAll(
            'link[rel~="icon"], link[rel="shortcut icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]'
          )].map(link => link.href).filter(Boolean);
          return icons.join("\\n");
        })()
        """

        Task {
            if let raw = try? await webView.evaluateJavaScript(script) as? String, !raw.isEmpty {
                for candidate in raw.split(separator: "\n").map(String.init) {
                    if await store(candidate, relativeTo: pageURL, host: host) {
                        return
                    }
                }
            }
            await fetchFallback(pageURL: pageURL, host: host)
        }
    }

    /// When a page declares no icon, `/favicon.ico` on the same origin is the
    /// conventional location — a request to a host the user already visited.
    private func fetchFallback(pageURL: URL, host: String) async {
        guard var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else { return }
        components.path = "/favicon.ico"
        components.query = nil
        components.fragment = nil
        guard let iconURL = components.url else { return }
        _ = await download(iconURL, host: host)
    }

    private func store(_ href: String, relativeTo pageURL: URL, host: String) async -> Bool {
        if href.hasPrefix("data:") {
            return decodeDataURI(href, host: host)
        }
        guard let iconURL = URL(string: href, relativeTo: pageURL)?.absoluteURL,
              iconURL.scheme == "https" || iconURL.scheme == "http",
              !iconURL.path.lowercased().hasSuffix(".svg") else {
            return false
        }
        return await download(iconURL, host: host)
    }

    private func download(_ iconURL: URL, host: String) async -> Bool {
        var request = URLRequest(url: iconURL)
        request.timeoutInterval = 6
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              data.count <= 1_000_000,
              let image = NSImage(data: data),
              image.size.width > 0 else {
            return false
        }
        store(image, for: host)
        return true
    }

    private func decodeDataURI(_ href: String, host: String) -> Bool {
        guard let comma = href.firstIndex(of: ",") else { return false }
        let metadata = href[..<comma]
        let payload = String(href[href.index(after: comma)...])
        let data: Data?
        if metadata.contains(";base64") {
            data = Data(base64Encoded: payload)
        } else {
            data = payload.removingPercentEncoding?.data(using: .utf8)
        }
        guard let data, data.count <= 1_000_000, let image = NSImage(data: data) else { return false }
        store(image, for: host)
        return true
    }

    private func store(_ image: NSImage, for host: String) {
        if images.count >= 256, let oldestKey = images.keys.first {
            images[oldestKey] = nil
        }
        images[host] = image
    }
}
