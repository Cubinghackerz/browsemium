import BrowsemiumCore

/// Constructed once per window, preserving the catalog's existing order and
/// placeholder tab IDs. Dispatch resolves those placeholders to the active tab.
enum PaletteCommandCatalog {
    static func commands() -> [BrowserPaletteCommand] {
        [
            BrowserPaletteCommand(id: "new-tab", title: "New Tab", shortcut: "⌘T", command: .newTab),
            BrowserPaletteCommand(id: "close-tab", title: "Close Tab", shortcut: "⌘W", command: .closeTab(TabID())),
            BrowserPaletteCommand(id: "reload", title: "Reload Page", shortcut: "⌘R", command: .reload),
            BrowserPaletteCommand(id: "reopen", title: "Reopen Closed Tab", shortcut: "⇧⌘T", command: .reopenClosedTab),
            BrowserPaletteCommand(id: "bookmark", title: "Bookmark This Page", shortcut: "⌘D", command: .toggleBookmark),
            BrowserPaletteCommand(id: "history", title: "Open History", shortcut: "⌘Y", command: .openHistory),
            BrowserPaletteCommand(id: "bookmarks", title: "Open Bookmarks", shortcut: "⌥⌘B", command: .openBookmarks),
            BrowserPaletteCommand(id: "downloads", title: "Open Downloads", shortcut: "⇧⌘J", command: .openDownloads),
            BrowserPaletteCommand(id: "settings", title: "Open Settings", shortcut: "⌘,", command: .openSettings),
            BrowserPaletteCommand(id: "import", title: "Import from Another Browser", shortcut: "", command: .openImportWizard),
            BrowserPaletteCommand(id: "toggle-ai", title: "Toggle Assistant", shortcut: "⇧⌘A", command: .toggleAIDock),
            BrowserPaletteCommand(id: "ai-summarize", title: "AI: Summarize This Page", shortcut: "", command: .aiQuickAction(.summarizePage)),
            BrowserPaletteCommand(id: "ai-keypoints", title: "AI: Extract Key Points", shortcut: "", command: .aiQuickAction(.keyPoints)),
            BrowserPaletteCommand(id: "ai-explain", title: "AI: Explain Selection", shortcut: "", command: .aiQuickAction(.explainSelection)),
            BrowserPaletteCommand(id: "zoom-in", title: "Zoom In", shortcut: "⌘+", command: .zoomIn),
            BrowserPaletteCommand(id: "zoom-out", title: "Zoom Out", shortcut: "⌘-", command: .zoomOut),
            BrowserPaletteCommand(id: "zoom-reset", title: "Reset Zoom", shortcut: "⌘0", command: .resetZoom),
            BrowserPaletteCommand(id: "print-page", title: "Print page", shortcut: "⌘P", command: .printPage),
            BrowserPaletteCommand(id: "find-in-page", title: "Find in page", shortcut: "⌘F", command: .findInPage),
            BrowserPaletteCommand(id: "reader-mode", title: "Reader mode", shortcut: "⇧⌘R", command: .toggleReaderMode),
            BrowserPaletteCommand(id: "hide-element", title: "Hide element", shortcut: "⇧⌘H", command: .hideElement),
            BrowserPaletteCommand(id: "save-pdf", title: "Save Page as PDF", shortcut: "", command: .savePageAsPDF),
            BrowserPaletteCommand(id: "save-screenshot", title: "Save Page Screenshot", shortcut: "", command: .savePageScreenshot),
            BrowserPaletteCommand(id: "pip", title: "Picture in Picture", shortcut: "", command: .togglePictureInPicture),
            BrowserPaletteCommand(id: "clear-data", title: "Clear Browsing Data", shortcut: "", command: .clearBrowsingData),
            BrowserPaletteCommand(id: "tab-layout", title: "Switch Between Top and Sidebar Tabs", shortcut: "", command: .toggleTabLayout),
            BrowserPaletteCommand(id: "split-view", title: "Toggle Split View", shortcut: "⇧⌘D", command: .toggleSplitView),
            BrowserPaletteCommand(id: "duplicate-tab", title: "Duplicate Tab", shortcut: "", command: .duplicateTab(TabID())),
            BrowserPaletteCommand(id: "copy-url", title: "Copy Current URL", shortcut: "⇧⌘C", command: .copyTabURL(TabID())),
            BrowserPaletteCommand(id: "next-tab", title: "Select Next Tab", shortcut: "⌃⇥", command: .selectAdjacentTab(forward: true)),
            BrowserPaletteCommand(id: "previous-tab", title: "Select Previous Tab", shortcut: "⌃⇧⇥", command: .selectAdjacentTab(forward: false)),
            BrowserPaletteCommand(id: "close-others", title: "Close Other Tabs", shortcut: "", command: .closeOtherTabs(TabID())),
            BrowserPaletteCommand(id: "private-window", title: "New Private Window", shortcut: "⇧⌘N", command: .newPrivateWindow),
            BrowserPaletteCommand(id: "ai-summarize-tabs", title: "AI: Summarize Open Tabs", shortcut: "", command: .summarizeOpenTabs),
            BrowserPaletteCommand(id: "ai-rewrite", title: "AI: Rewrite Selection", shortcut: "", command: .aiQuickAction(.rewriteSelection)),
            BrowserPaletteCommand(id: "ai-shorten", title: "AI: Shorten Selection", shortcut: "", command: .aiQuickAction(.shortenSelection)),
            BrowserPaletteCommand(id: "ai-bullets", title: "AI: Selection to Bullets", shortcut: "", command: .aiQuickAction(.bulletPoints))
        ]
    }
}
