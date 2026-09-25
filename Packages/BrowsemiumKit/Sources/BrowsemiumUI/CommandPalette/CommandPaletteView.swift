import BrowsemiumCore
import SwiftUI
import BrowsemiumEngineKit

/// ⌘K. One field for tabs, history, bookmarks, commands, and intent actions —
/// all matched locally with fuzzy ranking. The top row is what Return does
/// with the raw input: open it as a URL, or search for it.
@MainActor
struct CommandPaletteView: View {
    @Bindable var model: BrowserWindowModel
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var searchFocused: Bool

    private var results: [BrowserPaletteCommand] {
        model.filteredCommands(query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.browsemiumTertiary)
                    .accessibilityHidden(true)

                TextField("Search tabs, history, and commands", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .focused($searchFocused)
                    .onSubmit { runHighlighted() }
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
                    .font(.system(size: 12))
                    .foregroundStyle(Color.browsemiumTertiary)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                PaletteRow(
                                    item: item,
                                    isHighlighted: index == highlighted
                                ) {
                                    run(item.command)
                                    model.dismissCommandPalette()
                                }
                                .id(item.id)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 300)
                    .onChange(of: highlighted) {
                        guard results.indices.contains(highlighted) else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(results[highlighted].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 480)
        .browsemiumPanel(background: .browsemiumRaised, radius: BrowserMetrics.overlayRadius)
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

    private func moveHighlight(by offset: Int) {
        guard !results.isEmpty else { return }
        highlighted = min(max(highlighted + offset, 0), results.count - 1)
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

    private func runHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        run(results[highlighted].command)
        model.dismissCommandPalette()
    }
}

@MainActor
private struct PaletteRow: View {
    let item: BrowserPaletteCommand
    let isHighlighted: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: iconName)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.browsemiumTertiary)
                    .frame(width: 14)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.browsemiumPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.browsemiumTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)

                if !item.shortcut.isEmpty {
                    Text(item.shortcut)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.browsemiumTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: item.subtitle.isEmpty ? 30 : 38)
            .background(
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .fill(isHighlighted || isHovering ? Color.browsemiumSelection : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(accessibilityLabel)
    }

    private var iconName: String {
        switch item.kind {
        case .tab: "macwindow"
        case .history: "clock"
        case .bookmark: "bookmark"
        case .action: "wand.and.stars"
        case .command: "command"
        }
    }

    private var accessibilityLabel: String {
        var label = item.title
        if !item.subtitle.isEmpty { label += ", \(item.subtitle)" }
        if !item.shortcut.isEmpty { label += ", \(item.shortcut)" }
        return label
    }
}
