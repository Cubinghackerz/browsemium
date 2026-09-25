import BrowsemiumCore
import SwiftUI
import BrowsemiumEngineKit

/// One tile of the split view. The focused pane carries a thin accent bar;
/// secondary panes carry a close button that collapses their side without
/// closing the tab.
@MainActor
struct SplitPaneView: View {
    @Bindable var model: BrowserWindowModel
    let pane: PaneID
    let tab: BrowserTab
    let isPrimary: Bool

    private var isFocused: Bool { model.activePaneID == pane }

    var body: some View {
        VStack(spacing: 0) {
            // The title sits above the page, not over it. A SwiftUI overlay on
            // the web view eats clicks that were meant for the page.
            paneHeader

            WebViewHost(
                engine: model.environment.engine,
                tabID: tab.id,
                isPrivate: model.session.isPrivate,
                onFocus: { model.focusPane(pane) }
            )
            .onAppear { model.ensureLoaded(tab.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(tab.title), split pane\(isFocused ? ", focused" : "")")
    }

    private var paneHeader: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isFocused ? Color.browsemiumFocus : Color.browsemiumBorder)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(isFocused ? Color.browsemiumFocus : Color.browsemiumTertiary)
                .accessibilityHidden(true)
            Text(tab.title)
                .font(.system(size: 11))
                .foregroundStyle(isFocused ? Color.browsemiumPrimary : Color.browsemiumSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if !isPrimary {
                Button {
                    BrowserHaptics.perform()
                    model.closeSplitPane(pane)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.browsemiumSecondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close this split pane")
                .accessibilityLabel("Close split pane showing \(tab.title)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(isFocused ? Color.browsemiumSelection.opacity(0.65) : Color.browsemiumCanvas.opacity(0.4))
        .contentShape(Rectangle())
        .onTapGesture { model.focusPane(pane) }
    }
}
