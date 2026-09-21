import AppKit
import BrowsemiumCore
import Foundation
import Observation
import BrowsemiumEngineKit

/// Host-keyed favicon cache. Icons come from the site itself — the page's
/// declared icon link is fetched over the same connection the user already
/// opened, so nothing is sent to a third-party icon service. Anything that
/// fails to fetch or decode falls back to the tab's letter monogram.
@MainActor
@Observable
public final class FaviconStore {
    /// Bounded so a long session with many hosts cannot grow without limit.
    private static let maximumIcons = 256
    private static let maximumTrackedHosts = 512
    /// A site whose icon is not ready on the first try gets one more chance on
    /// a later page load; beyond that the monogram is final for the session.
    private static let maximumAttemptsPerHost = 2

    public private(set) var images: [String: NSImage] = [:]
    /// Insertion order for the icon cache, so eviction drops the oldest host
    /// rather than an arbitrary one.
    private var imageOrder: [String] = []
    /// Attempts per host, so a failed fetch can be retried instead of being
    /// remembered as permanently hopeless.
    private var attempts: [(host: String, count: Int)] = []

    public init() {}

    public func image(for url: URL?) -> NSImage? {
        guard let host = url?.host?.lowercased() else { return nil }
        return images[host]
    }

    /// Asks the page for its declared icons and fetches the first usable one.
    /// The script runs through the engine, so this works the same on WebKit and
    /// on Chromium.
    public func fetchIcon(engine: any BrowserEngine, tabID: TabID, pageURL: URL) {
        guard let host = pageURL.host?.lowercased(),
              pageURL.scheme == "https" || pageURL.scheme == "http",
              canAttempt(host) else {
            return
        }
        recordAttempt(host)

        let script = """
        (() => {
          const icons = [...document.querySelectorAll(
            'link[rel~="icon"], link[rel="shortcut icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]'
          )].map(link => link.href).filter(Boolean);
          return icons.join("\\n");
        })()
        """

        Task {
            if let raw = try? await engine.evaluateJavaScript(tabID: tabID, script: script) as? String,
               !raw.isEmpty {
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

    func store(_ href: String, relativeTo pageURL: URL, host: String) async -> Bool {
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

    func store(_ image: NSImage, for host: String) {
        if images[host] == nil {
            imageOrder.append(host)
        }
        images[host] = image
        while imageOrder.count > Self.maximumIcons {
            let evicted = imageOrder.removeFirst()
            images[evicted] = nil
        }
    }

    func canAttempt(_ host: String) -> Bool {
        (attempts.first { $0.host == host }?.count ?? 0) < Self.maximumAttemptsPerHost
    }

    func recordAttempt(_ host: String) {
        if let index = attempts.firstIndex(where: { $0.host == host }) {
            attempts[index].count += 1
            return
        }
        attempts.append((host, 1))
        if attempts.count > Self.maximumTrackedHosts {
            attempts.removeFirst(attempts.count - Self.maximumTrackedHosts)
        }
    }
}
