import BrowsemiumCore
import SwiftUI

/// The preview for "Group Tabs by Topic". Every folder is a checkbox and a
/// name field; nothing is created until Create is pressed.
@MainActor
struct TabGroupSuggestionSheet: View {
    @Bindable var grouping: TabGroupingController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Group tabs by topic")
                .font(BrowserType.font(.title, weight: .semibold))

            switch grouping.phase {
            case .idle, .working:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading tab titles…")
                        .font(BrowserType.font(.small))
                        .foregroundStyle(Color.browsemiumSecondary)
                }
            case .failed(let message):
                Text(message)
                    .font(BrowserType.font(.small))
                    .foregroundStyle(Color.browsemiumSecondary)
            case .ready:
                Text(grouping.usedModel
                     ? "Suggested with Apple's on-device model, using only tab titles and sites. Nothing left this Mac."
                     : "Suggested from tabs on the same site. Turn on Apple Intelligence for topic-based groups.")
                    .font(BrowserType.font(.small))
                    .foregroundStyle(Color.browsemiumSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach($grouping.rows) { $row in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Toggle("", isOn: $row.isIncluded)
                                        .labelsHidden()
                                        .accessibilityLabel("Create folder \(row.name)")
                                    TextField("Folder name", text: $row.name)
                                        .textFieldStyle(.roundedBorder)
                                        .controlSize(.small)
                                        .accessibilityLabel("Folder name")
                                }
                                ForEach(row.tabs) { tab in
                                    Text(tab.title)
                                        .font(BrowserType.font(.small))
                                        .foregroundStyle(row.isIncluded ? Color.browsemiumSecondary : Color.browsemiumTertiary)
                                        .lineLimit(1)
                                        .padding(.leading, 26)
                                }
                            }
                            .padding(10)
                            .background(Color.browsemiumRaised)
                            .clipShape(RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius))
                        }
                    }
                }
                .frame(maxHeight: 300)
            }

            HStack(spacing: 12) {
                BrowsemiumTextButton("Cancel") { grouping.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                BrowsemiumPrimaryButton(
                    "Create folders",
                    isDisabled: !(grouping.phase == .ready && grouping.rows.contains { $0.isIncluded })
                ) { grouping.apply() }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
        .background(Color.browsemiumSurface)
        .foregroundStyle(Color.browsemiumPrimary)
    }
}
