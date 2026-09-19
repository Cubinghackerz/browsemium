import BrowsemiumCore
import SwiftUI

@MainActor
struct CommandPaletteView: View {
    @Bindable var model: BrowserWindowModel
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

                TextField("Search commands", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .focused($searchFocused)
                    .onSubmit { runHighlighted() }
                    .accessibilityLabel("Search commands")
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Rectangle()
                .fill(Color.browsemiumBorder)
                .frame(height: 1)

            if results.isEmpty {
                Text("No matching commands")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.browsemiumTertiary)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            PaletteRow(
                                item: item,
                                isHighlighted: index == highlighted
                            ) {
                                model.perform(item.command)
                                model.dismissCommandPalette()
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(width: 460)
        .browsemiumPanel(background: .browsemiumRaised, radius: BrowserMetrics.overlayRadius)
        .onAppear {
            searchFocused = true
            highlighted = 0
        }
        .onChange(of: query) { highlighted = 0 }
        .onExitCommand { model.dismissCommandPalette() }
    }

    private func runHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        model.perform(results[highlighted].command)
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
            HStack(spacing: 10) {
                Text(item.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.browsemiumPrimary)
                Spacer(minLength: 8)
                if !item.shortcut.isEmpty {
                    Text(item.shortcut)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.browsemiumTertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .fill(isHighlighted || isHovering ? Color.browsemiumSelection : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(item.shortcut.isEmpty ? item.title : "\(item.title), \(item.shortcut)")
    }
}
