import BrowsemiumExtensions
import SwiftUI

/// The prompt an extension's permission request shows. Deny is always a
/// working answer — the extension keeps running without the grant — so the
/// card never implies the user must allow to continue.
@MainActor
struct ExtensionPermissionCard: View {
    let request: ExtensionPermissionRequest
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.browsemiumSecondary)
                Text("“\(request.extensionName)” is asking for access")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.browsemiumPrimary)
            }

            Text(explanation)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.browsemiumSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !request.items.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(request.items, id: \.self) { item in
                        HStack(spacing: 6) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 3))
                                .foregroundStyle(Color.browsemiumTertiary)
                            Text(item)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.browsemiumSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                        .fill(Color.browsemiumField)
                )
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Deny") { answer(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Allow") { answer(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
        .browsemiumPanel(background: .browsemiumRaised, radius: BrowserMetrics.overlayRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Extension permission request from \(request.extensionName)")
    }

    private var explanation: String {
        switch request.kind {
        case .apiPermissions:
            "The extension wants these browser features. Nothing is granted until you allow it."
        case .hostAccess:
            "The extension wants to read and change pages on these sites. Denying keeps it running without access."
        }
    }
}
