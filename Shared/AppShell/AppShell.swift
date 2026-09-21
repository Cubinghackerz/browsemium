import AppKit
import BrowsemiumUI
import Foundation
import SwiftUI

/// App-lifetime work shared by both editions. The only thing here is the
/// promise the settings screen makes: "Clear history when Browsemium quits".
@MainActor
final class BrowsemiumAppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the environment exists. Weak: the app owns it.
    weak var environment: BrowserEnvironment?

    override init() {
        super.init()
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment?.runTerminationTasks()
    }
}

/// A deliberately non-dismissible update gate. It lives above the browser
/// window so the app never leaves a stale, half-blocking Sparkle alert behind.
@MainActor
struct MandatoryUpdateOverlay: View {
    private let updates: UpdateController

    init(updates: UpdateController) {
        self.updates = updates
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.44)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.app")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color.browsemiumPrimary)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.browsemiumSelection))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Update required")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.browsemiumPrimary)
                        Text(updateName)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.browsemiumSecondary)
                            .lineLimit(2)
                    }
                }

                Text("A signed Browsemium update is ready. Install it before continuing so your browser stays secure and supported.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.browsemiumSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if updates.phase != .required {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            if case .failed = updates.phase {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(Color.browsemiumWarning)
                            } else if let progress = updates.downloadProgress {
                                ProgressView(value: progress)
                                    .progressViewStyle(.linear)
                                    .tint(Color.browsemiumAccent)
                            } else {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(updates.statusDescription)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.browsemiumTertiary)
                        }

                        if case .failed = updates.phase {
                            BrowsemiumPrimaryButton("Retry update") {
                                updates.retryMandatoryUpdate()
                            }
                        }
                    }
                } else {
                    BrowsemiumPrimaryButton("Update now") {
                        updates.installMandatoryUpdate()
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 440, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: BrowserMetrics.overlayRadius, style: .continuous)
                    .fill(Color.browsemiumRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BrowserMetrics.overlayRadius, style: .continuous)
                    .stroke(Color.browsemiumBorderStrong, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.24), radius: 26, y: 12)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .zIndex(20)
    }

    private var updateName: String {
        if let version = updates.pendingVersion {
            return "Browsemium \(version)"
        }
        return updates.pendingTitle ?? "A new Browsemium release"
    }
}

/// Gives each window its own model. The first window owns session persistence;
/// extra windows are ephemeral so two windows cannot clobber the saved session.
@MainActor
@Observable
final class BrowserWindowRegistry {
    private var hasPrimary = false

    init() {}

    func claimPrimary() -> Bool {
        if hasPrimary { return false }
        hasPrimary = true
        return true
    }
}
