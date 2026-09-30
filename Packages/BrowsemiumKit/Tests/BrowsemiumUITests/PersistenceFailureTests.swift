import BrowsemiumCore
import BrowsemiumData
import BrowsemiumEngineKit
import Foundation
import Testing
@testable import BrowsemiumUI

@Suite @MainActor struct PersistenceFailureTests {
    private func rejectWrites(_ environment: BrowserEnvironment, table: String, operation: String = "INSERT") throws {
        try #require(["bookmarks", "closed_tabs", "downloads", "site_permissions", "history_visits"].contains(table))
        try #require(["INSERT", "DELETE"].contains(operation))
        try environment.database.databaseQueue.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_fixture_writes BEFORE \(operation) ON \(table) BEGIN SELECT RAISE(ABORT, 'Fixture write rejected'); END")
        }
    }

    @Test func bookmarkRemovalExplainsFailureAndKeepsBookmark() throws {
        let environment = BrowserEnvironment.inMemory(engine: StubEngine())
        let bookmark = try environment.bookmarkRepository.add(url: URL(string: "https://bookmark.example")!, title: "Fixture")
        let model = BrowserWindowModel(environment: environment)
        try rejectWrites(environment, table: "bookmarks", operation: "DELETE")
        model.removeBookmark(bookmark)
        #expect(model.statusMessage == "Couldn't save bookmark change")
        #expect(model.bookmarks.contains { $0.id == bookmark.id })
    }

    @Test func closedTabFailureDoesNotPreventClosing() throws {
        let environment = BrowserEnvironment.inMemory(engine: StubEngine())
        let model = BrowserWindowModel(environment: environment)
        let tabID = model.newTab(url: URL(string: "https://closed.example")!)
        try rejectWrites(environment, table: "closed_tabs")
        model.closeTab(tabID)
        #expect(model.statusMessage == "Couldn't save recently closed tab")
        #expect(!model.session.tabs.contains { $0.id == tabID })
    }

    @Test func completedDownloadDoesNotHidePersistenceFailure() throws {
        let environment = BrowserEnvironment.inMemory(engine: StubEngine())
        let model = BrowserWindowModel(environment: environment)
        try rejectWrites(environment, table: "downloads")
        model.handleDownload(DownloadInfo(id: UUID(), tabID: model.session.activeTabID,
            sourceURL: URL(string: "https://download.example/file"), suggestedFilename: "fixture.txt",
            destinationURL: nil, bytesReceived: 10, totalBytes: 10, isFinished: true, failureMessage: nil))
        #expect(model.statusMessage == "Couldn't save download history")
        #expect(model.downloads.first?.isFinished == true)
    }

    @Test func rememberedPermissionFailureStillAnswersCurrentRequest() async throws {
        let environment = BrowserEnvironment.inMemory(engine: StubEngine())
        let model = BrowserWindowModel(environment: environment)
        try rejectWrites(environment, table: "site_permissions")
        let request = Task { await model.permissionDecision(origin: "https://permission.example", kind: .camera) }
        let pending = try await waitFor { model.pendingPermissionCount == 1 }
        try #require(pending)
        model.answerPermissionRequest(.allowAlways)
        #expect(await request.value == .allow)
        #expect(model.statusMessage == "Couldn't save site permission")
        #expect(model.sitePermissions.isEmpty)
    }

    @Test func historyFailureReturnsToMainActorWithoutCrashing() async throws {
        let engine = StubEngine()
        let environment = BrowserEnvironment.inMemory(engine: engine)
        let model = BrowserWindowModel(environment: environment)
        try rejectWrites(environment, table: "history_visits")
        engine.emit(.finished(title: "Fixture", url: URL(string: "https://history.example")!), for: model.session.activeTabID!)
        let reported = try await waitFor { model.statusMessage == "Couldn't save history" }
        #expect(reported)
        #expect(model.activeTab?.lifecycle == .active)
    }
}
