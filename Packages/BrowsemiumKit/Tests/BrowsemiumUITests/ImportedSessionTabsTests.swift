import BrowsemiumCore
import BrowsemiumData
import BrowsemiumUI
import Foundation
import Testing
import BrowsemiumEngineKit

@MainActor
private func safariSessionFolder(tabCount: Int, pinned: Bool = false) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-import-tabs-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let bookmarks: [String: Any] = ["Children": [], "Title": "Bookmarks"]
    try PropertyListSerialization.data(fromPropertyList: bookmarks, format: .xml, options: 0)
        .write(to: folder.appendingPathComponent("Bookmarks.plist"))
    var tabs: [[String: String]] = []
    for index in 0..<tabCount {
        tabs.append(["URLString": "https://import.example/page\(index)", "Title": "Page \(index)"])
    }
    let session: [String: Any] = ["SessionWindows": [["Tabs": tabs]]]
    try PropertyListSerialization.data(fromPropertyList: session, format: .binary, options: 0)
        .write(to: folder.appendingPathComponent("LastSession.plist"))
    return folder
}

@MainActor
private func previewTabs(in folder: URL) throws -> [BrowserImportPreview.SessionTab] {
    let database = try AppDatabase.inMemory()
    let importer = BrowserDataImporter(
        bookmarks: BookmarkRepository(database: database),
        history: HistoryRepository(database: database)
    )
    return try importer.preview(at: folder, source: .safari).sessionTabs
}

@Test @MainActor
func importedSessionTabsOpenUnloadedWithSourceTitles() throws {
    let folder = try safariSessionFolder(tabCount: 3)
    defer { try? FileManager.default.removeItem(at: folder) }
    let tabs = try previewTabs(in: folder)
    let model = BrowserWindowModel(environment: .inMemory(engine: StubEngine()))
    let before = model.session.tabs.count

    let outcomes = model.openImportedSessionTabs(tabs)

    #expect(outcomes == [.accepted, .accepted, .accepted])
    #expect(model.session.tabs.count == before + 3)
    let opened = model.session.tabs.suffix(3)
    #expect(opened.map(\.title) == ["Page 0", "Page 1", "Page 2"])
    // Unloaded until visited, like restored sessions — never a webview storm.
    #expect(opened.allSatisfy { $0.lifecycle == .metadataOnly })
    #expect(model.session.activeTabID == opened.first?.id)
}

@Test @MainActor
func reimportingSessionTabsIsIdempotent() throws {
    let folder = try safariSessionFolder(tabCount: 2)
    defer { try? FileManager.default.removeItem(at: folder) }
    let tabs = try previewTabs(in: folder)
    let model = BrowserWindowModel(environment: .inMemory(engine: StubEngine()))

    #expect(model.openImportedSessionTabs(tabs).allSatisfy { $0 == .accepted })
    let count = model.session.tabs.count
    #expect(model.openImportedSessionTabs(tabs) == [.duplicate, .duplicate])
    #expect(model.session.tabs.count == count)
}

@Test @MainActor
func alreadyOpenPagesAreSkipped() throws {
    let folder = try safariSessionFolder(tabCount: 2)
    defer { try? FileManager.default.removeItem(at: folder) }
    let tabs = try previewTabs(in: folder)
    let model = BrowserWindowModel(environment: .inMemory(engine: StubEngine()))
    let before = model.session.tabs.count
    _ = model.newTab(url: URL(string: "https://import.example/page1"))

    let outcomes = model.openImportedSessionTabs(tabs)

    #expect(outcomes == [.accepted, .duplicate])
    // The manually opened tab plus the one imported tab; the open page was
    // not duplicated.
    #expect(model.session.tabs.count == before + 2)
    #expect(model.session.tabs.contains { $0.title == "Page 0" })
}

@Test @MainActor
func privateWindowsOpenNoImportedTabs() throws {
    let folder = try safariSessionFolder(tabCount: 2)
    defer { try? FileManager.default.removeItem(at: folder) }
    let tabs = try previewTabs(in: folder)
    let model = BrowserWindowModel(environment: .inMemory(engine: StubEngine()))
    model.enterPrivateMode()
    let before = model.session.tabs.count

    #expect(model.openImportedSessionTabs(tabs) == [.skipped, .skipped])
    #expect(model.session.tabs.count == before)
}

@Test @MainActor
func sessionTabImportIsCappedPerImport() throws {
    let folder = try safariSessionFolder(tabCount: 105)
    defer { try? FileManager.default.removeItem(at: folder) }
    // The reader cap (2000) holds all 105; the per-import open cap applies.
    let tabs = try previewTabs(in: folder)
    #expect(tabs.count == 105)
    let model = BrowserWindowModel(environment: .inMemory(engine: StubEngine()))
    let before = model.session.tabs.count

    let outcomes = model.openImportedSessionTabs(tabs)

    #expect(outcomes.filter { $0 == .accepted }.count == BrowserWindowModel.maxImportedSessionTabsPerImport)
    #expect(outcomes.filter { $0 == .skipped }.count == 105 - BrowserWindowModel.maxImportedSessionTabsPerImport)
    #expect(model.session.tabs.count == before + BrowserWindowModel.maxImportedSessionTabsPerImport)
}
