import Foundation

/// A page reduced to readable text by the bundled Readability extractor.
/// Reader mode renders this as text rather than raw HTML, so nothing from the
/// page executes or styles itself inside the reading view.
public struct ReaderArticle: Hashable, Sendable {
    public let title: String
    public let url: URL?
    public let text: String

    public init(title: String, url: URL?, text: String) {
        self.title = title
        self.url = url
        self.text = text
    }

    /// Paragraphs with collapsed whitespace, for typographic rendering.
    public var paragraphs: [String] {
        text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public var estimatedReadingMinutes: Int {
        let words = text.split(whereSeparator: \.isWhitespace).count
        return max(1, Int((Double(words) / 220).rounded(.up)))
    }
}
