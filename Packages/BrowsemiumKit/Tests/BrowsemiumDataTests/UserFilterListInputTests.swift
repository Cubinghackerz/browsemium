@testable import BrowsemiumData
import Foundation
import Testing

private final class FilterInputFixtures: @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let chunks: [Data]
        var responseURL: URL? = nil
    }
    private let lock = NSLock()
    private var responses: [URL: Response] = [:]
    func put(_ response: Response) -> URL {
        let url = URL(string: "https://filter-fixture.invalid/" + UUID().uuidString)!
        lock.lock(); defer { lock.unlock() }
        responses[url] = response
        return url
    }
    func take(_ url: URL) -> Response? {
        lock.lock(); defer { lock.unlock() }
        return responses.removeValue(forKey: url)
    }
}

private final class FilterInputURLProtocol: URLProtocol, @unchecked Sendable {
    static let fixtures = FilterInputFixtures()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "filter-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = Self.fixtures.take(url),
              let response = HTTPURLResponse(url: fixture.responseURL ?? url, statusCode: fixture.status, httpVersion: nil, headerFields: fixture.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in fixture.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite struct UserFilterListInputTests {
    private func fetcher(limit: Int = 4 * 1024 * 1024) -> HTTPSUserFilterListFetcher {
        HTTPSUserFilterListFetcher(protocolClasses: [FilterInputURLProtocol.self], maximumBytes: limit)
    }

    @Test func localReaderBoundsValidatesEncodingAndRefusesSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("generated.txt")
        let data = Data("\u{feff}||fixture.example^\r\n".utf8)
        try data.write(to: file)
        #expect(try UserFilterListInput.readFile(file) == data)
        let truncatedPath = URL(fileURLWithPath: file.path + "\u{0}not-the-selected-file")
        #expect(throws: UserFilterListInput.InputError.unreadableFile) { try UserFilterListInput.readFile(truncatedPath) }
        #expect(throws: UserFilterListInput.InputError.tooLarge) { try UserFilterListInput.readFile(file, maximumBytes: 4) }
        let link = root.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: UserFilterListInput.InputError.self) { try UserFilterListInput.readFile(link) }
        try Data([0xff, 0xfe]).write(to: file)
        #expect(throws: UserFilterListInput.InputError.invalidEncoding) { try UserFilterListInput.readFile(file) }
    }

    @Test(arguments: ["http://fixture.invalid/list", "file:///tmp/list", "data:text/plain,fixture", "https://user:secret@fixture.invalid/list"])
    func sourcesMustBeHTTPSWithoutEmbeddedCredentials(raw: String) async {
        await #expect(throws: UserFilterListInput.InputError.httpsRequired) { _ = try await fetcher().fetch(URL(string: raw)!) }
    }

    @Test func redirectPolicyRevalidatesSchemeAndDropsAmbientHeaders() throws {
        let target = URL(string: "https://other-fixture.invalid/list")!
        let request = try UserFilterListRequestPolicy.redirect(to: target, count: 1)
        #expect(request.url == target && request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        for raw in ["http://fixture.invalid/list", "file:///tmp/list", "https://user:secret@fixture.invalid/list"] {
            #expect(throws: UserFilterListInput.InputError.redirectRefused) {
                try UserFilterListRequestPolicy.redirect(to: URL(string: raw)!, count: 1)
            }
        }
        #expect(throws: UserFilterListInput.InputError.redirectRefused) {
            try UserFilterListRequestPolicy.redirect(to: target, count: 6)
        }
    }

    @Test func HTTPSReadsAreBoundedAndDoNotUseCredentialCookieOrCacheStores() async throws {
        let configuration = HTTPSUserFilterListFetcher.configuration()
        #expect(configuration.httpCookieStorage == nil && configuration.urlCredentialStorage == nil && configuration.urlCache == nil)
        #expect(!configuration.httpShouldSetCookies && !configuration.waitsForConnectivity)
        let data = Data("||fixture.example^".utf8)
        let url = FilterInputURLProtocol.fixtures.put(.init(status: 200, headers: ["Content-Type": "text/plain; charset=utf-8"], chunks: [data]))
        #expect(try await fetcher().fetch(url) == data)
        let oversized = FilterInputURLProtocol.fixtures.put(.init(status: 200, headers: [:], chunks: [Data("1234".utf8), Data("5678".utf8)]))
        await #expect(throws: UserFilterListInput.InputError.tooLarge) { _ = try await fetcher(limit: 5).fetch(oversized) }
        let declaredOversized = FilterInputURLProtocol.fixtures.put(.init(status: 200, headers: ["Content-Length": "999"], chunks: []))
        await #expect(throws: UserFilterListInput.InputError.tooLarge) { _ = try await fetcher(limit: 5).fetch(declaredOversized) }
    }

    @Test func finalResponseMustStillBeHTTPSWithoutCredentials() async {
        let response = FilterInputURLProtocol.fixtures.put(.init(status: 200, headers: [:],
            chunks: [Data("||fixture.example^".utf8)], responseURL: URL(string: "http://fixture.invalid/list")!))
        await #expect(throws: UserFilterListInput.InputError.redirectRefused) { _ = try await fetcher().fetch(response) }
    }

    @Test func responseFailuresAreSanitizedAndInvalidEncodingIsRejected() async {
        let status = FilterInputURLProtocol.fixtures.put(.init(status: 503, headers: [:], chunks: [Data("private-source-values".utf8)]))
        await #expect(throws: UserFilterListInput.InputError.httpStatus(503)) { _ = try await fetcher().fetch(status) }
        let charset = FilterInputURLProtocol.fixtures.put(.init(status: 200, headers: ["Content-Type": "text/plain; charset=iso-8859-1"], chunks: []))
        await #expect(throws: UserFilterListInput.InputError.invalidEncoding) { _ = try await fetcher().fetch(charset) }
        let invalid = FilterInputURLProtocol.fixtures.put(.init(status: 200, headers: [:], chunks: [Data([0xff])]))
        await #expect(throws: UserFilterListInput.InputError.invalidEncoding) { _ = try await fetcher().fetch(invalid) }
    }

    @Test @MainActor func preCancelledDownloadFailsBeforeAnyDataCanBeReturned() async {
        let url = FilterInputURLProtocol.fixtures.put(.init(status: 200, headers: [:], chunks: [Data("||fixture.example^".utf8)]))
        let pending = Task { try Task.checkCancellation(); return try await fetcher().fetch(url) }
        pending.cancel()
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
    }
}
