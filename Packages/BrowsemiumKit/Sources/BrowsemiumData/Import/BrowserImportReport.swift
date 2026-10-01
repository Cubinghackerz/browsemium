import Foundation

/// Deliberately contains only closed enums and source ordinals. Never put
/// URLs, usernames, paths, source contents, or underlying errors in a report.
public struct BrowserImportReport: Codable, Sendable, Equatable {
    public enum Category: String, Codable, Sendable, CaseIterable {
        case bookmark, history, password, cookie, searchEngine, `extension`
    }

    public enum Outcome: String, Codable, Sendable {
        case accepted, duplicate, unsupported, failed, skipped
    }

    public enum Stage: String, Codable, Sendable {
        case preview, transfer, persistence
    }

    public enum Reason: String, Codable, Sendable {
        case parsed, imported, alreadyPresent, duplicateInSource
        case unsupportedURL, invalidItem, sourceUnreadable, destinationWriteFailed
        case decryptionFailed, notSelected, outsideSelection, preparedForTransfer, limitExceeded
    }

    public struct Item: Codable, Sendable, Equatable {
        public let category: Category
        /// One-based source ordinal; zero denotes a whole-artifact failure,
        /// not an invented item count.
        public let ordinal: Int
        public let stage: Stage
        public let outcome: Outcome
        public let reason: Reason
    }

    public internal(set) var items: [Item] = []

    public init() {}

    public func count(_ outcome: Outcome, stage: Stage) -> Int {
        items.filter { $0.ordinal > 0 && $0.outcome == outcome && $0.stage == stage }.count
    }

    /// Finish only transfers actually offered by this result. A missing
    /// outcome cannot be presented as a successful persistence operation.
    @discardableResult
    public mutating func completeTransfer(_ category: Category, outcomes: [Outcome]) -> Bool {
        let prepared = items.filter {
            $0.category == category && $0.stage == .transfer && $0.outcome == .accepted
        }
        guard prepared.count == outcomes.count else { return false }
        guard !items.contains(where: { $0.category == category && $0.stage == .persistence }) else { return false }
        for (item, outcome) in zip(prepared, outcomes) {
            record(category, ordinal: item.ordinal, stage: .persistence, outcome: outcome,
                   reason: outcome == .accepted ? .imported : .destinationWriteFailed)
        }
        return true
    }

    mutating func record(_ category: Category, ordinal: Int, stage: Stage = .preview,
                         outcome: Outcome, reason: Reason) {
        items.append(Item(category: category, ordinal: ordinal, stage: stage,
                          outcome: outcome, reason: reason))
    }
}

/// Source keys exist only during parsing, never in the returned report.
struct ImportReportRecorder {
    var report = BrowserImportReport()
    private var ordinals: [BrowserImportReport.Category: Int] = [:]
    private var seen: [BrowserImportReport.Category: Set<String>] = [:]

    mutating func parsed(_ category: BrowserImportReport.Category, key: String) -> Int {
        let ordinal = next(category)
        let normalized = URL(string: key)?.absoluteString ?? key
        let inserted = seen[category, default: []].insert(normalized).inserted
        report.record(category, ordinal: ordinal,
                      outcome: inserted ? .accepted : .duplicate,
                      reason: inserted ? .parsed : .duplicateInSource)
        return ordinal
    }

    mutating func rejected(_ category: BrowserImportReport.Category,
                           reason: BrowserImportReport.Reason = .unsupportedURL) {
        report.record(category, ordinal: next(category), outcome: .unsupported, reason: reason)
    }

    mutating func unreadable(_ category: BrowserImportReport.Category) {
        report.record(category, ordinal: 0, outcome: .failed, reason: .sourceUnreadable)
    }

    private mutating func next(_ category: BrowserImportReport.Category) -> Int {
        ordinals[category, default: 0] += 1
        return ordinals[category, default: 0]
    }
}
