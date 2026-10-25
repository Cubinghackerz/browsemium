import BrowsemiumCore
import SwiftUI

/// Settings: the pages being watched, with how often and what happened last.
@MainActor
struct PageWatchSettingsView: View {
    @Bindable var model: BrowserWindowModel

    var body: some View {
        let controller = model.environment.pageWatches
        SettingsCard("Page watches", systemImage: "bell") {
            if controller.watches.isEmpty {
                SettingsRow("Nothing watched") {
                    Text("Use Watch Page for Changes in the command menu.")
                        .font(BrowserType.font(.small))
                        .foregroundStyle(Color.browsemiumSecondary)
                }
            } else {
                ForEach(controller.watches) { watch in
                    VStack(alignment: .leading, spacing: 4) {
                        SettingsRow(watch.title.isEmpty ? (watch.url.host ?? "Page") : watch.title) {
                            HStack(spacing: 10) {
                                Picker("Check every", selection: Binding(
                                    get: { watch.intervalMinutes },
                                    set: { controller.setInterval($0, for: watch) }
                                )) {
                                    ForEach(PageWatchLimits.allowedIntervals, id: \.self) { minutes in
                                        Text(Self.label(minutes)).tag(minutes)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 110)
                                BrowsemiumTextButton("Remove", role: .destructive) { controller.remove(watch) }
                            }
                        }
                        Text(status(for: watch))
                            .font(BrowserType.font(.caption))
                            .foregroundStyle(watch.lastProblem == nil ? Color.browsemiumTertiary : Color.browsemiumWarning)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 6)
                    }
                }
            }
            SettingsNote("Watches run only while Browsemium is open. Each check loads the page without your cookies or logins, so a page behind a sign-in shows the sign-in page and is reported as such. Browsemium keeps a fingerprint of each page, not its text, and never watches from private windows.")
        }
    }

    private func status(for watch: PageWatch) -> String {
        if let problem = watch.lastProblem { return problem }
        guard let checked = watch.lastCheckedAt else { return "Not checked yet." }
        let base = "Checked \(checked.formatted(.relative(presentation: .named)))."
        guard let changed = watch.lastChangedAt else { return base + " No change yet." }
        return base + " Last changed \(changed.formatted(.relative(presentation: .named)))."
    }

    private static func label(_ minutes: Int) -> String {
        switch minutes {
        case 15: "15 minutes"
        case 30: "30 minutes"
        case 60: "1 hour"
        case 360: "6 hours"
        case 1440: "Daily"
        default: "\(minutes) min"
        }
    }
}
