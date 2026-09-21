import AppKit
import BrowsemiumCore
import BrowsemiumData
import SwiftUI
import BrowsemiumEngineKit

@MainActor
struct LibraryView: View {
    enum LibrarySection: String, CaseIterable, Identifiable {
        case history
        case bookmarks
        case downloads
        case recentlyClosed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .history: "History"
            case .bookmarks: "Bookmarks"
            case .downloads: "Downloads"
            case .recentlyClosed: "Recently Closed"
            }
        }
    }

    @Bindable var model: BrowserWindowModel
    @State private var section: LibrarySection = .history
    @State private var query = ""
    @State private var history: [HistoryVisit] = []
    @State private var bookmarks: [Bookmark] = []
    @State private var downloads: [DownloadRecord] = []
    @State private var closedTabs: [ClosedTabEntry] = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.browsemiumBorder).frame(height: 1)
            content
        }
        .background(Color.browsemiumRaised)
        .onAppear {
            section = switch model.activePanel {
            case .bookmarks: .bookmarks
            case .downloads: .downloads
            case .recentlyClosed: .recentlyClosed
            default: .history
            }
            reload()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BrowsemiumTabPicker(
                values: LibrarySection.allCases,
                selection: Binding(
                    get: { section },
                    set: { newValue in
                        section = newValue
                        reload()
                    }
                ),
                label: \.title
            )
            .accessibilityLabel("Library section")

            Spacer(minLength: 12)

            TextField("Filter", text: $query)
                .font(.system(size: 12))
                .browsemiumField()
                .frame(width: 180, height: 24)
                .padding(.horizontal, 8)
                .onSubmit { reload() }
                .accessibilityLabel("Filter \(section.title.lowercased())")

            BrowsemiumTextButton("Done") { model.activePanel = .none }
        }
        .padding(.horizontal, 12)
        .frame(height: BrowserMetrics.toolbarHeight)
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            BrowsemiumEmptyState(
                systemName: "exclamationmark.triangle",
                title: "Something went wrong",
                message: errorMessage
            )
        } else {
            switch section {
            case .history:
                if history.isEmpty {
                    BrowsemiumEmptyState(
                        systemName: "clock",
                        title: "No history yet",
                        message: "Pages you visit appear here. History stays on this Mac."
                    )
                } else {
                    list(history)
                }
            case .bookmarks:
                if bookmarks.isEmpty {
                    BrowsemiumEmptyState(
                        systemName: "bookmark",
                        title: "No bookmarks yet",
                        message: "Press ⌘D on a page to bookmark it."
                    )
                } else {
                    list(bookmarks)
                }
            case .downloads:
                if downloads.isEmpty {
                    BrowsemiumEmptyState(
                        systemName: "arrow.down.circle",
                        title: "No downloads yet",
                        message: "Files you download appear here with their destination."
                    )
                } else {
                    list(downloads)
                }
            case .recentlyClosed:
                if closedTabs.isEmpty {
                    BrowsemiumEmptyState(
                        systemName: "arrow.uturn.backward",
                        title: "No recently closed tabs",
                        message: "Tabs you close appear here; press ⇧⌘T to reopen the latest."
                    )
                } else {
                    list(closedTabs)
                }
            }
        }
    }

    private func list(_ visits: [HistoryVisit]) -> some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(visits) { visit in
                    LibraryRow(
                        title: visit.title.isEmpty ? (visit.url.host ?? visit.url.absoluteString) : visit.title,
                        subtitle: visit.url.absoluteString,
                        trailing: visit.visitedAt.formatted(date: .abbreviated, time: .shortened),
                        action: { _ = model.newTab(url: visit.url) }
                    )
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
        }
    }

    private func list(_ items: [Bookmark]) -> some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(items) { bookmark in
                    LibraryRow(
                        title: bookmark.title,
                        subtitle: bookmark.url.absoluteString,
                        trailing: nil,
                        action: { _ = model.newTab(url: bookmark.url) },
                        removeAction: {
                            _ = try? model.environment.bookmarkRepository.remove(id: bookmark.id)
                            reload()
                        }
                    )
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
        }
    }

    private func list(_ items: [DownloadRecord]) -> some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(items) { download in
                    LibraryRow(
                        title: download.suggestedFilename,
                        subtitle: download.destinationURL?.path ?? download.sourceURL.absoluteString,
                        trailing: download.state.rawValue,
                        action: {
                            if let url = download.destinationURL {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }
                    )
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
        }
    }

    private func list(_ items: [ClosedTabEntry]) -> some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(items) { entry in
                    LibraryRow(
                        title: entry.title.isEmpty ? (entry.url?.host ?? "Closed tab") : entry.title,
                        subtitle: entry.url?.absoluteString ?? "No address recorded",
                        trailing: entry.closedAt.formatted(date: .abbreviated, time: .shortened),
                        action: {
                            model.reopenClosedTab(entry)
                            reload()
                        }
                    )
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
        }
    }

    private func reload() {
        let environment = model.environment
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch section {
            case .history:
                history = trimmed.isEmpty
                    ? try environment.historyRepository.recent(limit: 300)
                    : try environment.historyRepository.search(trimmed, limit: 200)
            case .bookmarks:
                bookmarks = trimmed.isEmpty
                    ? try environment.bookmarkRepository.all()
                    : try environment.bookmarkRepository.search(trimmed)
            case .downloads:
                downloads = try environment.downloadRepository.recent(limit: 200)
                    .filter { trimmed.isEmpty || $0.suggestedFilename.localizedCaseInsensitiveContains(trimmed) }
            case .recentlyClosed:
                let entries = try environment.closedTabRepository.recent(limit: 50)
                closedTabs = trimmed.isEmpty
                    ? entries
                    : entries.filter {
                        $0.title.localizedCaseInsensitiveContains(trimmed)
                            || ($0.url?.absoluteString.localizedCaseInsensitiveContains(trimmed) ?? false)
                    }
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
private struct LibraryRow: View {
    let title: String
    let subtitle: String
    let trailing: String?
    let action: () -> Void
    var removeAction: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.browsemiumPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.browsemiumTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(subtitle)")

            if let trailing {
                Text(trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.browsemiumTertiary)
            }

            if let removeAction, isHovering {
                Button(action: removeAction) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.browsemiumTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(title)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                .fill(isHovering ? Color.browsemiumHover : Color.clear)
        )
        .onHover { isHovering = $0 }
    }
}
