import BrowsemiumCore
import BrowsemiumUI
import SwiftUI

@main
struct BrowsemiumApp: App {
    @State private var model = BrowsemiumApp.makeModel()

    var body: some Scene {
        WindowGroup {
            BrowsemiumAppView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { model.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                Button("Close Tab") { model.closeTab() }
                    .keyboardShortcut("w", modifiers: .command)
                Button("Reopen Closed Tab") { model.reopenClosedTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }

            CommandMenu("Navigate") {
                Button("Focus Address") { model.focusAddress() }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Reload") { model.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Stop") { model.stopLoading() }
                    .keyboardShortcut(".", modifiers: .command)
                Divider()
                Button("Back") { model.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward") { model.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
            }

            CommandMenu("Page") {
                Button("Find on Page…") { model.showFindBar() }
                    .keyboardShortcut("f", modifiers: .command)
                Divider()
                Button("Zoom In") { model.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { model.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { model.resetZoom() }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                Button("Print…") { model.printPage() }
                    .keyboardShortcut("p", modifiers: .command)
            }

            CommandMenu("View") {
                Button("Commands") { model.toggleCommandPalette() }
                    .keyboardShortcut("k", modifiers: .command)
                Button(model.isAIDockVisible ? "Hide Assistant" : "Show Assistant") { model.toggleAIDock() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button(model.isBookmarksBarVisible ? "Hide Bookmarks Bar" : "Show Bookmarks Bar") {
                    model.toggleBookmarksBar()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }

            CommandMenu("Library") {
                Button("Bookmark This Page") { model.toggleBookmark() }
                    .keyboardShortcut("d", modifiers: .command)
                Divider()
                Button("History") { model.openPanel(.history) }
                    .keyboardShortcut("y", modifiers: .command)
                Button("Bookmarks") { model.openPanel(.bookmarks) }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                Button("Downloads") { model.openPanel(.downloads) }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.openPanel(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    private static func makeModel() -> BrowserWindowModel {
        do {
            let environment = try BrowserEnvironment.live()
            return BrowserWindowModel(environment: environment)
        } catch {
            let fallback = BrowserWindowModel()
            fallback.statusMessage = "Browsemium could not open its local database, so history, bookmarks, and settings will not be saved this session."
            return fallback
        }
    }
}
