import BrowsemiumCore
import Foundation
import Testing

private func space(locked: Bool = false, separateData: Bool = false) -> BrowserSpace {
    BrowserSpace(name: "Fixture", isLocked: locked,
                 dataStoreID: separateData ? UUID() : nil)
}

@Test func pageTextPolicyAllowsOrdinaryPages() {
    #expect(PageTextIndexPolicy.mayIndex(
        url: URL(string: "https://example.com/article"),
        isPrivate: false, space: space()))
}

@Test func pageTextPolicyRefusesEveryExcludedClass() {
    let page = URL(string: "https://example.com/article")
    // Private windows never index.
    #expect(!PageTextIndexPolicy.mayIndex(url: page, isPrivate: true, space: space()))
    // Locked spaces never index, full stop.
    #expect(!PageTextIndexPolicy.mayIndex(url: page, isPrivate: false, space: space(locked: true)))
    // Spaces with a data store of their own never index.
    #expect(!PageTextIndexPolicy.mayIndex(url: page, isPrivate: false, space: space(separateData: true)))
    // Credentialed URLs would land secrets in the index.
    #expect(!PageTextIndexPolicy.mayIndex(url: URL(string: "https://user:pass@example.com/"),
                                          isPrivate: false, space: space()))
    // Only http(s) pages are content worth indexing.
    #expect(!PageTextIndexPolicy.mayIndex(url: URL(string: "about:blank"), isPrivate: false, space: space()))
    #expect(!PageTextIndexPolicy.mayIndex(url: URL(string: "file:///etc/hosts"), isPrivate: false, space: space()))
    #expect(!PageTextIndexPolicy.mayIndex(url: nil, isPrivate: false, space: space()))
    #expect(!PageTextIndexPolicy.mayIndex(url: page, isPrivate: false, space: nil))
}

@Test func pageTextSnippetCollapsesWhitespaceAndCapsAt4KB() {
    #expect(PageTextIndexPolicy.snippet("a  b\n\nc") == "a b c")
    let long = String(repeating: "word ", count: 2000)
    let capped = PageTextIndexPolicy.snippet(long)
    #expect(capped.utf8.count <= PageTextIndexPolicy.maxSnippetBytes)
    // A true prefix of the collapsed text, with no dangling separator.
    #expect(long.replacingOccurrences(of: " +", with: " ", options: .regularExpression).hasPrefix(capped))
    #expect(!capped.hasSuffix(" "))
    #expect(!capped.isEmpty)
    // Never splits a scalar: the cut lands on a character boundary.
    let emoji = String(repeating: "😀", count: 2000)
    let cappedEmoji = PageTextIndexPolicy.snippet(emoji)
    #expect(cappedEmoji.utf8.count <= PageTextIndexPolicy.maxSnippetBytes)
    #expect(cappedEmoji == String(repeating: "😀", count: cappedEmoji.count))
}

@Test func topicCosineHandlesDegenerateInputs() {
    #expect(TopicClustering.cosine([], []) == 0)
    #expect(TopicClustering.cosine([1, 0], [0, 1]) == 0)
    #expect(abs(TopicClustering.cosine([1, 1], [1, 1]) - 1) < 1e-9)
}

@Test func topicClusteringGroupsSimilarVectors() {
    // Two clear pairs plus a loner.
    let vectors = [
        [1.0, 0.0, 0.0],
        [0.95, 0.05, 0.0],
        [0.0, 1.0, 0.0],
        [0.0, 0.95, 0.05],
        [0.0, 0.0, 1.0]
    ]
    let groups = TopicClustering.cluster(vectors)
    #expect(groups.count == 2)
    #expect(groups.contains([0, 1]))
    #expect(groups.contains([2, 3]))
}

@Test func topicClusteringIsBoundedAndDeterministic() {
    // Four tight groups; only three topics survive the cap.
    let vectors = Array(repeating: [1.0, 0.0], count: 5)
        + Array(repeating: [0.0, 1.0], count: 5)
        + Array(repeating: [0.7, 0.7], count: 5)
        + Array(repeating: [-1.0, 0.0], count: 5)
    let groups = TopicClustering.cluster(vectors)
    #expect(groups.count == TopicClustering.maxTopics)
    #expect(groups.allSatisfy { $0.count <= TopicClustering.maxPagesPerTopic })
    #expect(TopicClustering.cluster(vectors) == groups)
    #expect(TopicClustering.cluster([[1.0]]).isEmpty)
    // Identical vectors are one cluster, however many there are.
    #expect(TopicClustering.cluster(Array(repeating: [1.0, 0.0], count: 20)).count == 1)
}

@Test func topicTermFallbackClustersSharedTitles() {
    let sets: [Set<String>] = [
        ["swift", "concurrency", "explained"],
        ["swift", "actors", "guide"],
        ["sourdough", "starter", "recipe"],
        ["sourdough", "bread", "baking"]
    ]
    let groups = TopicClustering.clusterByTerms(sets)
    #expect(groups.count == 2)
    #expect(TopicClustering.clusterByTerms([Set(["a"])]).isEmpty)
}

@Test func topicLabelsNameTheCluster() {    let label = TopicLabeler.label(
        titles: ["Swift concurrency explained", "Swift actors guide", "SwiftUI layout"],
        snippets: [], fallbackHost: "example.com")
    #expect(label.lowercased().contains("swift"))
    #expect(label.count <= TopicLabeler.maxLabelLength)
    // Empty titles fall back to the host, never to an empty label.
    #expect(TopicLabeler.label(titles: [], snippets: [], fallbackHost: "example.com") == "example.com")
    #expect(TopicLabeler.label(titles: [], snippets: [], fallbackHost: nil) == "Recent pages")
    // Stopwords and short tokens never lead.
    #expect(TopicLabeler.label(titles: ["The a an of to in"], snippets: [], fallbackHost: "h") == "h")
}

private func topicPage(_ host: String, _ title: String, _ snippet: String = "") -> TopicPage {
    TopicPage(url: URL(string: "https://\(host)/")!, title: title, snippet: snippet)
}

@Test func resumeTopicsBuilderUsesEmbeddingsWhenProvided() async {
    let pages = [
        topicPage("a.example", "Swift concurrency explained", "actors tasks"),
        topicPage("b.example", "Swift actors guide", "actors tasks"),
        topicPage("c.example", "Sourdough starter", "flour water"),
        topicPage("d.example", "Sourdough baking", "flour oven")
    ]
    let vectors = [
        [1.0, 0.0], [0.95, 0.05],
        [0.0, 1.0], [0.05, 0.95]
    ]
    let topics = await ResumeTopicsBuilder.build(pages: pages) { _ in vectors }
    #expect(topics.count == 2)
    #expect(topics.allSatisfy { $0.pages.count == 2 })
    #expect(topics.allSatisfy { !$0.label.isEmpty })
}

@Test func resumeTopicsBuilderFallsBackToTermsWithoutEmbeddings() async {
    let pages = [
        topicPage("a.example", "Swift concurrency explained"),
        topicPage("b.example", "Swift actors guide"),
        topicPage("c.example", "Unrelated lone page")
    ]
    let topics = await ResumeTopicsBuilder.build(pages: pages) { _ in nil }
    #expect(topics.count == 1)
    #expect(topics.first?.label.lowercased().contains("swift") == true)
    #expect(await ResumeTopicsBuilder.build(pages: [pages[0]]) { _ in nil }.isEmpty)
    // A vector count mismatch falls back instead of misaligning pages.
    let mismatched = await ResumeTopicsBuilder.build(pages: pages) { _ in [[1.0]] }
    #expect(mismatched.count == 1)
}
