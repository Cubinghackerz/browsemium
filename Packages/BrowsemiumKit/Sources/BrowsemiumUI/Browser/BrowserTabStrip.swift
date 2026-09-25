import AppKit
import BrowsemiumCore
import SwiftUI
import BrowsemiumEngineKit

/// The horizontal tab strip. Pinned tabs collapse to compact squares; regular
/// tabs share the remaining width evenly until they hit the floor, then the
/// strip scrolls — the same behaviour as Safari and Chrome.
@MainActor
struct BrowserTabStrip: View {
    @Bindable var model: BrowserWindowModel
    @State private var isNamingGroup = false
    @State private var newGroupName = ""
    @State private var isRenamingGroup = false
    @State private var groupRenameText = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pinnedTabs: [BrowserTab] {
        model.visibleTabs.filter(\.isPinned)
    }

    private var regularTabs: [BrowserTab] {
        model.visibleTabs.filter { !$0.isPinned }
    }

    /// The regular-tab run flattened for the strip: a collapsed folder is one
    /// chip; an expanded folder renders its members as ordinary tabs (with a
    /// folder badge) directly after the chip-less run.
    private enum StripEntry: Identifiable {
        case collapsedFolder(TabFolder, count: Int)
        case tab(BrowserTab, inFolder: Bool)

        var id: String {
            switch self {
            case .collapsedFolder(let folder, _): "folder-\(folder.id.rawValue.uuidString)"
            case .tab(let tab, _): tab.id.rawValue.uuidString
            }
        }
    }

