import BrowsemiumCore
import BrowsemiumData
import BrowsemiumEngineKit
import Foundation
import Testing
@testable import BrowsemiumUI

@MainActor
private func makeModel() -> (BrowserWindowModel, BrowserEnvironment) {
    let environment = BrowserEnvironment.inMemory(engine: StubEngine())
    return (BrowserWindowModel(environment: environment), environment)
}

private func closedTab(_ space: SpaceID, _ title: String, _ address: String?) -> BrowserTab {
    BrowserTab(spaceID: space, title: title, lastCommittedURL: address.flatMap(URL.init(string:)))
}

@Suite @MainActor struct NewTabTests {
    // MARK: Pick up where you left off

    @Test func pickUpIsNewestFirstDeduplicatedAndLimited() throws {
        let (model, environment) = makeModel()
        let space = model.session.activeSpaceID
        let now = Date()
        for (offset, name) in ["a", "b", "c", "d", "e"].enumerated() {
            try environment.closedTabRepository.record(
                closedTab(space, name.uppercased(), "https://\(name).example/"),
                closedAt: now.addingTimeInterval(Double(offset))
            )
        }
        // The same address, archived later, must not repeat.
        try environment.archivedTabRepository.record(
            closedTab(space, "A again", "https://a.example/"),
            url: URL(string: "https://a.example/")!,
            archivedAt: now.addingTimeInterval(10)
        )

        let rows = NewTabContent.pickUp(
            closed: model.recentlyClosedTabs(),
            archived: model.archivedTabs(),
            isEligible: { _ in true }
        )

        #expect(rows.count == 4)
        #expect(rows.map(\.host) == ["a.example", "e.example", "d.example", "c.example"])
        #expect(rows.first?.source == .archived)
    }

    @Test func entriesWithoutAnAddressAreDropped() throws {
        let (model, environment) = makeModel()
        let space = model.session.activeSpaceID
        try environment.closedTabRepository.record(closedTab(space, "Blank", nil))
        try environment.closedTabRepository.record(closedTab(space, "Real", "https://real.example/"))

        let rows = NewTabContent.pickUp(
            closed: model.recentlyClosedTabs(), archived: [], isEligible: { _ in true }
        )

        #expect(rows.map(\.title) == ["Real"])
    }

    @Test func aTitlelessEntryFallsBackToItsHost() throws {
        let (model, environment) = makeModel()
        let space = model.session.activeSpaceID
        try environment.closedTabRepository.record(closedTab(space, "  ", "https://untitled.example/x"))

        let rows = NewTabContent.pickUp(
            closed: model.recentlyClosedTabs(), archived: [], isEligible: { _ in true }
        )

        #expect(rows.first?.title == "untitled.example")
    }

    // MARK: Which spaces may be offered

    @Test func lockedAndForeignSeparateDataSpacesAreNeverOffered() {
        let open = BrowserSpace(name: "Open")
        let locked = BrowserSpace(name: "Locked", isLocked: true)
        let separate = BrowserSpace(name: "Work", dataStoreID: UUID())
        let spaces = [open, locked, separate]

        #expect(NewTabContent.isEligible(open.id, spaces: spaces, active: open.id))
        #expect(!NewTabContent.isEligible(locked.id, spaces: spaces, active: locked.id))
        #expect(!NewTabContent.isEligible(locked.id, spaces: spaces, active: open.id))
        #expect(!NewTabContent.isEligible(separate.id, spaces: spaces, active: open.id))
        #expect(NewTabContent.isEligible(separate.id, spaces: spaces, active: separate.id))
        #expect(!NewTabContent.isEligible(SpaceID(), spaces: spaces, active: open.id), "A deleted space is unknown")
    }

