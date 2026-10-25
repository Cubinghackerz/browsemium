import BrowsemiumCore
import SwiftUI
import BrowsemiumEngineKit

/// How wide the palette is, and whether the tab preview pane fits beside the
/// list. Pure, so the "only when it fits" rule can be tested.
enum PalettePreviewLayout {
    static let listWidth: CGFloat = 480
    /// The preview card sets its own width.
    static let paneWidth: CGFloat = 264
    /// Clear space kept on either side of the palette.
    static let margin: CGFloat = 48
    static let regionHeight: CGFloat = 340

    static func showsPane(hasTabRow: Bool, availableWidth: CGFloat) -> Bool {
        hasTabRow && availableWidth >= listWidth + paneWidth + margin * 2
    }

    static func width(hasTabRow: Bool, availableWidth: CGFloat) -> CGFloat {
        showsPane(hasTabRow: hasTabRow, availableWidth: availableWidth) ? listWidth + paneWidth : listWidth
    }
}

/// ⌘K. One field for tabs, history, bookmarks, commands, and intent actions —
/// all matched locally with fuzzy ranking. The top row is what Return does
/// with the raw input: open it as a URL, or search for it.
@MainActor
struct CommandPaletteView: View {
    @Bindable var model: BrowserWindowModel
    /// The window's width, so the preview pane only appears when it fits.
    var availableWidth: CGFloat = 1_000
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var searchFocused: Bool

    private var results: [BrowserPaletteCommand] {
        model.filteredCommands(query: query)
    }

