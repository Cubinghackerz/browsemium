import BrowsemiumCore
import SwiftUI

/// The link-preview overlay — Zen's Glance, Arc's peek. ⌘-clicking a link in a
/// page opens it here instead of stacking another tab: the page is live and
/// interactive, but nothing about it is persisted until the user promotes it
/// into a real tab.
@MainActor
struct PeekOverlay: View {
    @Bindable var model: BrowserWindowModel
    let peek: BrowserWindowModel.PeekState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { model.closePeek() }

                VStack(spacing: 0) {
                    header
                    Rectangle()
                        .fill(Color.browsemiumBorder)
                        .frame(height: 1)
                    WebViewHost(
                        engine: model.environment.engine,
                        tabID: peek.tabID,
                        isPrivate: model.session.isPrivate
                    )
                    Rectangle()
                        .fill(Color.browsemiumBorder)
                        .frame(height: 1)
                    footer
                }
                .frame(
                    width: min(geometry.size.width * 0.72, 980),
                    height: min(geometry.size.height * 0.82, 720)
                )
                .background(Color.browsemiumRaised)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.browsemiumBorder, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.22), radius: 24, y: 8)
            }
        }
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let favicon = model.favicons.image(for: peek.url) {
                Image(nsImage: favicon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                Image(systemName: "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.browsemiumTertiary)
                    .frame(width: 14, height: 14)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(peek.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.browsemiumPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(peek.url.absoluteString)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.browsemiumTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button {
                BrowserHaptics.perform()
                model.promotePeekToSplitView()
            } label: {
                Label("Open in Split", systemImage: "rectangle.split.2x1")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .fill(Color.browsemiumField)
            )
            .overlay {
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .stroke(Color.browsemiumBorder, lineWidth: 1)
            }
            .help("Open this page beside the one you came from")
            .accessibilityLabel("Open preview beside the current page")

            Button {
                BrowserHaptics.perform()
                model.promotePeekToTab()
            } label: {
                Label("Open as Tab", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .fill(Color.browsemiumSelection)
            )
            .overlay {
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .stroke(Color.browsemiumBorder, lineWidth: 1)
            }
            .help("Keep this page open as a real tab")
            .accessibilityLabel("Open preview as a tab")

            Button {
                BrowserHaptics.perform()
                model.closePeek()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.browsemiumTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Preview (Esc)")
            .accessibilityLabel("Close preview")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye")
                .font(.system(size: 9))
                .foregroundStyle(Color.browsemiumTertiary)
            Text("Preview — nothing is saved unless you open it as a tab.")
                .font(.system(size: 10))
                .foregroundStyle(Color.browsemiumTertiary)
            Spacer(minLength: 0)
            Text("⌘-click any link to preview it")
                .font(.system(size: 10))
                .foregroundStyle(Color.browsemiumTertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .accessibilityElement(children: .combine)
    }
}
