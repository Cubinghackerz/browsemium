import BrowsemiumCore
import SwiftUI

/// Per-extension site access: the stored Allow / Ask / Deny choices for one
/// extension, as shown in Settings → Extensions.
///
/// Explicit rows only — an extension with no rows uses WebKit's default
/// everywhere (it asks on first use). Denying a site blocks the extension's
/// content scripts there from the next load; code already running keeps going
/// until the page reloads.
@MainActor
struct ExtensionSitePolicySection: View {
    @Bindable var model: BrowserWindowModel
    let extensionID: String
    let extensionName: String

    @State private var revision = 0

    private var policies: [ExtensionSitePolicy] {
        _ = revision
        return model.extensionSitePolicies(for: extensionID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if policies.isEmpty {
                Text("Can ask for any site — nothing chosen yet.")
                    .font(BrowserType.font(.caption))
                    .foregroundStyle(Color.browsemiumTertiary)
                    .accessibilityLabel("\(extensionName) site access: no site choices, asks everywhere")
            } else {
                ForEach(policies) { policy in
                    HStack(spacing: 8) {
                        Text(policy.host)
                            .font(BrowserType.font(.small, design: .monospaced))
                            .foregroundStyle(Color.browsemiumPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        BrowsemiumTabPicker(
                            values: ExtensionSiteAccessMode.allCases,
                            selection: modeBinding(for: policy),
                            label: \.title
                        )
                        .accessibilityLabel("\(extensionName) on \(policy.host)")
                        BrowsemiumIconButton(systemName: "xmark", label: "Back to asking on \(policy.host)") {
                            model.clearExtensionSiteMode(for: extensionID, host: policy.host)
                            revision += 1
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
                Text("Blocking a site takes effect on its next load — anything already running there needs a reload.")
                    .font(BrowserType.font(.caption))
                    .foregroundStyle(Color.browsemiumTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 4)
    }

    private func modeBinding(for policy: ExtensionSitePolicy) -> Binding<ExtensionSiteAccessMode> {
        Binding(
            get: { model.extensionSiteMode(for: extensionID, host: policy.host) ?? .ask },
            set: {
                model.setExtensionSiteMode($0, for: extensionID, host: policy.host)
                revision += 1
            }
        )
    }
}
