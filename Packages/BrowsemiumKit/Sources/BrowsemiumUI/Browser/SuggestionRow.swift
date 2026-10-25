import AppKit
import SwiftUI

/// One result row, shared by the command palette and the address-bar
/// suggestions so both read and behave the same: an icon (the site's own when
/// cached, a symbol otherwise), a title, a quiet second line, a trailing key
/// hint or kind badge, and one highlight treatment.
@MainActor
struct SuggestionRow: View {
    /// The palette is roomier than the dropdown under the address bar.
    enum Density {
        case roomy
        case compact

        var titleStep: BrowserType.Step { self == .roomy ? .body : .small }
        var iconSize: CGFloat { self == .roomy ? 16 : 14 }
        var iconColumn: CGFloat { self == .roomy ? 18 : 16 }
    }

    let title: String
    var subtitle: String = ""
    let symbol: String
    var favicon: NSImage?
    /// A key combination or the row's kind, set in the quiet trailing slot.
    var trailing: String?
    var trailingIsMonospaced = false
    var density: Density = .roomy
    let isHighlighted: Bool
    let accessibilityText: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                icon
                    .frame(width: density.iconColumn)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(BrowserType.font(density.titleStep))
                        .foregroundStyle(Color.browsemiumPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(BrowserType.font(.caption))
                            .foregroundStyle(Color.browsemiumTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)

                if let trailing, !trailing.isEmpty {
                    Text(trailing)
                        .font(BrowserType.font(.caption, design: trailingIsMonospaced ? .monospaced : .default))
                        .foregroundStyle(Color.browsemiumTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, density == .roomy ? 10 : 8)
            .padding(.vertical, density == .roomy ? 0 : 5)
            .frame(height: density == .roomy ? (subtitle.isEmpty ? 30 : 38) : nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .fill(fill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    private var fill: Color {
        if isHighlighted { return .browsemiumSelection }
        return isHovering ? .browsemiumHover : .clear
    }

    @ViewBuilder
    private var icon: some View {
        if let favicon {
            Image(nsImage: favicon)
                .resizable()
                .interpolation(.high)
                .frame(width: density.iconSize, height: density.iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: symbol)
                .font(BrowserType.font(.caption))
                .foregroundStyle(Color.browsemiumTertiary)
        }
    }
}
