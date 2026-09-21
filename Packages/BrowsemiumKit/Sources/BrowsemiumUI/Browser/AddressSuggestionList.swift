import SwiftUI

/// The address-bar suggestion dropdown.
///
/// It is rendered by the browser panel rather than inside the toolbar, because
/// the panel clips its contents — a dropdown drawn inside the toolbar was cut
/// off and ended up behind the bookmarks bar.
@MainActor
struct AddressSuggestionList: View {
    @Bindable var model: BrowserWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.addressSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                AddressSuggestionRow(
                    suggestion: suggestion,
                    isHighlighted: index == model.highlightedSuggestion
                ) {
                    model.acceptSuggestion(suggestion)
                }
            }
        }
        .padding(4)
        .frame(width: 400, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                .fill(Color.browsemiumRaised)
        )
        .overlay {
            RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                .stroke(Color.browsemiumBorderStrong, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Address suggestions")
    }
}

@MainActor
private struct AddressSuggestionRow: View {
    let suggestion: BrowserWindowModel.AddressSuggestion
    let isHighlighted: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.browsemiumTertiary)
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.title)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.browsemiumPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(suggestion.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.browsemiumTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 6)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHighlighted || isHovering ? Color.browsemiumHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(suggestion.title), \(suggestion.subtitle)")
    }

    private var icon: String {
        switch suggestion.kind {
        case .openTab: "arrow.right.square"
        case .history: "clock"
        case .bookmark: "bookmark"
        case .search: "magnifyingglass"
        }
    }
}
