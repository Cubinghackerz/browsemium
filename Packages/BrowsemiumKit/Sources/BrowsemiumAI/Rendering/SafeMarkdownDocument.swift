import BrowsemiumCore
import Foundation
import Markdown

public struct SafeMarkdownDocument: Sendable {
    public enum Block: Sendable, Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case codeBlock(language: String?, code: String)
        case bulletList([String])
        case orderedList([String])
        case quote(String)
        case rule
    }

    public struct Link: Sendable, Equatable, Hashable {
        public let text: String
        public let url: URL
    }

    public let blocks: [Block]
    public let links: [Link]

    public init(source: String) {
        let document = Document(parsing: source)
        var blocks: [Block] = []
        var links: [Link] = []
        Self.collect(document, blocks: &blocks, links: &links)
        self.blocks = blocks
        self.links = Self.deduplicated(links)
    }

    public var plainText: String {
        blocks.map { block in
            switch block {
            case .heading(_, let text), .paragraph(let text), .quote(let text):
                return text
            case .codeBlock(_, let code):
                return code
            case .bulletList(let items), .orderedList(let items):
                return items.joined(separator: "\n")
            case .rule:
                return ""
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    public static func sanitizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    private static func collect(_ markup: Markup, blocks: inout [Block], links: inout [Link]) {
        for child in markup.children {
            switch child {
            case let heading as Heading:
                blocks.append(.heading(level: heading.level, text: heading.plainText))
                collectLinks(heading, into: &links)
            case let paragraph as Paragraph:
                blocks.append(.paragraph(paragraph.plainText))
                collectLinks(paragraph, into: &links)
            case let codeBlock as CodeBlock:
                blocks.append(.codeBlock(language: codeBlock.language, code: codeBlock.code))
            case let unordered as UnorderedList:
                blocks.append(.bulletList(unordered.listItems.map(text)))
                collectLinks(unordered, into: &links)
            case let ordered as OrderedList:
                blocks.append(.orderedList(ordered.listItems.map(text)))
                collectLinks(ordered, into: &links)
            case let quote as BlockQuote:
                blocks.append(.quote(text(quote)))
                collectLinks(quote, into: &links)
            case is ThematicBreak:
                blocks.append(.rule)
            default:
                collect(child, blocks: &blocks, links: &links)
            }
        }
    }

    private static func collectLinks(_ markup: Markup, into links: inout [Link]) {
        if let link = markup as? Markdown.Link,
           let destination = link.destination,
           let url = sanitizedURL(destination) {
            links.append(Link(text: link.plainText, url: url))
        }
        for child in markup.children {
            collectLinks(child, into: &links)
        }
    }

    private static func text(_ markup: Markup) -> String {
        if let convertible = markup as? any PlainTextConvertibleMarkup {
            return convertible.plainText
        }
        return markup.children.map(text).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func deduplicated(_ links: [Link]) -> [Link] {
        var seen = Set<URL>()
        var result: [Link] = []
        for link in links where !seen.contains(link.url) {
            seen.insert(link.url)
            result.append(link)
        }
        return result
    }
}
