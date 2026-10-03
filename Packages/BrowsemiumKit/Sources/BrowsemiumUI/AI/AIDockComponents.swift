import SwiftUI
import BrowsemiumCore

enum AIDockPresentation {
    static func reviewIsEnabled(canSend: Bool, isWorking: Bool) -> Bool { canSend && !isWorking }

    static func prompt(canUsePage: Bool) -> String {
        canUsePage ? "Ask a question about this page…" : "Ask a question…"
    }

    @MainActor static func pageContextIsAvailable(in model: BrowserWindowModel) -> Bool {
        guard let tab = model.activeTab, let url = tab.lastCommittedURL,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return false }
        return model.canSharePageWithAI(tab.id)
    }
}

struct AIAPIKeyField: View {
    let providerName: String
    @Binding var value: String
    @FocusState private var isFocused: Bool

    var body: some View {
        SecureField("\(providerName) API key", text: $value)
            .font(.system(size: 13))
            .textFieldStyle(.plain)
            .focused($isFocused)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color.browsemiumRaised, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isFocused ? Color.browsemiumFocus : Color.browsemiumBorderStrong, lineWidth: 1)
            }
            .accessibilityLabel("\(providerName) API key")
    }
}

@MainActor
struct AIDockConnectionCard: View {
    @Bindable var ai: AIDockViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "key.horizontal")
                    .foregroundStyle(Color.browsemiumSecondary)
                Text("Connect \(ai.descriptor.displayName)")
                    .font(.system(size: 13, weight: .semibold))
            }
            HStack(spacing: 8) {
                AIAPIKeyField(providerName: ai.descriptor.displayName, value: $ai.credentialInput)
                Button { Task { await ai.connect() } } label: {
                    Group {
                        if ai.isWorking { ProgressView().controlSize(.small) }
                        else { Text("Connect").font(.system(size: 12, weight: .semibold)) }
                    }
                    .frame(width: 76, height: 40)
                }
                .buttonStyle(AIDockActionStyle(primary: true))
                .disabled(ai.isWorking || ai.credentialInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(ai.isWorking ? "Connecting" : "Connect API key")
            }
            Text("Your key stays in Keychain and is sent only to \(ai.descriptor.displayName). A chat subscription does not include an API key.")
                .font(.system(size: 11))
                .foregroundStyle(Color.browsemiumPrimary.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.browsemiumPrimary)
        .padding(14)
        .background(Color.browsemiumField, in: RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor
struct AIDockWelcome: View {
    let canUsePage: Bool
    let isWorking: Bool
    let run: (AIQuickAction) -> Void

    private let actions: [(String, String, String, AIQuickAction)] = [
        ("Summarize", "An overview of this page", "doc.text", .summarizePage),
        ("Key points", "Find what matters", "list.bullet", .keyPoints),
        ("Explain", "Understand your selected text", "text.bubble", .explainSelection)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(canUsePage ? "Make sense of this page." : "Start a conversation.")
                    .font(.system(size: 21, weight: .medium))
                    .tracking(-0.5)
                    .foregroundStyle(Color.browsemiumPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(canUsePage ? "Go from reading to understanding. Choose a starting point, or ask your own question." : "Ask a question or attach a file. Page context is available only for an accessible browsing page.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.browsemiumPrimary.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if canUsePage { VStack(spacing: 4) {
                ForEach(actions.indices, id: \.self) { index in
                    let item = actions[index]
                    Button { run(item.3) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.2).font(.system(size: 15, weight: .regular)).frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.0).font(.system(size: 13, weight: .medium))
                                Text(item.1).font(.system(size: 11)).foregroundStyle(Color.browsemiumSecondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.right").font(.system(size: 11))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(AIDockActionStyle())
                    .disabled(!canUsePage || isWorking)
                    .accessibilityLabel("\(item.0) — opens review before sending")
                }
            } }
        }
        .frame(maxWidth: 400, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

@MainActor
struct AIDockCompactWelcome: View {
    let canUsePage: Bool
    let isWorking: Bool
    let run: (AIQuickAction) -> Void

    var body: some View {
        Group {
            if canUsePage {
                HStack(spacing: 4) {
                    action("Summarize", symbol: "doc.text", kind: .summarizePage)
                    action("Key points", symbol: "list.bullet", kind: .keyPoints)
                    action("Explain", symbol: "text.bubble", kind: .explainSelection)
                }
                .disabled(isWorking)
            } else {
                Text("Ask a question or attach a file.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.browsemiumPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func action(_ title: String, symbol: String, kind: AIQuickAction) -> some View {
        Button { run(kind) } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 14))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
        }
        .buttonStyle(AIDockActionStyle())
        .accessibilityLabel("\(title) — opens review before sending")
    }
}

struct AIDockActionStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        ActionBody(configuration: configuration, primary: primary)
    }

    private struct ActionBody: View {
        let configuration: Configuration
        let primary: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false
        var body: some View {
            configuration.label
                .foregroundStyle(primary && isEnabled ? Color.browsemiumAccentFillText : Color.browsemiumPrimary)
                .background {
                    RoundedRectangle(cornerRadius: 8).fill(primary && isEnabled ? Color.browsemiumAccentFill :
                        (isHovering || configuration.isPressed ? Color.browsemiumHover :
                            (primary ? Color.browsemiumField : Color.clear)))
                }
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onHover { isHovering = $0 }
        }
    }
}
