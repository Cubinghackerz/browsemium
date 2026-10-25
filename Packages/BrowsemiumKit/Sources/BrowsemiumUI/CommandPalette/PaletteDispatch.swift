import BrowsemiumCore
import AppKit
import Foundation

/// Which key was held with Return in the palette.
enum PaletteModifier: Equatable {
    case plain
    /// ⌘↩
    case newTab
    /// ⇧↩
    case split
}

/// What the palette will do, decided without touching the model so it can be
/// tested and so a hint is only offered when its key does something.
enum PaletteAction: Equatable {
    case run(BrowserCommand)
    /// The page opens in a fresh tab with the tab you were on tiled beside it.
    case openURLInSplit(URL)
}

/// What the model knows that the policy needs, as closures so tests can pass
/// a fixed answer.
struct PaletteDispatchContext {
    var tabURL: (TabID) -> URL?
    var isInActiveSpace: (TabID) -> Bool
}

enum PaletteDispatch {
    /// `nil` means the row has no meaning for that key, so the hint is dimmed
    /// and the key does nothing.
    static func action(for item: BrowserPaletteCommand, modifier: PaletteModifier,
                       context: PaletteDispatchContext) -> PaletteAction? {
        switch (modifier, item.command) {
        case (.plain, let command):
            return .run(command)

        case (.newTab, .selectTab(let id)):
            // Return switches to an open tab; ⌘↩ opens its page again instead.
            guard let url = context.tabURL(id) else { return nil }
            return .run(.openURLInNewTab(url))
        case (.newTab, .openURLInNewTab), (.newTab, .searchFor):
            return .run(item.command)

        case (.split, .selectTab(let id)), (.split, .openTabInSplit(let id)):
            // A tab from another space cannot be tiled into this window.
            guard context.isInActiveSpace(id) else { return nil }
            return .run(.openTabInSplit(id))
        case (.split, .openURLInNewTab(let url)):
            return .openURLInSplit(url)

        default:
            return nil
        }
    }
}

/// The first row while typing a sum or a unit conversion. Computed locally;
/// Return copies the answer and leaves the page alone.
enum PaletteAnswer {
    static func row(for query: String) -> BrowserPaletteCommand? {
        guard let quick = QuickAnswer.evaluate(query) else { return nil }
        return BrowserPaletteCommand(
            id: "answer-\(query)", title: "= \(quick.text)", shortcut: "↵", kind: .answer,
            subtitle: "\(quick.kind) — press Return to copy", command: .copyText(quick.text)
        )
    }
}

extension BrowserWindowModel {
    func perform(_ action: PaletteAction) {
        switch action {
        case .run(let command):
            perform(command)
        case .openURLInSplit(let url):
            let previous = session.activeTabID
            let fresh = newTab(url: url)
            if let previous, previous != fresh { openInSplitView(previous) }
        }
    }

    func copyTextToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Copied \(text)"
    }

    var paletteDispatchContext: PaletteDispatchContext {
        PaletteDispatchContext(
            tabURL: { [self] id in tabURLs[id] ?? session.tabs.first { $0.id == id }?.lastCommittedURL },
            isInActiveSpace: { [self] id in session.tabs.first { $0.id == id }?.spaceID == session.activeSpaceID }
        )
    }
}
