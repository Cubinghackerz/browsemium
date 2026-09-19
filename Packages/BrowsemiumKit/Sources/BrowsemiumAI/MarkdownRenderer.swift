import BrowsemiumCore
import Markdown

public struct AIMarkdownDocument: Sendable {
    public let source: String

    public init(source: String) {
        self.source = source
    }

    public var plainText: String {
        Document(parsing: source).format()
    }
}
