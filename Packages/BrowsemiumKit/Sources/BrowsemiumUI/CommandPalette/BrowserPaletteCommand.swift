import BrowsemiumCore

public struct BrowserPaletteCommand: Identifiable, Hashable, Sendable {
    /// What a row is, so the palette can show the right icon.
    public enum Kind: String, Sendable, Hashable {
        case tab, history, bookmark, action, command
    }

    public let id: String
    public let title: String
    public let shortcut: String
    public let kind: Kind
    /// Secondary line: a host for pages, a context hint for actions.
    public let subtitle: String
    public let command: BrowserCommand

    public init(id: String, title: String, shortcut: String, kind: Kind = .command,
                subtitle: String = "", command: BrowserCommand) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
        self.kind = kind
        self.subtitle = subtitle
        self.command = command
    }
}
