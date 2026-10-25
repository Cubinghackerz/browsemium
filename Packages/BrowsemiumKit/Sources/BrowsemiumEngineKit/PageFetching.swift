import BrowsemiumCore
import Foundation

public struct FetchedPage: Sendable {
    public let finalURL: URL
    public let html: String
    public init(finalURL: URL, html: String) {
        self.finalURL = finalURL
        self.html = html
    }
}

public enum PageFetchError: Error, Equatable, Sendable {
    case notHTTPS
    case badStatus(Int)
    case notText
    case tooLarge
    case network
}

public protocol PageFetching: Sendable {
    func fetch(_ url: URL) async throws -> FetchedPage
}

/// Fetches a page the way a signed-out stranger would: no cookies, no
/// credentials, no cache, https only, bounded in size and time. Because it
/// never carries the browser's logins, a watch on a page behind a sign-in
/// sees the sign-in page, and says so instead of guessing.
public struct EphemeralPageFetcher: PageFetching {
    private let allowsLoopbackHTTP: Bool

    /// `allowsLoopbackHTTP` exists for tests that serve a fixture on
    /// 127.0.0.1; the app never sets it.
    public init(allowsLoopbackHTTP: Bool = false) {
        self.allowsLoopbackHTTP = allowsLoopbackHTTP
    }

    public func fetch(_ url: URL) async throws -> FetchedPage {
        let isLoopback = url.host == "127.0.0.1" || url.host == "localhost"
        guard url.scheme?.lowercased() == "https" || (allowsLoopbackHTTP && isLoopback && url.scheme?.lowercased() == "http") else {
            throw PageFetchError.notHTTPS
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.setValue("text/html,text/plain;q=0.9", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw PageFetchError.network }
            guard (200..<300).contains(http.statusCode) else { throw PageFetchError.badStatus(http.statusCode) }
            let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            guard type.isEmpty || type.contains("text/html") || type.contains("text/plain") || type.contains("xml") else {
                throw PageFetchError.notText
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > PageWatchLimits.maximumBodyBytes { throw PageFetchError.tooLarge }
            }
            let html = String(decoding: data, as: UTF8.self)
            return FetchedPage(finalURL: http.url ?? url, html: html)
        } catch let error as PageFetchError {
            throw error
        } catch {
            throw PageFetchError.network
        }
    }
}

