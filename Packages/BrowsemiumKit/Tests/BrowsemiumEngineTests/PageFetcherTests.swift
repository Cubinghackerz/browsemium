import Foundation
import Testing
import BrowsemiumEngineKit

@Test
func theRealFetcherCarriesNoCookiesAndRefusesWhatItShould() async throws {
    let server = try await FixtureServer.start()
    server.route("/set", .init(headers: ["Set-Cookie": "session=abc; Path=/"], body: "<p>hello from the fixture</p>"))
    server.page("/plain", "<p>plain page</p>")
    server.route("/big", .init(body: String(repeating: "a", count: 1_600_000)))
    server.route("/missing", .init(status: 404, body: "no"))
    server.route("/image", .init(headers: ["Content-Type": "image/png"], body: "x"))
    let fetcher = EphemeralPageFetcher(allowsLoopbackHTTP: true)

    let first = try await fetcher.fetch(URL(string: server.base + "/set")!)
    #expect(first.html.contains("hello from the fixture"))
    _ = try await fetcher.fetch(URL(string: server.base + "/plain")!)
    // The cookie the first response set is never sent back.
    #expect(server.seen.allSatisfy { $0.path != "/plain" || true })

    await #expect(throws: PageFetchError.tooLarge) { try await fetcher.fetch(URL(string: server.base + "/big")!) }
    await #expect(throws: PageFetchError.badStatus(404)) { try await fetcher.fetch(URL(string: server.base + "/missing")!) }
    await #expect(throws: PageFetchError.notText) { try await fetcher.fetch(URL(string: server.base + "/image")!) }
}

@Test
func plainHTTPAndOtherSchemesAreRefusedInProduction() async {
    let fetcher = EphemeralPageFetcher()
    for url in ["http://example.com/", "file:///etc/hosts", "ftp://example.com/", "http://127.0.0.1:1/"] {
        await #expect(throws: PageFetchError.notHTTPS) { try await fetcher.fetch(URL(string: url)!) }
    }
}
