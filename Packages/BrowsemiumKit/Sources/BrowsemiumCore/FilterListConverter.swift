import Foundation

public struct FilterListConversion: Sendable {
    public enum SkipReason: String, Codable, Sendable {
        case duplicate, invalidDomain, unsupportedPattern, unsupportedModifier, cosmeticRule
    }

    public struct SkippedRule: Codable, Sendable, Equatable {
        public let line: Int
        public let reason: SkipReason

        public init(line: Int, reason: SkipReason) {
            self.line = line
            self.reason = reason
        }
    }

    public let rulesJSON: String
    public let acceptedCount: Int
    public let ignoredCount: Int
    public let skipped: [SkippedRule]
}

/// A deliberately limited, non-executing ABP/AdGuard hostname converter.
/// Unsupported syntax never becomes a broader rule with modifiers dropped.
public enum FilterListConverter {
    public struct Limits: Sendable {
        public let maximumBytes: Int
        public let maximumLines: Int
        public let maximumLineBytes: Int
        public let maximumRules: Int
        public let maximumOutputBytes: Int

        public init(maximumBytes: Int = 4 * 1024 * 1024, maximumLines: Int = 100_000,
                    maximumLineBytes: Int = 2048, maximumRules: Int = 50_000,
                    maximumOutputBytes: Int = 16 * 1024 * 1024) {
            self.maximumBytes = min(max(1, maximumBytes), 4 * 1024 * 1024)
            self.maximumLines = min(max(1, maximumLines), 100_000)
            self.maximumLineBytes = min(max(1, maximumLineBytes), 2048)
            self.maximumRules = min(max(1, maximumRules), 50_000)
            self.maximumOutputBytes = min(max(1, maximumOutputBytes), 16 * 1024 * 1024)
        }
    }

    public enum ConversionError: Error, LocalizedError, Equatable {
        case inputTooLarge, invalidUTF8, tooManyLines, lineTooLong, tooManyRules
        case outputTooLarge, noSupportedRules, unsupportedDirectives, cancelled

        public var errorDescription: String? {
            switch self {
            case .inputTooLarge: "The filter list exceeds the 4 MB input limit. Choose a smaller list."
            case .invalidUTF8: "The filter list is not UTF-8 text. Choose a UTF-8 export."
            case .tooManyLines: "The filter list has too many lines. Choose a smaller list."
            case .lineTooLong: "The filter list contains an oversized line. Choose another list."
            case .tooManyRules: "The filter list exceeds the 50,000-rule limit. Choose a smaller list."
            case .outputTooLarge: "The converted rules exceed the output limit. Choose a smaller list."
            case .noSupportedRules: "No supported hostname rules were found. Existing rules have not been replaced."
            case .unsupportedDirectives: "This list uses includes or conditional directives, which are not supported. Choose a standalone list."
            case .cancelled: "Filter list conversion was cancelled."
            }
        }
    }

