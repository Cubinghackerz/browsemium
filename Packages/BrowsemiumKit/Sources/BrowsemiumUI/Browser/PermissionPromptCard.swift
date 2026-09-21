import BrowsemiumCore
import BrowsemiumEngine
import SwiftUI
import BrowsemiumEngineKit

/// The camera/microphone prompt. WebKit routes these requests through the UI
/// delegate; without a prompt the request was denied silently and a voice
/// session on a provider site simply never started.
@MainActor
struct PermissionPromptCard: View {
    let request: BrowserWindowModel.PermissionRequest
    let answer: (SitePermissionAnswer) -> Void

    private var host: String {
        URL(string: request.origin)?.host ?? request.origin
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.browsemiumAccent)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                            .fill(Color.browsemiumSelection)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(host) wants to \(request.kind.requestDescription)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.browsemiumPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Nothing is shared until you allow it.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.browsemiumTertiary)
                }
            }

            HStack(spacing: 8) {
                BrowsemiumPrimaryButton("Allow") {
                    BrowserHaptics.perform()
                    answer(.allowOnce)
                }
                BrowsemiumTextButton("Always allow") {
                    BrowserHaptics.perform()
                    answer(.allowAlways)
                }
                Spacer(minLength: 4)
                BrowsemiumTextButton("Block", role: .destructive) {
                    BrowserHaptics.perform()
                    answer(.block)
                }
            }
        }
        .padding(18)
        .frame(width: 380, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: BrowserMetrics.overlayRadius, style: .continuous)
                .fill(Color.browsemiumRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BrowserMetrics.overlayRadius, style: .continuous)
                .stroke(Color.browsemiumBorderStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 24, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("\(host) wants to \(request.kind.requestDescription)")
    }

    private var iconName: String {
        switch request.kind {
        case .camera: "video"
        case .microphone: "mic"
        case .location: "location"
        case .notifications: "bell"
        case .popups: "macwindow.on.rectangle"
        case .downloads: "arrow.down.circle"
        }
    }
}