    private var stripEntries: [StripEntry] {
        var entries: [StripEntry] = []
        var lastFolderID: FolderID?
        for tab in regularTabs {
            guard let folderID = tab.folderID, let folder = model.folder(folderID) else {
                entries.append(.tab(tab, inFolder: false))
                lastFolderID = nil
                continue
            }
            if lastFolderID != folderID {
                if folder.isCollapsed {
                    entries.append(.collapsedFolder(folder, count: model.tabs(inFolder: folderID).count))
                }
                lastFolderID = folderID
            }
            if !folder.isCollapsed {
                entries.append(.tab(tab, inFolder: true))
            }
        }
        return entries
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 4) {
                Color.clear
                    .frame(width: BrowserMetrics.titlebarLeadingInset, height: 1)

                groupPicker

                ForEach(pinnedTabs) { tab in
                    TabItem(model: model, tab: tab, width: 30, inFolder: false)
                }

                let regularWidth = width(for: geometry.size.width)

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(stripEntries) { entry in
                                switch entry {
                                case .collapsedFolder(let folder, let count):
                                    FolderChip(model: model, folder: folder, count: count)
                                case .tab(let tab, let inFolder):
                                    TabItem(model: model, tab: tab, width: regularWidth, inFolder: inFolder)
                                        .id(tab.id)
                                }
                            }
                        }
                        .padding(.horizontal, 1)
                    }
                    .onChange(of: model.session.activeTabID) {
                        guard let active = model.session.activeTabID else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
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
        .alert("New Tab Group", isPresented: $isNamingGroup) {
            TextField("Name", text: $newGroupName)
            Button("Create") {
                let name = newGroupName
                newGroupName = ""
                model.createGroup(named: name.isEmpty ? "Group \(model.session.spaces.count)" : name)
            }
            Button("Cancel", role: .cancel) { newGroupName = "" }
        } message: {
            Text("Groups keep related tabs together and switch as a set.")
        }
        .alert("Rename Group", isPresented: $isRenamingGroup) {
            TextField("Name", text: $groupRenameText)
            Button("Rename") {
                if let id = model.activeGroup?.id {
                    model.renameGroup(id, to: groupRenameText)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Safari-style tab group picker at the head of the strip.
    private var groupPicker: some View {
        Menu {
            ForEach(model.session.spaces) { space in
                Button {
                    model.switchGroup(space.id)
                } label: {
                    if space.id == model.session.activeSpaceID {
                        Label(space.name, systemImage: "checkmark")
                    } else if space.isLocked {
                        Label(space.name, systemImage: "lock.fill")
                    } else {
                        Text(space.name)
                    }
                }
            }
            Divider()
            Button("New Group…") {
                newGroupName = ""
                isNamingGroup = true
            }
            if model.session.spaces.count > 1, let group = model.activeGroup {
                Button("Rename “\(group.name)”…") {
                    groupRenameText = group.name
                    isRenamingGroup = true
                }
                Button("Delete “\(group.name)”", role: .destructive) {
                    model.deleteGroup(group.id)
                }
                Divider()
                if group.isLocked {
                    if model.isSpaceUnlocked(group.id) {
                        Button("Lock “\(group.name)” Now") { model.lockSpaceNow(group.id) }
                    }
                    Button("Remove Lock from “\(group.name)”") {
                        model.setSpaceLocked(group.id, locked: false)
                    }
                } else {
                    Button("Lock “\(group.name)”…") {
                        model.setSpaceLocked(group.id, locked: true)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(groupColor)
                    .frame(width: 7, height: 7)
                Text(model.activeGroup?.name ?? "Tabs")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.browsemiumSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 6.5, weight: .semibold))
                    .foregroundStyle(Color.browsemiumTertiary)
            }
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(
                Capsule().fill(Color.browsemiumField)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Tab groups — switch, create, or manage groups")
        .accessibilityLabel("Tab group, \(model.activeGroup?.name ?? "Tabs")")
    }

    private var groupColor: Color {
        guard let hex = model.activeGroup?.color else {
            return Color.browsemiumTertiary
        }
        return Color(browsemiumHex: hex) ?? Color.browsemiumTertiary
    }

    private func width(for available: CGFloat) -> CGFloat {
        let collapsedFolders = stripEntries.count { entry in
            if case .collapsedFolder = entry { return true }
            return false
        }
        let visibleTabs = stripEntries.count - collapsedFolders
        let reserved = BrowserMetrics.titlebarLeadingInset + CGFloat(pinnedTabs.count) * 34
            + CGFloat(collapsedFolders) * 114 + 48 + 90
        let usable = max(available - reserved, 60)
        let count = max(visibleTabs, 1)
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
    /// Members of an expanded folder get a small folder glyph.
    let inFolder: Bool

    @State private var isHovering = false
    @State private var isShowingStats = false
    @State private var isNamingFolder = false
    @State private var newFolderName = ""
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
            if inFolder, !isCompact {
                Image(systemName: "folder")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(Color.browsemiumTertiary)
                    .frame(width: 8)
                    .accessibilityHidden(true)
            }

            icon

            if model.isTabInSplit(tab.id), !isCompact {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.browsemiumFocus)
                    .accessibilityHidden(true)
            }

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
            TabPreviewCard(model: model, tab: tab, stats: model.tabStats(for: tab))
        }
        .contextMenu {
            TabMenuContent(model: model, tab: tab, afterLabel: "Close Tabs to the Right") {
                newFolderName = ""
                isNamingFolder = true
            }
        }
        .alert("Move to New Folder", isPresented: $isNamingFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName
                newFolderName = ""
                let folderID = model.createFolder(named: name.isEmpty ? "New Folder" : name)
                model.assignTab(tab.id, toFolder: folderID)
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .onDrag {
            model.beginTabDrag()
            return NSItemProvider(object: tab.id.rawValue.uuidString as NSString)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let rawID = items.first,
                  let uuid = UUID(uuidString: rawID) else { return false }
            model.endTabDrag()
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
        if let folderID = tab.folderID, let folder = model.folder(folderID) {
            label += ", in folder \(folder.name)"
        }
        if isActive { label += ", active" }
        if model.isTabInSplit(tab.id) { label += ", in split view" }
        if isAsleep { label += ", sleeping" }
        if tab.lifecycle == .loading { label += ", loading" }
        if tab.lifecycle == .crashed { label += ", stopped responding" }
        if let audio = model.tabAudio[tab.id] {
            label += audio.isMuted ? ", muted" : ", playing audio"
        }
        return label
    }
}

/// A collapsed folder in the top strip: one chip standing in for all of its
/// tabs. Clicking expands it; dragging a tab onto it files the tab.
@MainActor
private struct FolderChip: View {
    @Bindable var model: BrowserWindowModel
    let folder: TabFolder
    let count: Int

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var renameText = ""

    private var accent: Color {
        folder.color.flatMap { Color(browsemiumHex: $0) } ?? Color.browsemiumSecondary
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder.fill")
                .font(.system(size: 9))
                .foregroundStyle(accent)
            Text(folder.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.browsemiumSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("\(count)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.browsemiumTertiary)
                .monospacedDigit()
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.browsemiumField))
        }
        .padding(.horizontal, 8)
        .frame(width: 110, height: 28)
        .background(
            RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                .fill(isHovering ? Color.browsemiumHover : Color.browsemiumField)
        )
        .overlay {
            RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                .stroke(Color.browsemiumBorder, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            BrowserHaptics.perform()
            model.toggleFolderCollapsed(folder.id)
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Expand Folder") { model.toggleFolderCollapsed(folder.id) }
            Button("Rename…") {
                renameText = folder.name
                isRenaming = true
            }
            Divider()
            Button("Ungroup Folder") { model.ungroupFolder(folder.id) }
            Button("Close Folder", role: .destructive) { model.closeFolder(folder.id) }
        }
        .alert("Rename Folder", isPresented: $isRenaming) {
            TextField("Name", text: $renameText)
            Button("Rename") { model.renameFolder(folder.id, to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .draggable(folder.id.rawValue.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let rawID = items.first,
                  let uuid = UUID(uuidString: rawID) else { return false }
            model.assignTab(TabID(rawValue: uuid), toFolder: folder.id)
            return true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Folder, \(folder.name), \(count) tabs, collapsed")
        .accessibilityAddTraits(.isButton)
        .transition(.opacity)
    }
}
