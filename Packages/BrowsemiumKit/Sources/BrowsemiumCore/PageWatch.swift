import CryptoKit
import Foundation

/// A page the person asked to be told about when it changes.
public struct PageWatch: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let url: URL
    public var title: String
    public var intervalMinutes: Int
    public var lastHash: String?
    /// Short hashes of the sentences on the page at the last check. Never the
    /// text: just enough to tell which sentences are new.
    public var lastSentences: [String]
    public var lastCheckedAt: Date?
    public var lastChangedAt: Date?
    public var consecutiveFailures: Int
    /// Plain words for the last problem, such as "needs sign-in".
    public var lastProblem: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        intervalMinutes: Int = PageWatchLimits.defaultIntervalMinutes,
        lastHash: String? = nil,
        lastSentences: [String] = [],
        lastCheckedAt: Date? = nil,
        lastChangedAt: Date? = nil,
        consecutiveFailures: Int = 0,
        lastProblem: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.intervalMinutes = intervalMinutes
        self.lastHash = lastHash
        self.lastSentences = lastSentences
        self.lastCheckedAt = lastCheckedAt
        self.lastChangedAt = lastChangedAt
        self.consecutiveFailures = consecutiveFailures
        self.lastProblem = lastProblem
        self.createdAt = createdAt
    }
}

public enum PageWatchLimits {
    public static let minimumIntervalMinutes = 15
    public static let defaultIntervalMinutes = 60
    public static let maximumWatches = 20
    public static let maximumBodyBytes = 1_500_000
    public static let maximumTextCharacters = 60_000
    /// Differences smaller than this are treated as noise (a counter ticking).
    public static let minimumChangedCharacters = 12
    public static let allowedIntervals = [15, 30, 60, 360, 1440]
    /// After this many failures in a row the watch pauses itself.
    public static let maximumConsecutiveFailures = 6

    /// Backoff after failures: the interval doubles each time, capped at a day.
    public static func effectiveInterval(minutes: Int, failures: Int) -> Int {
        let base = max(minutes, minimumIntervalMinutes)
        guard failures > 0 else { return base }
        return min(base << min(failures, 8), 24 * 60)
    }
}

public enum PageWatchSchedule {
    /// Watches whose turn has come. A watch that has never been checked is
    /// due at once; one that failed too often is paused until re-enabled.
    public static func due(_ watches: [PageWatch], now: Date) -> [PageWatch] {
        watches.filter { watch in
            guard watch.consecutiveFailures < PageWatchLimits.maximumConsecutiveFailures else { return false }
            guard let last = watch.lastCheckedAt else { return true }
            let interval = PageWatchLimits.effectiveInterval(minutes: watch.intervalMinutes, failures: watch.consecutiveFailures)
            return now.timeIntervalSince(last) >= TimeInterval(interval) * 60
        }
    }
}

/// Turns fetched HTML into the text a person would read, so a changed
/// script, style, comment or attribute does not count as a changed page.
public enum PageTextNormalizer {
    public static func visibleText(fromHTML html: String) -> String {
        var text = html
        for block in ["script", "style", "noscript", "template", "svg"] {
            text = text.replacingOccurrences(
                of: "<\(block)\\b[^>]*>[\\s\\S]*?</\(block)\\s*>",
                with: " ", options: [.regularExpression, .caseInsensitive]
            )
        }
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        for (entity, value) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(PageWatchLimits.maximumTextCharacters))
    }

    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the page is asking for a password, which means the fetch got a
    /// sign-in page rather than the page the person watches.
    public static func looksLikeSignIn(html: String) -> Bool {
        html.range(of: #"<input\b[^>]*type\s*=\s*["']?password"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

public enum PageWatchDiff {
    public static let maximumSentences = 2_000

    /// A short fingerprint per sentence, in page order, without repeats.
    public static func sentenceHashes(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for sentence in sentences(text) {
            let digest = PageTextNormalizer.hash(sentence.lowercased()).prefix(16)
            if seen.insert(String(digest)).inserted {
                result.append(String(digest))
                if result.count >= maximumSentences { break }
            }
        }
        return result
    }

    /// What is new on the page compared with the sentences seen last time,
    /// as a short quotation, or nil when the difference is only noise. A page
    /// that only lost text reports that plainly.
    public static func change(previous: [String], newText: String) -> String? {
        let known = Set(previous)
        let current = sentences(newText)
        let added = current.filter { !known.contains(String(PageTextNormalizer.hash($0.lowercased()).prefix(16))) }
        let addedText = added.joined(separator: ". ")
        if addedText.count >= PageWatchLimits.minimumChangedCharacters {
            return String(addedText.prefix(160))
        }
        let nowSeen = Set(sentenceHashes(newText))
        let removed = known.subtracting(nowSeen).count
        return removed >= 3 ? "Some text was removed." : nil
    }

    static func sentences(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
    }
}
