import AppKit
import BrowsemiumCore
import SwiftUI

/// The horizontal tab strip. Pinned tabs collapse to compact squares; regular
/// tabs share the remaining width evenly until they hit the floor, then the
/// strip scrolls — the same behaviour as Safari and Chrome.
@MainActor
struct BrowserTabStrip: View {
    @Bindable var model: BrowserWindowModel

    private var pinnedTabs: [BrowserTab] {
        model.session.tabs.filter(\.isPinned)
    }

    private var regularTabs: [BrowserTab] {
        model.session.tabs.filter { !$0.isPinned }
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 4) {
                Color.clear
                    .frame(width: BrowserMetrics.titlebarLeadingInset, height: 1)

                ForEach(pinnedTabs) { tab in
                    TabItem(model: model, tab: tab, width: 30)
                }

                let regularWidth = width(for: geometry.size.width)

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(regularTabs) { tab in
                                TabItem(model: model, tab: tab, width: regularWidth)
                                    .id(tab.id)
                            }
                        }
                        .padding(.horizontal, 1)
                    }
                    .onChange(of: model.session.activeTabID) {
                        guard let active = model.session.activeTabID else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(active, anchor: .center)
                        }
                    }
                }

                NewTabButton {
                    BrowserHaptics.perform()
                    model.newTab()
                }
            }
            .padding(.trailing, 8)
            .padding(.top, BrowserMetrics.tabStripTopInset)
        }
        .frame(height: BrowserMetrics.tabStripHeight)
        .background(WindowDragView())
    }

    private func width(for available: CGFloat) -> CGFloat {
        let reserved = BrowserMetrics.titlebarLeadingInset + CGFloat(pinnedTabs.count) * 34 + 48
        let usable = max(available - reserved, 60)
        let count = max(regularTabs.count, 1)
        let even = usable / CGFloat(count) - 4
        return min(BrowserMetrics.tabWidth, max(BrowserMetrics.tabMinimumWidth, even))
    }
}

@MainActor
private struct NewTabButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovering ? Color.browsemiumPrimary : Color.browsemiumSecondary)
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                        .fill(isHovering ? Color.browsemiumSelection : Color.browsemiumField)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                        .stroke(Color.browsemiumBorder, lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("New tab")
        .help("New Tab (⌘T)")
    }
}

@MainActor
private struct TabItem: View {
    @Bindable var model: BrowserWindowModel
    let tab: BrowserTab
    let width: CGFloat

    @State private var isHovering = false
    @State private var isShowingStats = false
    @State private var hoverTask: Task<Void, Never>?

    private var isActive: Bool {
        model.session.activeTabID == tab.id
    }

    private var isAsleep: Bool {
        tab.lifecycle == .hibernated || tab.lifecycle == .suspended
    }

    private var isCompact: Bool {
        width <= 40
    }

    var body: some View {
        HStack(spacing: 6) {
            icon

            if !isCompact {
                Text(tab.title)
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? Color.browsemiumPrimary : Color.browsemiumSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 2)

                trailing
            }
        }
        .padding(.horizontal, isCompact ? 0 : 9)
        .frame(width: width, height: 28)
        .background(
            RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                .fill(isActive ? Color.browsemiumSelection : (isHovering ? Color.browsemiumHover : Color.clear))
        )
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .stroke(Color.browsemiumBorder, lineWidth: 1)
            }
        }
        .opacity(isAsleep && !isActive ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            BrowserHaptics.perform()
            model.selectTab(tab.id)
        }
        .onHover { hovering in
            isHovering = hovering
            hoverTask?.cancel()
            guard hovering else {
                isShowingStats = false
                return
            }
            // Small delay so brushing past tabs does not flash a card.
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, isHovering else { return }
                isShowingStats = true
            }
        }
        .popover(isPresented: $isShowingStats, arrowEdge: .bottom) {
            TabStatsCard(tab: tab, stats: model.tabStats(for: tab))
        }
        .contextMenu {
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { model.togglePin(tab.id) }
            Divider()
            Button("Close Tab") { model.closeTab(tab.id) }
        }
        .draggable(tab.id.rawValue.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let rawID = items.first,
                  let uuid = UUID(uuidString: rawID) else { return false }
            model.moveTab(TabID(rawValue: uuid), before: tab.id)
            return true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .transition(.opacity)
    }

    @ViewBuilder
    private var trailing: some View {
        if isHovering {
            Button {
                BrowserHaptics.perform()
                model.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.browsemiumTertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(tab.title)")
        } else if let audio = model.tabAudio[tab.id] {
            // Speaker shows while a page is audible; clicking mutes the tab.
            Button {
                BrowserHaptics.perform()
                model.toggleTabMute(tab.id)
            } label: {
                Image(systemName: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(audio.isMuted ? Color.browsemiumTertiary : Color.browsemiumSecondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(audio.isMuted ? "Unmute \(tab.title)" : "Mute \(tab.title)")
        } else {
            Color.clear.frame(width: 16, height: 16)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if tab.lifecycle == .loading {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
                .frame(width: 14, height: 14)
        } else if let favicon = model.favicons.image(for: tab.lastCommittedURL) {
            Image(nsImage: favicon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else if tab.lifecycle == .crashed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.browsemiumWarning)
                .frame(width: 14, height: 14)
        } else {
            monogram
        }
    }

    @ViewBuilder
    private var monogram: some View {
        if let letter = tab.lastCommittedURL?.host?.first.map({ String($0).uppercased() }) {
            Text(letter)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isActive ? Color.browsemiumPrimary : Color.browsemiumTertiary)
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "sparkle")
                .font(.system(size: 10))
                .foregroundStyle(Color.browsemiumTertiary)
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
        }
    }

    private var accessibilityLabel: String {
        var label = "Tab, \(tab.title)"
        if tab.isPinned { label += ", pinned" }
        if isActive { label += ", active" }
        if isAsleep { label += ", sleeping" }
        if tab.lifecycle == .loading { label += ", loading" }
        if tab.lifecycle == .crashed { label += ", stopped responding" }
        if let audio = model.tabAudio[tab.id] {
            label += audio.isMuted ? ", muted" : ", playing audio"
        }
        return label
    }
}
