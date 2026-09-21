import BrowsemiumCore
import Foundation
import Markdown

public struct SafeMarkdownDocument: Sendable {
    /// A run of inline content inside a block. Styling stays semantic —
    /// the view decides how strong, emphasis, code, and links look — and a
    /// link only survives if its destination passed sanitization.
    public enum Inline: Sendable, Equatable {
        case text(String)
        case strong([Inline])
        case emphasis([Inline])
        case strikethrough([Inline])
        case code(String)
        case link([Inline], URL)
        case lineBreak
    }

    public enum Block: Sendable, Equatable {
        case heading(level: Int, text: [Inline])
        case paragraph([Inline])
        case codeBlock(language: String?, code: String)
        case bulletList([[Inline]])
        case orderedList([[Inline]])
        case quote([Inline])
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
            case .heading(_, let inlines), .paragraph(let inlines), .quote(let inlines):
                return Self.plainText(inlines)
            case .codeBlock(_, let code):
                return code
            case .bulletList(let items), .orderedList(let items):
                return items.map { Self.plainText($0) }.joined(separator: "\n")
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
                blocks.append(.heading(level: heading.level, text: inlines(heading)))
                collectLinks(heading, into: &links)
            case let paragraph as Paragraph:
                blocks.append(.paragraph(inlines(paragraph)))
                collectLinks(paragraph, into: &links)
            case let codeBlock as CodeBlock:
                blocks.append(.codeBlock(language: codeBlock.language, code: codeBlock.code))
            case let unordered as UnorderedList:
                blocks.append(.bulletList(unordered.listItems.map(inlines)))
                collectLinks(unordered, into: &links)
            case let ordered as OrderedList:
                blocks.append(.orderedList(ordered.listItems.map(inlines)))
                collectLinks(ordered, into: &links)
            case let quote as BlockQuote:
                blocks.append(.quote(inlines(quote)))
                collectLinks(quote, into: &links)
            case is ThematicBreak:
                blocks.append(.rule)
            default:
                collect(child, blocks: &blocks, links: &links)
            }
        }
    }

    /// Walks inline markup into runs, preserving structure the old plain-text
    /// flattening dropped. Anything unrecognized falls through to its
    /// children, so odd markup degrades to readable text rather than vanishing.
    private static func inlines(_ markup: Markup) -> [Inline] {
        var result: [Inline] = []
        for child in markup.children {
            switch child {
            case let text as Markdown.Text:
                result.append(.text(text.string))
            case let strong as Strong:
                result.append(.strong(inlines(strong)))
            case let emphasis as Emphasis:
                result.append(.emphasis(inlines(emphasis)))
            case let strike as Strikethrough:
                result.append(.strikethrough(inlines(strike)))
            case let code as InlineCode:
                result.append(.code(code.code))
            case let link as Markdown.Link:
                if let destination = link.destination, let url = sanitizedURL(destination) {
                    result.append(.link(inlines(link), url))
                } else {
                    // A link we cannot trust keeps its text but loses the URL.
                    result.append(contentsOf: inlines(link))
                }
            case is SoftBreak:
                result.append(.text(" "))
            case is LineBreak:
                result.append(.lineBreak)
            case let html as InlineHTML:
                result.append(.text(html.rawHTML))
            case let image as Markdown.Image:
                result.append(.text(image.plainText))
            default:
                result.append(contentsOf: inlines(child))
            }
        }
        return result
    }

    private static func plainText(_ inlines: [Inline]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let string):
                return string
            case .strong(let inner), .emphasis(let inner), .strikethrough(let inner):
                return plainText(inner)
            case .code(let code):
                return code
            case .link(let inner, _):
                return plainText(inner)
            case .lineBreak:
                return "\n"
            }
        }.joined()
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
