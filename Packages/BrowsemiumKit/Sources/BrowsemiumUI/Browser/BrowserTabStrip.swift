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
    @State private var newGroupIsSeparate = false
    @State private var newGroupName = ""
    @State private var isRenamingGroup = false
    @State private var groupRenameText = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The selected tab's pill is one shape that slides between tabs.
    @Namespace private var selectionPill

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
                    TabItem(model: model, tab: tab, width: 30, inFolder: false, pill: selectionPill)
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
                                    TabItem(model: model, tab: tab, width: regularWidth, inFolder: inFolder, pill: selectionPill)
                                        .id(tab.id)
                                }
                            }
                        }
                        .padding(.horizontal, 1)
                        .animation(BrowserMotion.standard(reduceMotion: reduceMotion), value: stripEntries.map(\.id))
                    }
                    // The active tab is always brought into view: when it
                    // changes, when tabs come or go, and when the strip appears.
                    .onChange(of: model.session.activeTabID) { scrollToActive(proxy, animated: true) }
                    .onChange(of: stripEntries.count) { scrollToActive(proxy, animated: true) }
                    // One turn later on appear: the strip has to lay out before
                    // a restored session's active tab has a position to scroll to.
                    .onAppear { Task { @MainActor in scrollToActive(proxy, animated: false) } }
                }

                NewTabButton {
                    BrowserHaptics.perform()
                    model.newTab()
                }
            }
            .padding(.trailing, 8)
            .padding(.top, model.chromeStyle == .compact ? 2 : BrowserMetrics.tabStripTopInset)
        }
        .frame(height: BrowserMetrics.tabStripHeight(for: model.chromeStyle))
        .background(WindowDragView())
        .alert(newGroupIsSeparate ? "New Separate Group" : "New Tab Group", isPresented: $isNamingGroup) {
            TextField("Name", text: $newGroupName)
            Button("Create") {
                let name = newGroupName
                newGroupName = ""
                model.createGroup(
                    named: name.isEmpty ? "Group \(model.session.spaces.count)" : name,
                    separateData: newGroupIsSeparate
                )
            }
            Button("Cancel", role: .cancel) { newGroupName = "" }
        } message: {
            Text(newGroupIsSeparate
                 ? "Cookies, logins and site data in this group are kept apart from your other groups, so you can sign in to two accounts on one site. History, bookmarks and passwords are still shared. This cannot be changed later."
                 : "Groups keep related tabs together and switch as a set.")
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
                    } else if space.hasSeparateData {
                        Label(space.name, systemImage: "person.crop.square")
                    } else {
                        Text(space.name)
                    }
                }
            }
            Divider()
            Button("New Group…") {
                newGroupName = ""
                newGroupIsSeparate = false
                isNamingGroup = true
            }
            .disabled(model.session.isPrivate)
            Button("New Separate Group…") {
                newGroupName = ""
                newGroupIsSeparate = true
                isNamingGroup = true
            }
            .disabled(model.session.isPrivate)
            .help("A group with its own cookies and logins")
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
                if model.activeGroup?.hasSeparateData == true {
                    Image(systemName: "person.crop.square")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.browsemiumTertiary)
                        .help("This group keeps its own cookies and logins")
                        .accessibilityLabel("Separate cookies and logins")
                }
                Text(model.activeGroup?.name ?? "Tabs")
                    .font(BrowserType.font(.caption, weight: .medium))
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

    private func scrollToActive(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let active = model.session.activeTabID else { return }
        if animated {
            withAnimation(BrowserMotion.standard(reduceMotion: reduceMotion)) {
                proxy.scrollTo(active, anchor: .center)
            }
        } else {
            proxy.scrollTo(active, anchor: .center)
        }
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
                .font(BrowserType.font(.small, weight: .semibold))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: BrowserWindowModel
    let tab: BrowserTab
    let width: CGFloat
    /// Members of an expanded folder get a small folder glyph.
    let inFolder: Bool
    let pill: Namespace.ID

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

            TabFaviconView(model: model, tab: tab, size: 16, isActive: isActive)

            if model.isTabInSplit(tab.id), !isCompact {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.browsemiumFocus)
                    .accessibilityHidden(true)
            }

            if !isCompact {
                Text(tab.title)
                    .font(BrowserType.font(.small))
                    .foregroundStyle(isActive ? Color.browsemiumPrimary : Color.browsemiumSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 2)

                trailing
            }
        }
        .padding(.horizontal, isCompact ? 0 : 9)
        .frame(width: width, height: 28)
        .background {
            // One pill shared by every tab: selecting another tab slides it
            // there instead of redrawing it.
            ZStack {
                if isActive {
                    RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                        .fill(Color.browsemiumSelection)
                        .overlay {
                            RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                                .stroke(Color.browsemiumBorderStrong, lineWidth: 1)
                        }
                        .matchedGeometryEffect(id: "selection-pill", in: pill)
                } else if isHovering {
                    RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                        .fill(Color.browsemiumHover)
                }
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
        // The close button below appears only while the pointer is over the
        // tab. This action gives VoiceOver and the rotor the same command.
        .accessibilityAction(named: "Close tab") { model.closeTab(tab.id) }
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
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
                    .contentTransition(.symbolEffect(.replace))
                    // The waves move while the page is actually making sound.
                    .symbolEffect(.variableColor.iterative, isActive: audio.isPlaying && !audio.isMuted && !reduceMotion)
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
                .font(BrowserType.font(.caption, weight: .medium))
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
