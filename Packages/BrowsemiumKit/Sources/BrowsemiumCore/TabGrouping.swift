import Foundation

/// What the suggester is allowed to see about a tab: its title and host.
/// Never page content, never the full URL.
public struct TabGroupCandidate: Hashable, Sendable {
    public let id: TabID
    public let title: String
    public let host: String?

    public init(id: TabID, title: String, host: String?) {
        self.id = id
        self.title = title
        self.host = host
    }
}

/// A suggested folder. Nothing happens until the person accepts it.
public struct TabGroupProposal: Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var tabIDs: [TabID]

    public init(id: UUID = UUID(), name: String, tabIDs: [TabID]) {
        self.id = id
        self.name = name
        self.tabIDs = tabIDs
    }
}

public protocol TabGroupProposing: Sendable {
    func propose(_ candidates: [TabGroupCandidate]) async throws -> [TabGroupProposal]
}

public enum TabGrouping {
    /// Tabs offered for grouping at once. More than this and a small model
    /// stops being reliable, and the preview stops being reviewable.
    public static let maximumCandidates = 40
    public static let maximumGroupNameLength = 32
}

/// A site's name for grouping purposes. Without the public-suffix list this
/// is an approximation: two labels, or three under a common country-code
/// second level such as `co.uk`.
public enum RegistrableDomain {
    private static let secondLevelLabels: Set<String> = ["co", "com", "org", "net", "gov", "edu", "ac", "or", "ne"]

    public static func of(host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let last = labels[labels.count - 1]
        let second = labels[labels.count - 2]
        if last.count == 2, secondLevelLabels.contains(second) {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }

    /// A readable folder name for a domain: its main label, capitalised.
    public static func displayName(forDomain domain: String) -> String {
        let labels = domain.split(separator: ".").map(String.init)
        let main = labels.count >= 3 && secondLevelLabels.contains(labels[labels.count - 2]) && labels.last?.count == 2
            ? labels[labels.count - 3]
            : (labels.first ?? domain)
        return main.prefix(1).uppercased() + main.dropFirst()
    }
}

/// The version that needs no model: tabs on the same site, three or more.
public struct DomainTabGrouper: TabGroupProposing {
    public let minimumSize: Int

    public init(minimumSize: Int = 3) {
        self.minimumSize = minimumSize
    }

    public func propose(_ candidates: [TabGroupCandidate]) async throws -> [TabGroupProposal] {
        Self.proposals(for: candidates, minimumSize: minimumSize)
    }

    public static func proposals(for candidates: [TabGroupCandidate], minimumSize: Int = 3) -> [TabGroupProposal] {
        var order: [String] = []
        var byDomain: [String: [TabID]] = [:]
        for candidate in candidates.prefix(TabGrouping.maximumCandidates) {
            guard let host = candidate.host, !host.isEmpty else { continue }
            let domain = RegistrableDomain.of(host: host)
            if byDomain[domain] == nil { order.append(domain) }
            byDomain[domain, default: []].append(candidate.id)
        }
        return order.compactMap { domain in
            guard let ids = byDomain[domain], ids.count >= minimumSize else { return nil }
            return TabGroupProposal(name: RegistrableDomain.displayName(forDomain: domain), tabIDs: ids)
        }
    }
}

/// Reads a model's plain-text answer into proposals. The model is asked for
/// one `Name | 1,4,7` line per group; everything it says that does not fit
/// that shape, or names a tab that does not exist, is ignored.
public enum TabTopicParser {
    public static func parse(_ output: String, candidates: [TabGroupCandidate]) -> [TabGroupProposal] {
        var claimed = Set<Int>()
        var proposals: [TabGroupProposal] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            guard let bar = rawLine.lastIndex(of: "|") else { continue }
            let name = clean(String(rawLine[..<bar]))
            let numbers = rawLine[rawLine.index(after: bar)...]
                .split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }
            var picked: [Int] = []
            for number in numbers {
                let index = number - 1
                guard candidates.indices.contains(index), !claimed.contains(index), !picked.contains(index) else { continue }
                picked.append(index)
            }
            guard picked.count >= 2, !name.isEmpty else { continue }
            claimed.formUnion(picked)
            proposals.append(TabGroupProposal(name: name, tabIDs: picked.map { candidates[$0].id }))
        }
        return proposals
    }

    private static func clean(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a list marker ("-", "*", "1.", "2)") the model likes to add.
        if let marker = name.range(of: #"^(?:[-*•]|\d+[.)])\s*"#, options: .regularExpression) {
            name.removeSubrange(marker)
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*#:").union(.whitespaces))
        if name.count > TabGrouping.maximumGroupNameLength {
            name = String(name.prefix(TabGrouping.maximumGroupNameLength)).trimmingCharacters(in: .whitespaces)
        }
        return name
    }
}

/// Finds tabs that show the same page, ignoring the parts of a URL that do
/// not change what page it is.
public enum TabDuplicates {
    /// Identity of a page for duplicate detection: scheme-insensitive,
    /// fragment-free, tracking-parameter-free, trailing-slash-free.
    public static func key(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return nil }
        let cleaned = TrackingParameterStripper.stripped(url) ?? url
        guard var components = URLComponents(url: cleaned, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = nil
        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(host)\(port)\(path.isEmpty ? "/" : path)\(query)"
    }

    /// Tabs that repeat an earlier tab's page. The first (leftmost) copy is
    /// kept; pinned tabs are never listed as duplicates to close, but a
    /// pinned tab does count as the copy to keep.
    public static func duplicates(
        in tabs: [(id: TabID, url: URL?, isPinned: Bool)]
    ) -> [TabID] {
        var keepers: [String: TabID] = [:]
        // Pinned tabs claim their page first so an unpinned twin is the one
        // offered for closing.
        for tab in tabs where tab.isPinned {
            if let url = tab.url, let key = key(for: url), keepers[key] == nil { keepers[key] = tab.id }
        }
        var result: [TabID] = []
        for tab in tabs where !tab.isPinned {
            guard let url = tab.url, let key = key(for: url) else { continue }
            if keepers[key] == nil {
                keepers[key] = tab.id
            } else {
                result.append(tab.id)
            }
        }
        return result
    }
}
