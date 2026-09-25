import BrowsemiumCore
import BrowsemiumData
import BrowsemiumUI
import Foundation
import Testing
import BrowsemiumEngineKit

@Test @MainActor
func openingAPeekDoesNotCreateATab() {
    let model = BrowserWindowModel()
    let tabsBefore = model.session.tabs
    let url = URL(string: "https://preview.example/page")!

    model.openPeek(url: url)

    let peek = model.peek
    #expect(peek != nil)
    #expect(peek?.url == url)
    #expect(peek?.title == "preview.example")
    #expect(model.session.tabs == tabsBefore)
    #expect(model.tabURLs[peek!.tabID] == url)
}

@Test @MainActor
func closingAPeekLeavesNoTrace() {
    let model = BrowserWindowModel()
    let tabsBefore = model.session.tabs
    model.openPeek(url: URL(string: "https://preview.example/transient")!)
    let peekTabID = model.peek?.tabID

    model.closePeek()

    #expect(model.peek == nil)
    #expect(peekTabID.flatMap { model.tabURLs[$0] } == nil)
    #expect(model.session.tabs == tabsBefore)
    // Closing an already-closed peek is a no-op, not a crash.
    model.closePeek()
    #expect(model.peek == nil)
}

@Test @MainActor
func promotingAPeekAdoptsTheLoadedEngineTab() {
    let model = BrowserWindowModel()
    let url = URL(string: "https://preview.example/promote")!
    model.openPeek(url: url)
    let peekTabID = model.peek?.tabID

    let promoted = model.promotePeekToTab()

    #expect(promoted == peekTabID)
    #expect(model.peek == nil)
    let tab = model.session.tabs.first { $0.id == peekTabID }
    #expect(tab?.lastCommittedURL == url)
    #expect(tab?.lifecycle == .active)
    #expect(tab?.spaceID == model.session.activeSpaceID)
    #expect(model.session.activeTabID == peekTabID)
    #expect(model.addressText == url.absoluteString)
}

@Test @MainActor
func openingASecondPeekReplacesTheFirst() {
    let model = BrowserWindowModel()
    model.openPeek(url: URL(string: "https://first.example")!)
    let firstTabID = model.peek?.tabID

    model.openPeek(url: URL(string: "https://second.example")!)

    #expect(model.peek?.tabID != firstTabID)
    #expect(firstTabID.flatMap { model.tabURLs[$0] } == nil)
    #expect(model.session.tabs.contains { $0.id == firstTabID } == false)
}

@Test @MainActor
func promotedPeekIsPersistedButClosedPeekIsNot() async throws {
    let environment = BrowserEnvironment.inMemory()
    let model = BrowserWindowModel(environment: environment)

    model.openPeek(url: URL(string: "https://preview.example/never-saved")!)
    model.closePeek()

    model.openPeek(url: URL(string: "https://preview.example/saved")!)
    model.promotePeekToTab()

    var restored: BrowserSessionState?
    for _ in 0..<50 {
        restored = try? environment.sessionRepository.load()
        if restored?.tabs.contains(where: { $0.lastCommittedURL?.absoluteString == "https://preview.example/saved" }) == true { break }
        try? await Task.sleep(for: .milliseconds(20))
    }
    let session = try #require(restored)
    #expect(session.tabs.contains { $0.lastCommittedURL?.absoluteString == "https://preview.example/saved" })
    #expect(!session.tabs.contains { $0.lastCommittedURL?.absoluteString == "https://preview.example/never-saved" })
}

@Test @MainActor
func promotingAPeekRecordsHistoryButClosingOneDoesNot() async throws {
    let environment = BrowserEnvironment.inMemory()
    let model = BrowserWindowModel(environment: environment)

    model.openPeek(url: URL(string: "https://preview.example/closed")!)
    model.closePeek()
    model.openPeek(url: URL(string: "https://preview.example/kept")!)
    model.promotePeekToTab()

    // History writes are serialized off the main thread; poll for the entry.
    var recent: [HistoryVisit] = []
    for _ in 0..<50 {
        recent = (try? environment.historyRepository.recent()) ?? []
        if recent.contains(where: { $0.url.absoluteString == "https://preview.example/kept" }) { break }
        try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(recent.contains { $0.url.absoluteString == "https://preview.example/kept" })
    #expect(!recent.contains { $0.url.absoluteString == "https://preview.example/closed" })
}

@Test @MainActor
func promotingWithoutAPeekIsANoOp() {
    let model = BrowserWindowModel()
    #expect(model.promotePeekToTab() == nil)
    #expect(model.peek == nil)
}
