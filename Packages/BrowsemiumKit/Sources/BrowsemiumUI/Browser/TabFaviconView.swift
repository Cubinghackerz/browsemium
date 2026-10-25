import BrowsemiumCore
import SwiftUI

/// The tab's icon: a spinner while loading, the cached favicon, a warning
/// when the page crashed, otherwise the host's first letter. One view for the
/// sidebar rows, pinned tiles and the top strip so they never drift apart.
@MainActor
struct TabFaviconView: View {
    let model: BrowserWindowModel
    let tab: BrowserTab
    var size: CGFloat = 16
    let isActive: Bool

    var body: some View {
        Group {
            if tab.lifecycle == .loading {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.75)
            } else if let favicon = model.favicons.image(for: tab.lastCommittedURL) {
                Image(nsImage: favicon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else if tab.lifecycle == .crashed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(BrowserType.font(.caption))
                    .foregroundStyle(Color.browsemiumWarning)
            } else if let host = tab.lastCommittedURL?.host {
                Text(NewTabContent.fallbackLetter(forHost: host))
                    .font(.system(size: size * 0.56, weight: .semibold))
                    .foregroundStyle(isActive ? Color.browsemiumPrimary : Color.browsemiumSecondary)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.browsemiumSelection))
            } else {
                Image(systemName: "sparkle")
                    .font(BrowserType.font(.caption))
                    .foregroundStyle(Color.browsemiumTertiary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
