import AppKit
import BrowsemiumCore
import BrowsemiumData
import SwiftUI

/// A slim strip of bookmarks below the toolbar. Appears only when the bar is
/// enabled and at least one bookmark exists, so it never occupies dead space.
@MainActor
struct BookmarksBar: View {
    @Bindable var model: BrowserWindowModel

    var body: some View {
        if model.isBookmarksBarVisible, !model.bookmarks.isEmpty {
            HStack(spacing: 2) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(model.bookmarks) { bookmark in
                            BookmarkItem(model: model, bookmark: bookmark)
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Bookmarks bar")
        }
    }
}

@MainActor
private struct BookmarkItem: View {
    let model: BrowserWindowModel
    let bookmark: Bookmark

    @State private var isHovering = false

    var body: some View {
        Button {
            BrowserHaptics.perform()
            model.open(bookmark.url)
        } label: {
            HStack(spacing: 6) {
                icon

                Text(bookmark.title.isEmpty ? (bookmark.url.host ?? bookmark.url.absoluteString) : bookmark.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.browsemiumSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .frame(maxWidth: 160)
            .background(
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .fill(isHovering ? Color.browsemiumHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open in New Tab") { model.newTab(url: bookmark.url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(bookmark.url.absoluteString, forType: .string)
            }
            Divider()
            Button("Remove Bookmark", role: .destructive) { model.removeBookmark(bookmark) }
        }
        .help(bookmark.url.absoluteString)
        .accessibilityLabel("Bookmark, \(bookmark.title)")
    }

    @ViewBuilder
    private var icon: some View {
        if let favicon = model.favicons.image(for: bookmark.url) {
            Image(nsImage: favicon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 13, height: 13)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: "globe")
                .font(.system(size: 10))
                .foregroundStyle(Color.browsemiumTertiary)
                .frame(width: 13, height: 13)
        }
    }
}