    public static func convert(_ data: Data, limits: Limits = Limits(),
                               isCancelled: () -> Bool = { false }) throws -> FilterListConversion {
        guard !isCancelled() else { throw ConversionError.cancelled }
        guard data.count <= limits.maximumBytes else { throw ConversionError.inputTooLarge }
        guard var text = String(data: data, encoding: .utf8) else { throw ConversionError.invalidUTF8 }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var blocks: [String] = []
        var exceptions: [String] = []
        var seen: Set<HostRule> = []
        var skipped: [FilterListConversion.SkippedRule] = []
        var ignored = 0
        var outputBytes = 2 // JSON array brackets; checked before retaining each rule.
        for (index, rawLine) in text.split(maxSplits: limits.maximumLines, omittingEmptySubsequences: false,
                                          whereSeparator: { $0.isNewline }).enumerated() {
            guard !isCancelled() else { throw ConversionError.cancelled }
            guard index < limits.maximumLines else { throw ConversionError.tooManyLines }
            guard rawLine.utf8.count <= limits.maximumLineBytes else { throw ConversionError.lineTooLong }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            // Includes are never fetched and conditional branches are never guessed.
            guard !line.hasPrefix("!#") else { throw ConversionError.unsupportedDirectives }
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[Adblock Plus") || line.hasPrefix("[AdGuard") {
                ignored += 1
                continue
            }
            switch parse(line) {
            case .failure(let reason):
                skipped.append(.init(line: index + 1, reason: reason))
            case .success(let rule):
                guard seen.insert(rule).inserted else {
                    skipped.append(.init(line: index + 1, reason: .duplicate))
                    continue
                }
                guard seen.count <= limits.maximumRules else { throw ConversionError.tooManyRules }
                let encoded = try encoder.encode(rule.webKitRule)
                outputBytes += encoded.count + (seen.count > 1 ? 1 : 0)
                guard outputBytes <= limits.maximumOutputBytes else { throw ConversionError.outputTooLarge }
                let json = String(decoding: encoded, as: UTF8.self)
                if rule.isException { exceptions.append(json) } else { blocks.append(json) }
            }
        }
        guard !isCancelled() else { throw ConversionError.cancelled }
        guard !seen.isEmpty else { throw ConversionError.noSupportedRules }
        return FilterListConversion(rulesJSON: "[" + (blocks + exceptions).joined(separator: ",") + "]",
                                    acceptedCount: seen.count, ignoredCount: ignored, skipped: skipped)
    }

    private enum ParseResult {
        case success(HostRule)
        case failure(FilterListConversion.SkipReason)
    }

    private struct HostRule: Hashable {
        let host: String
        let isException: Bool
        let resources: [String]

        var webKitRule: Rule {
            // The host is validated ASCII, so only dots need regex escaping.
            // No alternation: one anchored expression per request hostname.
            let escaped = host.replacingOccurrences(of: ".", with: "\\.")
            return Rule(trigger: .init(urlFilter: "^https?://([a-z0-9-]+\\.)*" + escaped + "[:/]",
                                       resourceType: resources.isEmpty ? nil : resources),
                        action: .init(type: isException ? "ignore-previous-rules" : "block"))
        }
    }

    private struct Rule: Encodable {
        struct Trigger: Encodable {
            let urlFilter: String
            let resourceType: [String]?
            enum CodingKeys: String, CodingKey {
                case urlFilter = "url-filter", resourceType = "resource-type"
            }
        }
        struct Action: Encodable { let type: String }
        let trigger: Trigger
        let action: Action
    }

    private static func parse(_ line: String) -> ParseResult {
        if line.contains("##") || line.contains("#@#") || line.contains("#$#") || line.contains("#?#") {
            return .failure(.cosmeticRule)
        }
        if line.hasPrefix("#") { return .failure(.unsupportedPattern) }
        let isException = line.hasPrefix("@@")
        let body = isException ? String(line.dropFirst(2)) : line
        let pieces = body.split(separator: "$", omittingEmptySubsequences: false)
        guard pieces.count <= 2, let pattern = pieces.first,
              pattern.hasPrefix("||"), pattern.hasSuffix("^") else {
            return .failure(.unsupportedPattern)
        }
        let sourceHost = pattern.dropFirst(2).dropLast()
        guard sourceHost.utf8.allSatisfy({ $0 < 128 }) else { return .failure(.invalidDomain) }
        let host = sourceHost.lowercased()
        guard validHost(host) else { return .failure(.invalidDomain) }
        var resources: Set<String> = []
        if pieces.count == 2 {
            for modifier in pieces[1].split(separator: ",", omittingEmptySubsequences: false) {
                let resource: String
                switch modifier {
                case "image": resource = "image"
                case "script": resource = "script"
                case "stylesheet": resource = "style-sheet"
                case "font": resource = "font"
                case "media": resource = "media"
                case "xmlhttprequest": resource = "raw"
                // ABP exception $document disables page-wide filtering, which
                // is not the same as a WebKit request-resource exception.
                case "document" where !isException: resource = "document"
                default: return .failure(.unsupportedModifier)
                }
                resources.insert(resource)
            }
        }
        return .success(.init(host: host, isException: isException, resources: resources.sorted()))
    }

    private static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
}
