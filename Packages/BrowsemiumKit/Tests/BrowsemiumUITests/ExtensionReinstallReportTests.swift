import BrowsemiumCore
import BrowsemiumData
import BrowsemiumExtensions
@testable import BrowsemiumUI
import Foundation
import Testing

private struct RecordingWebStore: ChromeWebStoreDownloading {
    final class Calls: @unchecked Sendable {
        var versions: [String?] = []
    }
    let calls = Calls()
    let packages: [String: URL]

    func downloadPackage(for extensionID: String) async throws -> URL {
        try await downloadPackage(for: extensionID, chromeVersion: nil)
    }

    func downloadPackage(for extensionID: String, chromeVersion: String?) async throws -> URL {
        calls.versions.append(chromeVersion)
        guard let package = packages[extensionID] else { throw ChromeWebStoreDownloader.DownloadError.unavailable }
        return package
    }
}

private func extensionFolder(named name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-reinstall-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"{"manifest_version":3,"name":"\#(name)","version":"1.0"}"#.utf8)
        .write(to: directory.appendingPathComponent("manifest.json"))
    return directory
}

@Suite @MainActor
struct ExtensionReinstallReportTests {
    private let installable = String(repeating: "a", count: 32)
    private let unavailable = String(repeating: "b", count: 32)

    private func makeModel(store: RecordingWebStore) throws -> BrowserWindowModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("browsemium-reinstall-store-\(UUID().uuidString)", isDirectory: true)
        let environment = BrowserEnvironment.inMemory(engine: StubEngine(), extensionStore: ExtensionStore(rootDirectory: root))
        environment.chromeWebStore = store
        return BrowserWindowModel(environment: environment)
    }

    @Test
    func everyExtensionGetsItsOwnOutcomeWithAReasonWhenItFails() async throws {
        let store = RecordingWebStore(packages: [installable: try extensionFolder(named: "Kept Extension")])
        let model = try makeModel(store: store)

        let results = await model.reinstallImportedExtensions([installable, unavailable], chromeVersion: "145.0.7632.46")

        #expect(results.map(\.id) == [installable, unavailable])
        #expect(results[0].isInstalled)
        #expect(results[0].failure == nil)
        #expect(!results[1].isInstalled)
        let reason = try #require(results[1].failure)
        #expect(reason.contains("Chrome Web Store"))
        #expect(!reason.contains("/"), "A reason never carries a file path")
        #expect(model.installedExtensions.count == 1)
        #expect(model.installedExtensions.first?.isEnabled == false)
    }

    @Test
    func theSourceBrowsersVersionIsWhatTheStoreIsAsked() async throws {
        let store = RecordingWebStore(packages: [:])
        let model = try makeModel(store: store)

        _ = await model.reinstallImportedExtensions([unavailable], chromeVersion: "145.0.7632.46")

        #expect(store.calls.versions == ["145.0.7632.46"])
    }

    @Test
    func theSummarySaysWhatInstalledAndWhatDidNot() {
        let results = [
            ExtensionReinstallResult(id: "a", name: "Alpha", failure: nil),
            ExtensionReinstallResult(id: "b", name: nil, failure: "The Chrome Web Store did not provide that extension."),
            ExtensionReinstallResult(id: "c", name: nil, failure: "The Chrome Web Store did not provide that extension.")
        ]
        let summary = results.summary
        #expect(summary.contains("1 extension installed"))
        #expect(summary.contains("2 could not be installed"))
        #expect(summary.contains("disabled"))
    }
}
