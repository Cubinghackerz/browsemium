import AppKit
import BrowsemiumCore
import SwiftUI
import BrowsemiumEngineKit

/// The vertical tab list — the Arc/Zen/Nook layout. It replaces the top strip
/// when Settings → General → Tab layout is "Sidebar", keeping full titles
/// readable and scaling to many tabs without shrinking them.
///
/// The sidebar owns the space picker: groups are the organizing unit of a
/// vertical list, so switching spaces lives where the tabs are.
@MainActor
struct TabSidebar: View {
    @Bindable var model: BrowserWindowModel
    @State private var isNamingGroup = false
    @State private var newGroupName = ""
    @State private var isRenamingGroup = false
    @State private var groupRenameText = ""
    @State private var isNamingFolder = false
    @State private var newFolderName = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pinnedTabs: [BrowserTab] {
        model.visibleTabs.filter(\.isPinned)
    }

    private var regularTabs: [BrowserTab] {
        model.visibleTabs.filter { !$0.isPinned }
    }

    /// The regular-tab list flattened for rendering: folder headers appear
    /// before their first member, members are indented, and a collapsed
    /// folder hides its members behind the header.
    private enum SidebarEntry: Identifiable {
        case folderHeader(TabFolder, count: Int)
        case tab(BrowserTab, indent: Bool)

        var id: String {
            switch self {
            case .folderHeader(let folder, _): "folder-\(folder.id.rawValue.uuidString)"
            case .tab(let tab, _): tab.id.rawValue.uuidString
            }
        }
    }

    private var sidebarEntries: [SidebarEntry] {
        var entries: [SidebarEntry] = []
        var lastFolderID: FolderID?
        for tab in regularTabs {
            guard let folderID = tab.folderID, let folder = model.folder(folderID) else {
                entries.append(.tab(tab, indent: false))
                lastFolderID = nil
                continue
            }
            if lastFolderID != folderID {
                entries.append(.folderHeader(folder, count: model.tabs(inFolder: folderID).count))
            }
            lastFolderID = folderID
            if !folder.isCollapsed {
                entries.append(.tab(tab, indent: true))
            }
        }
        return entries
    }