    @Test func aLockedSpacesClosedPageDoesNotReachAnotherStartPage() throws {
        let (model, environment) = makeModel()
        let active = model.session.activeSpaceID
        let locked = BrowserSpace(name: "Private notes", isLocked: true)
        try environment.closedTabRepository.record(closedTab(locked.id, "Secret", "https://secret.example/"))
        try environment.closedTabRepository.record(closedTab(active, "Fine", "https://fine.example/"))
        let spaces = model.session.spaces + [locked]

        let rows = NewTabContent.pickUp(
            closed: model.recentlyClosedTabs(), archived: [],
            isEligible: { NewTabContent.isEligible($0, spaces: spaces, active: active) }
        )

        #expect(rows.map(\.title) == ["Fine"])
    }

    // MARK: Tiles

    @Test func fallbackLetterIsTheFirstLetterOfTheHost() {
        #expect(NewTabContent.fallbackLetter(forHost: "www.swift.org") == "S")
        #expect(NewTabContent.fallbackLetter(forHost: "9to5mac.com") == "9")
        #expect(NewTabContent.fallbackLetter(forHost: nil) == "•")
        #expect(NewTabContent.fallbackLetter(forHost: "---") == "•")
    }

    // MARK: Actions

    @Test func aSiteTileOpensItsAddressInTheStartTab() throws {
        let (model, _) = makeModel()
        let tabs = model.session.tabs.count

        NewTabTarget.site(URL(string: "https://swift.org/blog")!).perform(in: model)

        #expect(model.activeTab?.lastCommittedURL?.absoluteString == "https://swift.org/blog")
        #expect(model.session.tabs.count == tabs, "A tile navigates the start tab; it opens no second tab")
    }

    @Test func theSearchFieldUsesTheAddressBarsResolver() {
        let (model, _) = makeModel()

        NewTabTarget.search("example.com/docs").perform(in: model)
        #expect(model.activeTab?.lastCommittedURL?.absoluteString == "https://example.com/docs")

        let (searchModel, _) = makeModel()
        NewTabTarget.search("  swift concurrency  ").perform(in: searchModel)
        let url = searchModel.activeTab?.lastCommittedURL
        #expect(url?.host?.contains("google") == true)
        #expect(url?.absoluteString.contains("swift") == true)
        #expect(searchModel.addressText == "swift concurrency", "The bar keeps the trimmed query")
    }

    @Test func anEmptySearchDoesNothing() {
        let (model, _) = makeModel()
        let before = model.activeTab?.lastCommittedURL

        NewTabTarget.search("   ").perform(in: model)

        #expect(model.activeTab?.lastCommittedURL == before)
    }

    @Test func aRecentlyClosedRowReopensInPlaceAndLeavesTheList() throws {
        let (model, environment) = makeModel()
        let space = model.session.activeSpaceID
        try environment.closedTabRepository.record(closedTab(space, "Docs", "https://docs.example/a"))
        let row = try #require(
            NewTabContent.pickUp(
                closed: model.recentlyClosedTabs(), archived: [], isEligible: { _ in true }
            ).first
        )
        let tabs = model.session.tabs.count

        NewTabTarget.pickUp(row).perform(in: model)

        #expect(model.activeTab?.lastCommittedURL?.absoluteString == "https://docs.example/a")
        #expect(model.session.tabs.count == tabs)
        #expect(model.recentlyClosedTabs().isEmpty)
    }

    @Test func anArchivedRowReopensInPlaceAndLeavesTheArchive() throws {
        let (model, environment) = makeModel()
        let space = model.session.activeSpaceID
        let url = URL(string: "https://archive.example/old")!
        try environment.archivedTabRepository.record(closedTab(space, "Old", url.absoluteString), url: url)
        let row = try #require(
            NewTabContent.pickUp(
                closed: [], archived: model.archivedTabs(), isEligible: { _ in true }
            ).first
        )

        NewTabTarget.pickUp(row).perform(in: model)

        #expect(model.activeTab?.lastCommittedURL == url)
        #expect(model.archivedTabs().isEmpty)
    }
}
