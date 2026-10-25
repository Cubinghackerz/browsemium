import BrowsemiumCore
import SwiftUI

/// Pinned tabs as a three-column grid of icon tiles above the tab list.
@MainActor
struct PinnedTabGrid: View {
    @Bindable var model: BrowserWindowModel
    let tabs: [BrowserTab]

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(Array(PinnedGrid.rows(tabs).enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row) { tab in
                        PinnedTabTile(model: model, tab: tab)
                    }
                    // Short last rows keep their tiles at column width.
                    ForEach(0..<(PinnedGrid.columns - row.count), id: \.self) { _ in
                        Color.clear.frame(height: 1)
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }
}

@MainActor
private struct PinnedTabTile: View {
    @Bindable var model: BrowserWindowModel
    let tab: BrowserTab

    @State private var isHovering = false
    @State private var isDropTargeted = false
    @State private var isNamingFolder = false
    @State private var newFolderName = ""

    private var isActive: Bool { model.session.activeTabID == tab.id }
    private var isAsleep: Bool { tab.lifecycle == .hibernated || tab.lifecycle == .suspended }

    var body: some View {
        Button {
            BrowserHaptics.perform()
            model.selectTab(tab.id)
        } label: {
            TabFaviconView(model: model, tab: tab, size: 20, isActive: isActive)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                        .fill(isActive ? Color.browsemiumSelection : (isHovering ? Color.browsemiumHover : Color.browsemiumField))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                        .stroke(
                            isDropTargeted ? Color.browsemiumFocus
                                : (isActive ? Color.browsemiumBorderStrong : Color.browsemiumBorder),
                            lineWidth: isDropTargeted ? 1.5 : 1
                        )
                }
                .opacity(isAsleep && !isActive ? 0.55 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(tab.title)
        .contextMenu {
            TabMenuContent(model: model, tab: tab, afterLabel: "Close Tabs Below") {
                newFolderName = ""
                isNamingFolder = true
            }
        }
        .onDrag {
            model.beginTabDrag()
            return NSItemProvider(object: tab.id.rawValue.uuidString as NSString)
        }
        .dropDestination(for: String.self, action: { items, _ in
            guard let rawID = items.first, let uuid = UUID(uuidString: rawID) else { return false }
            model.endTabDrag()
            model.moveTab(TabID(rawValue: uuid), before: tab.id)
            return true
        }, isTargeted: { isDropTargeted = $0 })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityLabel: String {
        var label = "Pinned tab, \(tab.title)"
        if isActive { label += ", active" }
        if isAsleep { label += ", sleeping" }
        if tab.lifecycle == .loading { label += ", loading" }
        if tab.lifecycle == .crashed { label += ", stopped responding" }
        return label
    }
}

/// One small colored circle per space, at the foot of the sidebar. A lock or
/// a person glyph marks spaces that ask for authentication or keep their own
/// cookies and logins. Choosing one switches to it.
@MainActor
struct SpaceSwitcherRow: View {
    let items: [SpaceSwitcherItem]
    let choose: (SpaceID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    SpaceDot(item: item) { choose(item.id) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spaces")
    }
}

@MainActor
private struct SpaceDot: View {
    let item: SpaceSwitcherItem
    let action: () -> Void
    @State private var isHovering = false

    private var fill: Color {
        item.colorHex.flatMap { Color(browsemiumHex: $0) } ?? Color.browsemiumTertiary
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(fill)
                    .frame(width: 14, height: 14)
                    .padding(3)
                    .overlay {
                        Circle()
                            .stroke(
                                item.isActive ? Color.browsemiumPrimary : (isHovering ? Color.browsemiumBorderStrong : Color.clear),
                                lineWidth: 1.5
                            )
                    }
                if let glyph = item.glyph {
                    Image(systemName: glyph.symbolName)
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(Color.browsemiumPrimary)
                        .frame(width: 10, height: 10)
                        .background(Circle().fill(Color.browsemiumRaised))
                        .overlay { Circle().stroke(Color.browsemiumBorder, lineWidth: 0.5) }
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(item.name)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityAddTraits(item.isActive ? [.isButton, .isSelected] : .isButton)
    }
}
