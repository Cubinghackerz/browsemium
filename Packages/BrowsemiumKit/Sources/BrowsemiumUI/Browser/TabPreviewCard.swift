import BrowsemiumCore
import SwiftUI
import BrowsemiumEngineKit

/// Hover preview for a tab — the page snapshot plus the facts that can be
/// verified: the tab's real load state, whether it currently holds a web
/// view, and Browsemium's own measured memory footprint. A sleeping or
/// blank tab has no page to photograph, so it shows metadata only — the
/// snapshot area collapses rather than faking a thumbnail.
@MainActor
struct TabPreviewCard: View {
    @Bindable var model: BrowserWindowModel
    let tab: BrowserTab
    let stats: BrowserWindowModel.TabStats
    @State private var snapshot: NSImage?
    @State private var snapshotLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot {
                Image(nsImage: snapshot)
                    .resizable()
                    .aspectRatio(16 / 10, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.browsemiumBorder, lineWidth: 1)
                    }
                    .accessibilityLabel("Preview of \(tab.title)")
            } else if snapshotLoaded {
                // A snapshot was attempted and the tab had nothing to show —
                // say so rather than leaving a blank box.
                HStack(spacing: 6) {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.browsemiumTertiary)
                    Text("This tab is asleep — wake it to see the page.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.browsemiumTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.browsemiumField)
                )
                .accessibilityElement(children: .combine)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    if let favicon = model.favicons.image(for: tab.lastCommittedURL) {
                        Image(nsImage: favicon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                    Text(tab.title.isEmpty ? "New Tab" : tab.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.browsemiumPrimary)
                        .lineLimit(2)
                }

                if let url = tab.lastCommittedURL {
                    Text(url.absoluteString)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.browsemiumTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            // The facts, grouped in one quiet block so the rows read as a set
            // instead of floating text.
            VStack(alignment: .leading, spacing: 7) {
                statRow("State", stateLabel, accent: stateColor)
                if let audio = model.tabAudio[tab.id], audio.isPlaying || audio.isMuted {
                    statRow("Audio", audio.isMuted ? "Muted" : "Playing")
                }
                if let folderID = tab.folderID, let folder = model.folder(folderID) {
                    statRow("Folder", folder.name)
                }
                statRow("Live tabs", "\(stats.liveTabs)")
                statRow("Sleeping tabs", "\(stats.sleepingTabs)")
                statRow("Browsemium memory", stats.footprint)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .fill(Color.browsemiumField)
            )

            Text("Web pages run in separate WebKit processes, so per-tab memory is not measurable. The figure above covers the \(stats.footprintScope).")
                .font(.system(size: 9.5))
                .foregroundStyle(Color.browsemiumTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 264)
        .background(Color.browsemiumRaised)
        .foregroundStyle(Color.browsemiumPrimary)
        .task {
            // Snapshot once when the card appears; a page keeps changing, but
            // re-shooting on a timer would spin WebKit for a hover card.
            snapshot = await model.previewImage(for: tab.id)
            snapshotLoaded = true
        }
    }

    private func statRow(_ label: String, _ value: String, accent: Color = .browsemiumSecondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.browsemiumTertiary)
            Spacer(minLength: 10)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(accent)
                .lineLimit(1)
        }
    }

    private var stateLabel: String {
        if tab.isPinned, tab.lastCommittedURL == nil { return "Pinned" }
        switch tab.lifecycle {
        case .metadataOnly: return tab.lastCommittedURL == nil ? "Blank" : "Not loaded"
        case .loading: return "Loading"
        case .active: return "Loaded"
        case .suspended: return "Suspended"
        case .hibernated: return "Sleeping"
        case .crashed: return "Stopped responding"
        }
    }

    private var stateColor: Color {
        switch tab.lifecycle {
        case .crashed: return .browsemiumWarning
        case .loading: return .browsemiumPrimary
        default: return .browsemiumSecondary
        }
    }
}
