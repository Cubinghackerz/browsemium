import BrowsemiumCore
import BrowsemiumEngineKit
import Foundation
import Testing
@testable import BrowsemiumEngine

@MainActor
private final class Finished {
    var url: URL?
}

@MainActor
private func loadFixture(
    _ path: String,
    level: ProtectionLevel,
    server: FixtureServer
) async throws -> URL? {
    let runtime = TabRuntime(
        tabID: TabID(), isPrivate: true, factory: WebViewFactory(),
        captureService: ContentCaptureService(), downloadCoordinator: DownloadCoordinator()
    )
    runtime.applyProtection(level)
    let finished = Finished()
    runtime.onEvent = { event in
        if case .finished(_, let url) = event { finished.url = url }
    }
    runtime.load(URL(string: server.base + path)!)
    _ = try await waitFor { finished.url != nil }
    return finished.url
}

@Test @MainActor
func balancedProtectionRemovesTrackingParametersBeforeTheRequest() async throws {
    let server = try await FixtureServer.start()
    server.page("/landing", "<html><body>ok</body></html>")

    let url = try await loadFixture("/landing?utm_source=mail&keep=1&fbclid=abc", level: .standard, server: server)

    #expect(url?.query == "keep=1")
    #expect(server.seen.allSatisfy { !$0.path.contains("utm_source") && !$0.path.contains("fbclid") })
}

@Test @MainActor
func offProtectionLeavesTheLinkExactlyAsWritten() async throws {
    let server = try await FixtureServer.start()
    server.page("/landing", "<html><body>ok</body></html>")

    let url = try await loadFixture("/landing?utm_source=mail&keep=1", level: .off, server: server)

    #expect(url?.query == "utm_source=mail&keep=1")
}

@Test @MainActor
func signInRequestsAreNeverRewritten() async throws {
    let server = try await FixtureServer.start()
    server.page("/authorize", "<html><body>login</body></html>")
    let query = "client_id=abc&redirect_uri=https%3A%2F%2Fapp.example%2Fcb&utm_source=x"

    let url = try await loadFixture("/authorize?\(query)", level: .strict, server: server)

    #expect(url?.query == query)
}
