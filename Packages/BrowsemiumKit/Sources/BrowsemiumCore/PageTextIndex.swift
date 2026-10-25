import Foundation

/// Eligibility for the opt-in on-Mac page-text index. Pure and testable: the
/// caller additionally checks the settings switch and the per-site exclude
/// list, which live in the database, not here.
///
/// Never indexed, no matter the switch: private sessions, locked spaces (even
/// while unlocked — the lock hides the space's content from every surface),
/// spaces with a data store of their own, credentialed URLs (userinfo would
/// land in the index), and non-http(s) addresses.
public enum PageTextIndexPolicy {
    public static func mayIndex(url: URL?, isPrivate: Bool, space: BrowserSpace?) -> Bool {
        guard !isPrivate,
              let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              url.user == nil, url.password == nil,
              let space, !space.isLocked, !space.hasSeparateData else {
            return false
        }
        return true
    }

    /// Collapses runs of whitespace and caps stored text at 4 KB, so one
    /// page cannot bloat the profile database.
    public static let maxSnippetBytes = 4 * 1024

    public static func snippet(_ text: String) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let data = collapsed.data(using: .utf8), data.count > maxSnippetBytes else {
            return collapsed
        }
        var end = collapsed.startIndex
        var used = 0
        // Character boundaries are scalar boundaries, so the cut never
        // splits a scalar or a grapheme.
        for character in collapsed {
            let next = used + String(character).utf8.count
            if next > maxSnippetBytes { break }
            used = next
            end = collapsed.index(after: end)
        }
        // The byte cap can land on a separator; don't store the dangling
        // whitespace.
        return String(collapsed[..<end]).replacingOccurrences(
            of: "\\s+$", with: "", options: .regularExpression)
    }
}

/// One indexed page offered back to the start page or suggestions.
public struct TopicPage: Hashable, Codable, Sendable {
    public let url: URL
    public let title: String
    public let snippet: String

    public init(url: URL, title: String, snippet: String) {
        self.url = url
        self.title = title
        self.snippet = snippet
    }
}

/// A "Resume topics" group on the new-tab page: a derived label plus the
/// pages behind it. Labels come from title n-grams, never from page text
/// summarization — they name the cluster, not its content.
public struct ResumeTopic: Hashable, Codable, Sendable, Identifiable {
    public var id: String { label + pages.map(\.url.absoluteString).joined() }
    public let label: String
    public let pages: [TopicPage]

    public init(label: String, pages: [TopicPage]) {
        self.label = label
        self.pages = pages
    }
}

/// Assembles resume topics from indexed pages. The embed closure is
/// injected so tests pin each path: real vectors for the embedding route,
/// nil for the term-overlap fallback.
public enum ResumeTopicsBuilder {
    public static func build(
        pages: [TopicPage],
        embed: ([String]) async -> [[Double]]?,
        embeddingThreshold: Double = TopicClustering.embeddingSimilarityThreshold
    ) async -> [ResumeTopic] {
        guard pages.count >= TopicClustering.minimumGroupSize else { return [] }
        let texts = pages.map { "\($0.title)\n\($0.snippet.prefix(500))" }
        let groups: [[Int]]
        if let vectors = await embed(texts), vectors.count == pages.count {
            groups = TopicClustering.cluster(vectors, threshold: embeddingThreshold)
        } else {
            groups = TopicClustering.clusterByTerms(texts.map(TopicLabeler.termSet))
        }
        return groups.map { group in
            let members = group.map { pages[$0] }
            return ResumeTopic(
                label: TopicLabeler.label(
                    titles: members.map(\.title),
                    snippets: members.map(\.snippet),
                    fallbackHost: members.first?.url.host),
                pages: members
            )
        }
    }
}

/// Greedy agglomerative clustering over embedding vectors. Deterministic:
/// pairs merge highest-similarity first with index tiebreaks, so the same
/// input always yields the same topics.
public enum TopicClustering {
    public static let similarityThreshold = 0.72
    /// Threshold for on-device contextual-embedding vectors. Calibrated on
    /// the current NL revision (512-dim, mean-pooled): clearly same-topic
    /// short texts measured 0.93–0.96, clearly different ones 0.74–0.82, so
    /// 0.85 sits inside the gap with margin on both sides. Contextual
    /// vectors are anisotropic — unrelated texts still score high — which is
    /// why this is far above the generic default. Model revisions can shift
    /// the geometry; the term-overlap fallback covers a total miss.
    public static let embeddingSimilarityThreshold = 0.85
    public static let maxTopics = 3
    public static let minimumGroupSize = 2
    public static let maxPagesPerTopic = 8

