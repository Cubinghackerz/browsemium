import BrowsemiumCore
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
                SuggestionRow(
                    title: suggestion.title,
                    subtitle: suggestion.subtitle,
                    symbol: Self.symbol(for: suggestion.kind),
                    favicon: favicon(for: suggestion),
                    trailing: Self.badge(for: suggestion.kind),
                    density: .compact,
                    isHighlighted: index == model.highlightedSuggestion,
                    accessibilityText: "\(suggestion.title), \(suggestion.subtitle)"
                ) {
                    model.acceptSuggestion(suggestion)
                }
            }
        }
        .padding(4)
        .frame(width: 400, alignment: .leading)
        .browsemiumOverlaySurface(radius: BrowserMetrics.controlRadius, strongBorder: true, shadowOpacity: 0.22)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Address suggestions")
    }

    /// The site's own icon when it is already cached; nothing is fetched here.
    private func favicon(for suggestion: BrowserWindowModel.AddressSuggestion) -> NSImage? {
        switch suggestion.kind {
        case .history, .bookmark, .pageText:
            return model.favicons.image(for: URL(string: suggestion.value))
        case .openTab:
            guard let uuid = UUID(uuidString: suggestion.value) else { return nil }
            return model.favicons.image(for: model.tabURLs[TabID(rawValue: uuid)])
        case .search, .answer:
            return nil
        }
    }

    static func symbol(for kind: BrowserWindowModel.AddressSuggestion.Kind) -> String {
        switch kind {
        case .openTab: "arrow.right.square"
        case .history: "clock"
        case .bookmark: "bookmark"
        case .search: "magnifyingglass"
        case .answer: "equal.square"
        case .pageText: "doc.text"
        }
    }

    static func badge(for kind: BrowserWindowModel.AddressSuggestion.Kind) -> String? {
        switch kind {
        case .openTab: "Tab"
        case .history: "History"
        case .bookmark: "Bookmark"
        case .pageText: "Page text"
        case .search, .answer: nil
        }
    }
}
