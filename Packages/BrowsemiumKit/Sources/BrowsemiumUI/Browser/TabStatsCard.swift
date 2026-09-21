import BrowsemiumCore
import SwiftUI

/// Hover card for a tab. Shows only figures that can be verified: the tab's
/// real load state, whether it currently holds a web view, and Browsemium's
/// own measured memory footprint.
@MainActor
struct TabStatsCard: View {
    let tab: BrowserTab
    let stats: BrowserWindowModel.TabStats

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tab.title.isEmpty ? "New Tab" : tab.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.browsemiumPrimary)
                    .lineLimit(2)

                if let host = tab.lastCommittedURL?.host {
                    Text(host)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.browsemiumTertiary)
                        .lineLimit(1)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                statRow("State", stateLabel, accent: stateColor)
                statRow("Holding memory", stats.isLive ? "Yes" : "No — released")
                statRow("Live tabs", "\(stats.liveTabs)")
                statRow("Sleeping tabs", "\(stats.sleepingTabs)")
                statRow("Browsemium memory", stats.footprint)
            }

            Text("Web pages run in separate WebKit processes, so per-tab memory is not measurable. The figure above covers the \(stats.footprintScope). These figures are real.")
                .font(.system(size: 10))
                .foregroundStyle(Color.browsemiumTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 230)
        .background(Color.browsemiumRaised)
        .foregroundStyle(Color.browsemiumPrimary)
    }

    private func statRow(_ label: String, _ value: String, accent: Color = .browsemiumSecondary) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.browsemiumTertiary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(accent)
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
