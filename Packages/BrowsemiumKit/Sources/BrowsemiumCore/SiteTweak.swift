import Foundation

/// A person's own CSS for one site, applied at document start. Cosmetic
/// only: it can restyle or hide what the page already shows, and it cannot
/// make the page request anything (see `SiteTweakValidator`).
public struct SiteTweak: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let host: String
    public var name: String
    public var css: String
    public var isEnabled: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        host: String,
        name: String,
        css: String,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.host = host.lowercased()
        self.name = name
        self.css = css
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum SiteTweakProblem: Error, Equatable, Sendable {
    case empty
    case tooLarge(limit: Int)
    case remoteLoad(String)
    case nameTooLong

    public var message: String {
        switch self {
        case .empty: "Write some CSS first."
        case .tooLarge(let limit): "That is too long. Tweaks are limited to \(limit / 1024) KB."
        case .remoteLoad(let what): "Tweaks cannot load anything from the network, so “\(what)” is not allowed. Use a data: address if you need an inline image."
        case .nameTooLong: "That name is too long."
        }
    }
}

/// Keeps a tweak from becoming a way for a page, an import or an AI's output
/// to phone home. CSS can request resources through `url()`, `@import`,
/// `image-set()` and `src()`, and an attribute selector plus a request is
/// enough to leak page data one character at a time. So any of them pointing
/// anywhere but a `data:` URL is refused.
///
/// CSS lets a token be spelled with escapes (`u\72l(` is `url(`), and
/// comments can hide text. The scan therefore runs on a normalised copy:
/// comments removed, escapes decoded, case folded.
public enum SiteTweakValidator {
    public static let maximumBytes = 32 * 1024
    public static let maximumNameLength = 60

    public static func validate(css: String) -> Result<String, SiteTweakProblem> {
        let trimmed = css.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.utf8.count <= maximumBytes else { return .failure(.tooLarge(limit: maximumBytes)) }
        let normalised = normalise(trimmed)
        if let problem = remoteLoad(in: normalised) { return .failure(.remoteLoad(problem)) }
        return .success(trimmed)
    }

    public static func validate(name: String) -> Result<String, SiteTweakProblem> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= maximumNameLength else { return .failure(.nameTooLong) }
        return .success(trimmed.isEmpty ? "Tweak" : trimmed)
    }

    /// Comments stripped, escapes decoded, lowercase. Public so the tests
    /// can pin its behaviour.
    public static func normalise(_ css: String) -> String {
        decodeEscapes(stripComments(css)).lowercased()
    }

    static func stripComments(_ css: String) -> String {
        var result = ""
        var index = css.startIndex
        while index < css.endIndex {
            if css[index...].hasPrefix("/*") {
                if let end = css.range(of: "*/", range: css.index(index, offsetBy: 2)..<css.endIndex) {
                    index = end.upperBound
                } else {
                    break // unterminated comment swallows the rest, as CSS does
                }
            } else {
                result.append(css[index])
                index = css.index(after: index)
            }
        }
        return result
    }

    /// CSS escapes: a backslash plus 1-6 hex digits (and one optional
    /// whitespace), or a backslash plus any other character, which stands for
    /// that character. A backslash-newline inside a string is a line join.
    static func decodeEscapes(_ css: String) -> String {
        var result = ""
        var iterator = Array(css)
        var index = 0
        while index < iterator.count {
            let character = iterator[index]
            guard character == "\\" else {
                result.append(character)
                index += 1
                continue
            }
            index += 1
            guard index < iterator.count else { break }
            var hex = ""
            while index < iterator.count, hex.count < 6, iterator[index].isHexDigit {
                hex.append(iterator[index])
                index += 1
            }
            if !hex.isEmpty {
                if index < iterator.count, iterator[index].isWhitespace { index += 1 }
                if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value), value != 0 {
                    result.append(Character(scalar))
                } else {
                    result.append("\u{FFFD}")
                }
            } else if iterator[index].isNewline {
                index += 1
            } else {
                result.append(iterator[index])
                index += 1
            }
        }
        iterator.removeAll()
        return result
    }

    /// The first construct that could load a resource from anywhere other
    /// than a `data:` URL, if there is one.
    static func remoteLoad(in normalised: String) -> String? {
        if normalised.contains("@import") { return "@import" }
        if normalised.contains("@namespace") && normalised.contains("url") { return "@namespace url()" }
        for function in ["image-set(", "-webkit-image-set(", "src(", "cross-fade(", "-webkit-cross-fade("] where normalised.contains(function) {
            return function.hasSuffix("(") ? String(function.dropLast()) + "()" : function
        }
        // Every url( must be followed by a data: address.
        var search = normalised.startIndex
        while let range = normalised.range(of: "url(", range: search..<normalised.endIndex) {
            var rest = normalised[range.upperBound...]
            rest = rest.drop(while: { $0.isWhitespace })
            rest = rest.drop(while: { $0 == "\"" || $0 == "'" })
            rest = rest.drop(while: { $0.isWhitespace })
            if !rest.hasPrefix("data:") { return "url()" }
            search = range.upperBound
        }
        return nil
    }
}
