import BrowsemiumCore
import Foundation
import Testing

private func candidate(_ title: String, _ host: String?) -> TabGroupCandidate {
    TabGroupCandidate(id: TabID(), title: title, host: host)
}

@Test
func registrableDomainsHandleCommonShapes() {
    #expect(RegistrableDomain.of(host: "github.com") == "github.com")
    #expect(RegistrableDomain.of(host: "gist.github.com") == "github.com")
    #expect(RegistrableDomain.of(host: "a.b.example.org") == "example.org")
    #expect(RegistrableDomain.of(host: "news.bbc.co.uk") == "bbc.co.uk")
    #expect(RegistrableDomain.of(host: "localhost") == "localhost")
    #expect(RegistrableDomain.displayName(forDomain: "github.com") == "Github")
    #expect(RegistrableDomain.displayName(forDomain: "bbc.co.uk") == "Bbc")
}

@Test
func domainGroupingNeedsThreeTabsOnTheSameSite() async throws {
    let tabs = [
        candidate("a", "github.com"), candidate("b", "gist.github.com"), candidate("c", "github.com"),
        candidate("d", "example.com"), candidate("e", "example.com"),
        candidate("f", nil), candidate("g", "")
    ]
    let proposals = try await DomainTabGrouper().propose(tabs)
    #expect(proposals.count == 1)
    #expect(proposals.first?.name == "Github")
    #expect(proposals.first?.tabIDs == [tabs[0].id, tabs[1].id, tabs[2].id])
}

@Test
func domainGroupingIsBounded() {
    let many = (0..<200).map { candidate("t\($0)", "same.example") }
    let proposals = DomainTabGrouper.proposals(for: many)
    #expect(proposals.first?.tabIDs.count == TabGrouping.maximumCandidates)
}

@Test
func theParserKeepsOnlyWellFormedGroupsOfRealTabs() {
    let tabs = (0..<6).map { candidate("t\($0)", "h\($0).example") }
    let output = """
    Here are the groups:
    1. Reading | 1, 2, 3
    - "Travel" | 4,5
    Solo | 6
    Ghost | 9, 10
    Overlap | 3, 4, 5, 6
    Fresh | 6, 3, 1
    | 1,2
    no bar here 1 2 3
    """
    let proposals = TabTopicParser.parse(output, candidates: tabs)

    // "Solo" has one tab, "Ghost" names tabs that do not exist, and "Overlap"
    // and "Fresh" are left with fewer than two unclaimed tabs.
    #expect(proposals.map(\.name) == ["Reading", "Travel"])
    #expect(proposals[0].tabIDs == [tabs[0].id, tabs[1].id, tabs[2].id])
    #expect(proposals[1].tabIDs == [tabs[3].id, tabs[4].id])
    // A tab claimed by an earlier group is not offered twice.
    let all = proposals.flatMap(\.tabIDs)
    #expect(Set(all).count == all.count)
}

@Test
func parserNamesAreBoundedAndCleaned() {
    let tabs = (0..<4).map { candidate("t\($0)", nil) }
    let long = String(repeating: "Wordy ", count: 20)
    let proposals = TabTopicParser.parse("**\(long)** | 1,2\n2) `Short`: | 3,4", candidates: tabs)
    #expect(proposals.count == 2)
    #expect(proposals[0].name.count <= TabGrouping.maximumGroupNameLength)
    #expect(proposals[1].name == "Short")
}

@Test
func duplicateKeysIgnoreFragmentsTrackingAndTrailingSlashes() {
    func key(_ s: String) -> String? { TabDuplicates.key(for: URL(string: s)!) }
    #expect(key("https://Example.com/a/") == key("https://example.com/a"))
    #expect(key("https://example.com/a#top") == key("https://example.com/a"))
    #expect(key("https://example.com/a?utm_source=x") == key("https://example.com/a"))
    #expect(key("http://example.com/a") == key("https://example.com/a"))
    #expect(key("https://example.com/a?q=1") != key("https://example.com/a?q=2"))
    #expect(key("https://example.com:8443/a") != key("https://example.com/a"))
    #expect(key("about:blank") == nil)
    #expect(key("file:///tmp/x") == nil)
}

@Test
func duplicatesKeepTheFirstCopyAndNeverOfferAPinnedTabForClosing() {
    let a = (id: TabID(), url: URL(string: "https://example.com/a"), isPinned: false)
    let b = (id: TabID(), url: URL(string: "https://example.com/a#x"), isPinned: false)
    let c = (id: TabID(), url: URL(string: "https://example.com/c"), isPinned: false)
    let pinned = (id: TabID(), url: URL(string: "https://example.com/c"), isPinned: true)
    let blank = (id: TabID(), url: URL?.none, isPinned: false)
    let result = TabDuplicates.duplicates(in: [a, b, c, pinned, blank])

    #expect(result == [b.id, c.id])
    #expect(!result.contains(pinned.id))
    #expect(!result.contains(blank.id))
}
