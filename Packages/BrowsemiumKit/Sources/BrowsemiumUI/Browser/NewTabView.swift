import BrowsemiumData
import SwiftUI

/// The quiet start surface: the mark, the name, and the shortcuts that matter.
struct NewTabView: View {
    @Bindable var model: BrowserWindowModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            BrowsemiumLogo(size: 68)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .padding(.bottom, 18)

            Text("Browsemium")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.browsemiumPrimary)

            Text("Search or type an address — ⌘L jumps straight to it.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.browsemiumTertiary)
                .padding(.top, 5)

            HStack(spacing: 14) {
                hint("⌘T", "New tab")
                hint("⌘K", "Commands")
                hint("⇧⌘A", "Assistant")
            }
            .padding(.top, 26)

            if !model.bookmarks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Bookmarks")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.browsemiumTertiary)

                    HStack(spacing: 8) {
                        ForEach(Array(model.bookmarks.prefix(8))) { bookmark in
                            bookmarkButton(bookmark)
                        }
                    }
                }
                .padding(.top, 34)
                .frame(maxWidth: 680, alignment: .leading)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.browsemiumRaised)
        .contentShape(Rectangle())
        .onTapGesture { model.focusAddress() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("New tab. Search or type an address. Command L focuses the address bar, Command K opens commands, Shift Command A opens the assistant.")
    }

    private func bookmarkButton(_ bookmark: Bookmark) -> some View {
        Button {
            model.open(bookmark.url)
        } label: {
            VStack(spacing: 8) {
                Group {
                    if let favicon = model.favicons.image(for: bookmark.url) {
                        Image(nsImage: favicon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    } else {
                        Image(systemName: "globe")
                            .font(.system(size: 16, weight: .light))
                            .foregroundStyle(Color.browsemiumTertiary)
                    }
                }
                .frame(width: 22, height: 22)

                Text(bookmark.title.isEmpty ? (bookmark.url.host ?? "Bookmark") : bookmark.title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.browsemiumSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(width: 76, height: 62)
            .background(
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .fill(Color.browsemiumField)
            )
            .overlay {
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .stroke(Color.browsemiumBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help(bookmark.url.absoluteString)
    }

    private func hint(_ keys: String, _ description: String) -> some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.browsemiumSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.browsemiumField)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.browsemiumBorder, lineWidth: 1)
                }
            Text(description)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.browsemiumTertiary)
        }
        .accessibilityHidden(true)
    }
}