    var body: some View {
        VStack(spacing: 0) {
            // The traffic lights overlay the sidebar's top corner, so the
            // leading inset's height is reserved as pure window-drag space.
            WindowDragView()
                .frame(height: BrowserMetrics.sidebarTrafficLightInset)

            header

            Rectangle()
                .fill(Color.browsemiumBorder)
                .frame(height: 1)
                .padding(.horizontal, 10)
                .padding(.top, 8)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        if !pinnedTabs.isEmpty {
                            sectionLabel("Pinned")
                            ForEach(pinnedTabs) { tab in
                                SidebarTabRow(model: model, tab: tab, indent: false)
                            }
                        }

                        if !regularTabs.isEmpty {
                            if !pinnedTabs.isEmpty {
                                sectionLabel("Tabs")
                            }
                            ForEach(sidebarEntries) { entry in
                                switch entry {
                                case .folderHeader(let folder, let count):
                                    SidebarFolderRow(model: model, folder: folder, count: count)
                                case .tab(let tab, let indent):
                                    SidebarTabRow(model: model, tab: tab, indent: indent)
                                        .id(tab.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .onChange(of: model.session.activeTabID) {
                    guard let active = model.session.activeTabID else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        proxy.scrollTo(active, anchor: .center)
                    }
                }
            }

            Rectangle()
                .fill(Color.browsemiumBorder)
                .frame(height: 1)
                .padding(.horizontal, 10)

            footer
        }
        .frame(width: BrowserMetrics.sidebarWidth)
        .frame(maxHeight: .infinity)
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
        .alert("New Folder", isPresented: $isNamingFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName
                newFolderName = ""
                model.createFolder(named: name.isEmpty ? "New Folder" : name)
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        } message: {
            Text("Folders keep related tabs together without switching groups.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            BrowsemiumIconButton(systemName: "sidebar.left", label: "Collapse sidebar") {
                BrowserHaptics.perform()
                model.toggleSidebarCollapsed()
            }
            spaceMenu
            Spacer(minLength: 0)
            NewTabSidebarButton {
                BrowserHaptics.perform()
                model.newTab()
            }
        }
        .padding(.horizontal, 10)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.browsemiumTertiary)
            Text("\(model.visibleTabs.count) \(model.visibleTabs.count == 1 ? "tab" : "tabs")")
                .font(.system(size: 11))
                .foregroundStyle(Color.browsemiumTertiary)
            if model.sleepingTabCount > 0 {
                Text("· \(model.sleepingTabCount) sleeping")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.browsemiumTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.visibleTabs.count) tabs, \(model.sleepingTabCount) sleeping")
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.browsemiumTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, pinnedTabs.isEmpty || title == "Pinned" ? 0 : 6)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    /// The same group picker the top strip shows, styled for the sidebar.
    private var spaceMenu: some View {
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
            Button("New Folder…") {
                newFolderName = ""
                isNamingFolder = true
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
            HStack(spacing: 6) {
                Circle()
                    .fill(groupColor)
                    .frame(width: 7, height: 7)
                Text(model.activeGroup?.name ?? "Tabs")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.browsemiumPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Color.browsemiumTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .fill(Color.browsemiumField)
            )
            .overlay {
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .stroke(Color.browsemiumBorder, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help("Tab groups — switch, create, or manage groups")
        .accessibilityLabel("Tab group, \(model.activeGroup?.name ?? "Tabs")")
    }

    private var groupColor: Color {
        guard let hex = model.activeGroup?.color else {
            return Color.browsemiumTertiary
        }
        return Color(browsemiumHex: hex) ?? Color.browsemiumTertiary
    }
}

@MainActor
private struct NewTabSidebarButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovering ? Color.browsemiumPrimary : Color.browsemiumSecondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                        .fill(isHovering ? Color.browsemiumSelection : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("New tab")
        .help("New Tab (⌘T)")
    }
}

/// One full-width row in the sidebar. Mirrors `TabItem` in the top strip —
/// same model calls, same context menu — but laid out for a fixed-width list
/// where the title always has room.
@MainActor
private struct SidebarTabRow: View {
    @Bindable var model: BrowserWindowModel
    let tab: BrowserTab
    /// Folder members are indented under their folder's header.
    let indent: Bool

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

    var body: some View {
        HStack(spacing: 8) {
            icon

            if model.isTabInSplit(tab.id) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.browsemiumFocus)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title)
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? Color.browsemiumPrimary : Color.browsemiumSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let host = tab.lastCommittedURL?.host, isActive || isHovering {
                    Text(host)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.browsemiumTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 2)

            trailing
        }
        .padding(.leading, indent ? 18 : 8)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
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
            // Small delay so brushing past rows does not flash a card.
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, isHovering else { return }
                isShowingStats = true
            }
        }
        .popover(isPresented: $isShowingStats, arrowEdge: .trailing) {
            TabPreviewCard(model: model, tab: tab, stats: model.tabStats(for: tab))
        }
        .contextMenu {
            TabMenuContent(model: model, tab: tab, afterLabel: "Close Tabs Below") {
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

/// A folder's header row in the sidebar: chevron, name, and member count.
/// Clicking collapses or expands; dragging a tab onto it files the tab.
@MainActor
private struct SidebarFolderRow: View {
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
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.browsemiumTertiary)
                .rotationEffect(.degrees(folder.isCollapsed ? 0 : 90))
                .frame(width: 10)
            Image(systemName: folder.isCollapsed ? "folder.fill" : "folder")
                .font(.system(size: 10))
                .foregroundStyle(accent)
                .frame(width: 14)
            Text(folder.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.browsemiumSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.browsemiumTertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                .fill(isHovering ? Color.browsemiumHover : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            BrowserHaptics.perform()
            model.toggleFolderCollapsed(folder.id)
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(folder.isCollapsed ? "Expand Folder" : "Collapse Folder") {
                model.toggleFolderCollapsed(folder.id)
            }
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
        .dropDestination(for: String.self) { items, _ in
            guard let rawID = items.first,
                  let uuid = UUID(uuidString: rawID) else { return false }
            model.assignTab(TabID(rawValue: uuid), toFolder: folder.id)
            return true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Folder, \(folder.name), \(count) tabs, \(folder.isCollapsed ? "collapsed" : "expanded")")
        .accessibilityAddTraits(.isButton)
    }
}
