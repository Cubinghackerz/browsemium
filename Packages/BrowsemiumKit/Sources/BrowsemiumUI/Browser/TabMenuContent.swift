import BrowsemiumCore
import SwiftUI
import BrowsemiumEngineKit

/// The right-click menu for a tab, shared by the top strip and the sidebar
/// so the two never drift apart. `afterLabel` is the only difference: the
/// strip reads "to the Right", the sidebar "Below".
@MainActor
struct TabMenuContent: View {
    @Bindable var model: BrowserWindowModel
    let tab: BrowserTab
    let afterLabel: String
    /// Opens the caller's "name the new folder" alert — the alert lives on
    /// the row so its state survives the menu closing.
    let onNewFolder: () -> Void

    var body: some View {
        Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { model.togglePin(tab.id) }
        Button(model.isKeptAwake(tab.id) ? "Allow This Tab to Sleep" : "Keep This Tab Loaded") {
            model.toggleKeepAwake(tab.id)
        }
        Button("Duplicate Tab") { model.duplicateTab(tab.id) }
        Button("Copy Link") { model.copyURL(of: tab.id) }
            .disabled(model.tabURLs[tab.id] == nil && tab.lastCommittedURL == nil)
        if !tab.isPinned {
            if tab.folderID != nil {
                Button("Remove from Folder") { model.assignTab(tab.id, toFolder: nil) }
            }
            Menu("Move to Folder") {
                Button("New Folder…") { onNewFolder() }
                ForEach(model.activeFolders.filter { $0.id != tab.folderID }) { folder in
                    Button(folder.name) { model.assignTab(tab.id, toFolder: folder.id) }
                }
            }
        }
        if tab.id == model.session.activeTabID {
            // The active tab cannot split with itself — offer the other tabs
            // in this space instead, so "Open in Split View" is never a dead
            // end on the tab the user is reading.
            Menu("Split View With") {
                ForEach(model.visibleTabs.filter { $0.id != tab.id }) { other in
                    Button(other.title.isEmpty ? (model.tabURLs[other.id]?.host ?? "Tab") : other.title) {
                        model.openInSplitView(other.id)
                    }
                }
            }
            .disabled(!model.visibleTabs.contains { $0.id != tab.id })
        } else {
            Button("Open in Split View") { model.openInSplitView(tab.id) }
        }
        if model.isSplitViewActive {
            Button("Close Split View") { model.closeSplitView() }
        }
        let otherGroups = model.session.spaces.filter { $0.id != tab.spaceID }
        if !otherGroups.isEmpty {
            Menu("Move to Group") {
                ForEach(otherGroups) { space in
                    Button(space.name) { model.moveTab(tab.id, toGroup: space.id) }
                }
            }
        }
        Divider()
        Button("Close Other Tabs") { model.closeOtherTabs(around: tab.id) }
            .disabled(!closableOthersExist)
        Button(afterLabel) { model.closeTabs(after: tab.id) }
            .disabled(!closableLaterExists)
        Divider()
        Button("Close Tab") { model.closeTab(tab.id) }
    }

    private var closableOthersExist: Bool {
        model.visibleTabs.contains { $0.id != tab.id && !$0.isPinned }
    }

    private var closableLaterExists: Bool {
        guard let index = model.visibleTabs.firstIndex(where: { $0.id == tab.id }) else { return false }
        return model.visibleTabs.dropFirst(index + 1).contains { !$0.isPinned }
    }
}