    var body: some View {
        // Computed once per render: ranking runs history and bookmark queries.
        let results = results
        let hasTabRow = results.contains { if case .selectTab = $0.command { true } else { false } }
        let showsPane = PalettePreviewLayout.showsPane(hasTabRow: hasTabRow, availableWidth: availableWidth)
        let width = PalettePreviewLayout.width(hasTabRow: hasTabRow, availableWidth: availableWidth)

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(BrowserType.font(.small))
                    .foregroundStyle(Color.browsemiumTertiary)
                    .accessibilityHidden(true)

                TextField("Search tabs, history, and commands", text: $query)
                    .textFieldStyle(.plain)
                    .font(BrowserType.font(.body))
                    .focused($searchFocused)
                    .onSubmit { runHighlighted(.plain) }
                    .onKeyPress(.upArrow) {
                        moveHighlight(by: -1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveHighlight(by: 1)
                        return .handled
                    }
                    .accessibilityLabel("Search tabs, history, and commands")
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Rectangle()
                .fill(Color.browsemiumBorder)
                .frame(height: 1)

            if results.isEmpty {
                Text("No matches — press Return to search the web")
                    .font(BrowserType.font(.small))
                    .foregroundStyle(Color.browsemiumTertiary)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 0) {
                    resultList(results, listHeight: showsPane ? PalettePreviewLayout.regionHeight : 300)
                        .frame(width: PalettePreviewLayout.listWidth)
                        .frame(height: showsPane ? PalettePreviewLayout.regionHeight : nil)

                    if showsPane {
                        // An explicit height: a bare Rectangle is greedy and
                        // would stretch the palette to the window.
                        Rectangle()
                            .fill(Color.browsemiumBorder)
                            .frame(width: 1, height: PalettePreviewLayout.regionHeight)
                        PalettePreviewPane(model: model, tab: previewTab(in: results))
                            .frame(width: PalettePreviewLayout.paneWidth, height: PalettePreviewLayout.regionHeight)
                    }
                }
            }

            Rectangle()
                .fill(Color.browsemiumBorder)
                .frame(height: 1)

            keyHints(results)
        }
        .frame(width: width)
        .browsemiumOverlaySurface(radius: BrowserMetrics.overlayRadius, shadowOpacity: 0.24, shadowRadius: 22, shadowY: 8)
        .onAppear {
            searchFocused = true
            highlighted = 0
        }
        .onChange(of: query) { highlighted = 0 }
        .onMoveCommand { direction in
            switch direction {
            case .up: moveHighlight(by: -1)
            case .down: moveHighlight(by: 1)
            default: break
            }
        }
        .onExitCommand { model.dismissCommandPalette() }
    }

    // MARK: Results

    private func resultList(_ results: [BrowserPaletteCommand], listHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        // Group labels only on the idle list; while typing,
                        // ranking mixes kinds and a label per run would
                        // flicker, so each row names its kind.
                        if isIdle, index == 0 || results[index - 1].kind != item.kind {
                            Text(Self.groupTitle(item.kind))
                                .font(BrowserType.font(.caption, weight: .semibold))
                                .foregroundStyle(Color.browsemiumTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.top, index == 0 ? 2 : 8)
                                .padding(.bottom, 2)
                                .accessibilityAddTraits(.isHeader)
                        }
                        row(for: item, isHighlighted: index == highlighted)
                            .id(item.id)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: listHeight)
            .onChange(of: highlighted) {
                guard results.indices.contains(highlighted) else { return }
                withAnimation(BrowserMotion.quick(reduceMotion: reduceMotion)) {
                    proxy.scrollTo(results[highlighted].id, anchor: .center)
                }
            }
        }
    }

    private func row(for item: BrowserPaletteCommand, isHighlighted: Bool) -> some View {
        SuggestionRow(
            title: item.title,
            subtitle: item.subtitle,
            symbol: Self.symbol(for: item.kind),
            favicon: favicon(for: item),
            trailing: trailing(for: item),
            trailingIsMonospaced: item.kind == .command,
            density: .roomy,
            isHighlighted: isHighlighted,
            accessibilityText: Self.accessibilityLabel(for: item)
        ) {
            run(item, modifier: .plain)
        }
    }

    /// A key combination reads best monospaced; a host does not. Rows whose
    /// shortcut is only their host repeat it, so those show the kind instead.
    private func trailing(for item: BrowserPaletteCommand) -> String? {
        if !item.shortcut.isEmpty, item.kind == .command || !item.subtitle.contains(item.shortcut) {
            return item.shortcut
        }
        return isIdle ? nil : Self.kindLabel(item.kind)
    }

    private var isIdle: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func previewTab(in results: [BrowserPaletteCommand]) -> BrowserTab? {
        guard results.indices.contains(highlighted),
              case .selectTab(let id) = results[highlighted].command else { return nil }
        return model.session.tabs.first { $0.id == id }
    }

    // MARK: Key hints

    private func keyHints(_ results: [BrowserPaletteCommand]) -> some View {
        let item = results.indices.contains(highlighted) ? results[highlighted] : nil
        let canNewTab = item.flatMap { action(for: $0, modifier: .newTab) } != nil
        let canSplit = item.flatMap { action(for: $0, modifier: .split) } != nil
        return HStack(spacing: 14) {
            KeyHint(keys: "↩", label: "Open")
            hintButton("⌘↩", "New tab", spoken: "Open in a new tab, Command Return",
                       shortcut: KeyboardShortcut(.return, modifiers: .command),
                       isEnabled: canNewTab, modifier: .newTab)
            hintButton("⇧↩", "Split", spoken: "Open in split view, Shift Return",
                       shortcut: KeyboardShortcut(.return, modifiers: .shift),
                       isEnabled: canSplit, modifier: .split)
            Spacer(minLength: 0)
            Button { model.dismissCommandPalette() } label: {
                KeyHint(keys: "esc", label: "Close")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close the palette, Escape")
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    private func hintButton(_ keys: String, _ label: String, spoken: String, shortcut: KeyboardShortcut,
                            isEnabled: Bool, modifier: PaletteModifier) -> some View {
        // A real button, so the hint is clickable and the key works with the
        // search field focused; it is dimmed when the highlighted row has no
        // meaning for the key.
        Button { runHighlighted(modifier) } label: {
            KeyHint(keys: keys, label: label)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(spoken)
    }

    // MARK: Actions

    private func action(for item: BrowserPaletteCommand, modifier: PaletteModifier) -> PaletteAction? {
        PaletteDispatch.action(for: item, modifier: modifier, context: model.paletteDispatchContext)
    }

    private func moveHighlight(by offset: Int) {
        let count = results.count
        guard count > 0 else { return }
        highlighted = min(max(highlighted + offset, 0), count - 1)
    }

    /// Commands that need the view's environment run here; everything else
    /// goes through the model like any other command.
    private func run(_ command: BrowserCommand) {
        if case .newPrivateWindow = command {
            PrivateWindowRequest.shared.arm()
            openWindow(id: "main")
            return
        }
        model.perform(command)
    }

    private func run(_ item: BrowserPaletteCommand, modifier: PaletteModifier) {
        guard let action = action(for: item, modifier: modifier) else { return }
        switch action {
        case .run(let command): run(command)
        case .openURLInSplit: model.perform(action)
        }
        model.dismissCommandPalette()
    }

    private func runHighlighted(_ modifier: PaletteModifier) {
        let results = results
        guard results.indices.contains(highlighted) else { return }
        run(results[highlighted], modifier: modifier)
    }

    // MARK: Presentation

    private static func groupTitle(_ kind: BrowserPaletteCommand.Kind) -> String {
        switch kind {
        case .tab: "Open tabs"
        case .history: "History"
        case .bookmark: "Bookmarks"
        case .action: "Actions"
        case .command: "Commands"
        case .answer: "Answer"
        case .pageText: "Page text"
        }
    }

    private static func symbol(for kind: BrowserPaletteCommand.Kind) -> String {
        switch kind {
        case .tab: "macwindow"
        case .history: "clock"
        case .bookmark: "bookmark"
        case .action: "wand.and.stars"
        case .command: "command"
        case .answer: "equal.square"
        case .pageText: "doc.text"
        }
    }

    private static func kindLabel(_ kind: BrowserPaletteCommand.Kind) -> String {
        switch kind {
        case .tab: "Tab"
        case .history: "History"
        case .bookmark: "Bookmark"
        case .action: "Action"
        case .command: "Command"
        case .answer: "Answer"
        case .pageText: "Page text"
        }
    }

    private static func accessibilityLabel(for item: BrowserPaletteCommand) -> String {
        var label = item.title
        if !item.subtitle.isEmpty { label += ", \(item.subtitle)" }
        if !item.shortcut.isEmpty { label += ", \(item.shortcut)" }
        return label
    }

    /// The site's own icon for rows that open a page, when it is cached.
    private func favicon(for item: BrowserPaletteCommand) -> NSImage? {
        switch item.command {
        case .selectTab(let id): model.favicons.image(for: model.tabURLs[id])
        case .openURLInNewTab(let url): model.favicons.image(for: url)
        default: nil
        }
    }
}

/// "⌘↩ New tab": the keys set apart from what they do.
private struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(BrowserType.font(.caption, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.browsemiumSecondary)
            Text(label)
                .font(BrowserType.font(.caption))
                .foregroundStyle(Color.browsemiumTertiary)
        }
        .contentShape(Rectangle())
    }
}

/// The right-hand pane: the highlighted open tab's preview card, or a quiet
/// hint when the highlighted row is something else. The card says honestly
/// when a tab is asleep instead of showing a made-up thumbnail.
@MainActor
private struct PalettePreviewPane: View {
    @Bindable var model: BrowserWindowModel
    let tab: BrowserTab?

    var body: some View {
        ScrollView {
            if let tab {
                // A new identity per tab so the snapshot reloads when the
                // highlight moves.
                TabPreviewCard(model: model, tab: tab, stats: model.tabStats(for: tab))
                    .id(tab.id)
            } else {
                Text("Highlight an open tab to preview it.")
                    .font(BrowserType.font(.caption))
                    .foregroundStyle(Color.browsemiumTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            }
        }
        .background(Color.browsemiumRaised)
    }
}
