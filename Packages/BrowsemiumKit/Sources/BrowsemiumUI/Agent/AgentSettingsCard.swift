import AppKit
import BrowsemiumEngine
import SwiftUI

/// Settings for the external-agent endpoint. Off by default; while off the app
/// opens no port. Drawing this card only asks the keychain whether a token
/// exists (`hasSecret`), so opening Settings never triggers a keychain prompt.
@MainActor
struct AgentSettingsCard: View {
    let environment: BrowserEnvironment
    @State private var isEnabled = false
    @State private var copiedMessage: String?

    private var coordinator: AgentCoordinator { environment.agent }

    var body: some View {
        // The Chromium edition cannot be driven yet; show nothing rather than
        // a switch that does nothing.
        if environment.engine is BrowserRuntimeController {
            SettingsCard("External agents", systemImage: "point.3.connected.trianglepath.dotted") {
                SettingsRow("Allow external agents") {
                    Toggle("", isOn: Binding(
                        get: { isEnabled },
                        set: { value in
                            isEnabled = value
                            coordinator.setEndpointEnabled(value)
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Color.browsemiumAccentFill)
                    .accessibilityLabel("Allow external agents")
                }

                SettingsRow("Status") {
                    Text(statusText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(statusColor)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("agent-endpoint-status")
                }

                if isEnabled || coordinator.tokenExists {
                    SettingsRow("Access token") {
                        HStack(spacing: 12) {
                            Text(coordinator.tokenExists ? "Saved in your keychain" : "Not created yet")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.browsemiumSecondary)
                            if coordinator.tokenExists {
                                BrowsemiumTextButton("Copy token") { copyToken(.token) }
                                BrowsemiumTextButton("Reset", role: .destructive) {
                                    coordinator.rotateToken()
                                }
                            }
                        }
                    }
                }

                if coordinator.tokenExists {
                    SettingsRow("Claude Code") {
                        BrowsemiumTextButton("Copy command") { copyToken(.claudeCode) }
                    }
                    SettingsRow("Other clients") {
                        BrowsemiumTextButton("Copy JSON config") { copyToken(.json) }
                    }
                }

                if let message = copiedMessage ?? coordinator.notice {
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.browsemiumSecondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                        .accessibilityLabel(message)
                }

                SettingsNote(
                    "Lets an agent such as Claude Code or Cursor ask to work in a Browsemium window. "
                        + "It listens only on this Mac (127.0.0.1) and only answers requests that carry the token above. "
                        + "Each task needs your approval first, shows what it is doing, and ends when you press Stop, "
                        + "switch profile, lock a space or quit. Every click and every typed value asks you again. "
                        + "A task works with this profile's logins and cookies on the sites you approve, so an agent you "
                        + "allow can read what those sites show you. Anyone who has the token and is signed in to this Mac "
                        + "can ask for a task, though nothing happens until you approve it. "
                        + "Works with clients that support HTTP MCP servers with custom headers."
                )
            }
            .onAppear {
                isEnabled = coordinator.isEndpointEnabled
                coordinator.refreshTokenState()
            }
        }
    }

    private var statusText: String {
        switch coordinator.endpoint {
        case .off: "Off"
        case .starting: "Starting…"
        case .listening(let port): "Listening on 127.0.0.1:\(port)"
        case .failed(let message): message
        }
    }

    private var statusColor: Color {
        switch coordinator.endpoint {
        case .listening: .browsemiumSuccess
        case .failed: .browsemiumWarning
        default: .browsemiumSecondary
        }
    }

    private enum Copy { case token, claudeCode, json }

    private func copyToken(_ kind: Copy) {
        guard let token = coordinator.revealToken() else {
            copiedMessage = "The token could not be read from the keychain."
            return
        }
        let text: String
        switch kind {
        case .token: text = token
        case .claudeCode: text = AgentCoordinator.claudeCodeCommand(token: token)
        case .json: text = AgentCoordinator.jsonConfiguration(token: token)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Tells clipboard managers that honor the convention not to record it.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        copiedMessage = "Copied. It contains your access token, so only paste it into your agent client."
    }
}