    public static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// Index groups, largest first. `vectors[i]` belongs to page `i`.
    public static func cluster(
        _ vectors: [[Double]],
        threshold: Double = similarityThreshold,
        maxTopics: Int = maxTopics,
        minimumGroupSize: Int = minimumGroupSize
    ) -> [[Int]] {
        guard vectors.count >= minimumGroupSize else { return [] }
        var parent = Array(0..<vectors.count)
        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root { root = parent[root] }
            return root
        }
        var pairs: [(similarity: Double, a: Int, b: Int)] = []
        for a in vectors.indices {
            for b in (a + 1)..<vectors.count {
                pairs.append((cosine(vectors[a], vectors[b]), a, b))
            }
        }
        pairs.sort {
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            if $0.a != $1.a { return $0.a < $1.a }
            return $0.b < $1.b
        }
        for pair in pairs where pair.similarity >= threshold {
            let (ra, rb) = (find(pair.a), find(pair.b))
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
        var groups: [Int: [Int]] = [:]
        for index in vectors.indices {
            groups[find(index), default: []].append(index)
        }
        return groups.values
            .filter { $0.count >= minimumGroupSize }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.min()! < $1.min()!
            }
            .prefix(maxTopics)
            .map { Array($0.prefix(maxPagesPerTopic)) }
    }

    /// Fallback when embedding assets are unavailable: overlap over title
    /// term sets (`shared / smaller`), same group selection as above. Generic
    /// words are stopwords, so sharing one surviving term already signals a
    /// topic at this threshold.
    public static func clusterByTerms(
        _ termSets: [Set<String>],
        threshold: Double = 0.3,
        maxTopics: Int = maxTopics,
        minimumGroupSize: Int = minimumGroupSize
    ) -> [[Int]] {
        guard termSets.count >= minimumGroupSize else { return [] }
        var parent = Array(0..<termSets.count)
        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root { root = parent[root] }
            return root
        }
        func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
            guard !a.isEmpty, !b.isEmpty else { return 0 }
            return Double(a.intersection(b).count) / Double(min(a.count, b.count))
        }
        var pairs: [(similarity: Double, a: Int, b: Int)] = []
        for a in termSets.indices {
            for b in (a + 1)..<termSets.count {
                pairs.append((overlap(termSets[a], termSets[b]), a, b))
            }
        }
        pairs.sort {
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            if $0.a != $1.a { return $0.a < $1.a }
            return $0.b < $1.b
        }
        for pair in pairs where pair.similarity >= threshold {
            let (ra, rb) = (find(pair.a), find(pair.b))
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
        var groups: [Int: [Int]] = [:]
        for index in termSets.indices {
            groups[find(index), default: []].append(index)
        }
        return groups.values
            .filter { $0.count >= minimumGroupSize }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.min()! < $1.min()!
            }
            .prefix(maxTopics)
            .map { Array($0.prefix(maxPagesPerTopic)) }
    }
}

/// Topic labels from title n-grams. Terms are counted across member titles
/// (a term in several titles outranks one repeated in a single title);
/// snippet terms break ties. Two to three words, capped in length, falling
/// back to the first page's host — never an empty label.
public enum TopicLabeler {
    public static let maxLabelLength = 48

    static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from",
        "how", "in", "is", "it", "of", "on", "or", "that", "the", "this", "to",
        "with", "you", "your", "what", "when", "where", "which", "we", "all",
        "new", "more", "best", "guide", "get", "vs", "via", "de", "la", "und",
        "der", "die", "das", "the", "inc", "com", "www", "http", "https"
    ]

    public static func terms(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
    }

    public static func termSet(_ text: String) -> Set<String> {
        Set(terms(text))
    }

    public static func label(titles: [String], snippets: [String], fallbackHost: String?) -> String {
        var titleHits: [String: Int] = [:]
        for title in titles {
            for term in Set(terms(title)) {
                titleHits[term, default: 0] += 1
            }
        }
        var snippetHits: [String: Int] = [:]
        for snippet in snippets.prefix(8) {
            for term in Set(terms(String(snippet.prefix(2000)))) {
                snippetHits[term, default: 0] += 1
            }
        }
        let ranked = titleHits.keys.sorted {
            let (aTitles, bTitles) = (titleHits[$0] ?? 0, titleHits[$1] ?? 0)
            if aTitles != bTitles { return aTitles > bTitles }
            let (aSnip, bSnip) = (snippetHits[$0] ?? 0, snippetHits[$1] ?? 0)
            if aSnip != bSnip { return aSnip > bSnip }
            return $0 < $1
        }
        let words = Array(ranked.prefix(3))
        if words.isEmpty {
            return fallbackHost ?? "Recent pages"
        }
        var label = words.joined(separator: " ")
        if label.count > maxLabelLength {
            label = String(label.prefix(maxLabelLength))
        }
        return label.prefix(1).uppercased() + label.dropFirst()
    }
}
