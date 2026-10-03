import BrowsemiumCore
import BrowsemiumEngineKit
import SwiftUI

/// One writing surface; context is deliberate and the primary action is review,
/// not a silent send. Capture/skills remain the existing browser operations.
@MainActor
struct AIDockComposer<Actions: View, Attachments: View>: View {
    @Bindable var model: BrowserWindowModel
    @Bindable var ai: AIDockViewModel
    let focus: FocusState<Bool>.Binding
    let actions: Actions
    let attachments: Attachments
    let attach: (CaptureKind, String) -> Void
    let quickAction: (AIQuickAction) -> Void

    private var canReview: Bool { AIDockPresentation.reviewIsEnabled(canSend: ai.canSend, isWorking: ai.isWorking) }
    private var canUsePage: Bool { AIDockPresentation.pageContextIsAvailable(in: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CurrentPageBar(model: model)
            if !ai.attachments.isEmpty { attachments }
            if !ai.messages.isEmpty {
                HStack(spacing: 12) {
                    Button("Summarize") { quickAction(.summarizePage) }
                    Button("Key points") { quickAction(.keyPoints) }
                    Button("Explain") { quickAction(.explainSelection) }
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color.browsemiumSecondary)
                .disabled(ai.isWorking || ai.isStreaming || !canUsePage)
            }

            VStack(alignment: .leading, spacing: 12) {
                TextField("", text: $ai.draft,
                    prompt: Text(AIDockPresentation.prompt(canUsePage: canUsePage)).foregroundColor(.browsemiumSecondary), axis: .vertical)
                    .font(.system(size: 14))
                    .lineLimit(2...6)
                    .textFieldStyle(.plain)
                    .focused(focus)
                    .accessibilityLabel("Assistant prompt")
                    .onSubmit { review() }
                    .frame(minHeight: 44, alignment: .topLeading)

                HStack(spacing: 6) {
                    Menu {
                        Button("Attach a file…", systemImage: "paperclip") { ai.addFiles() }
                            .disabled(ai.isWorking)
                        Divider()
                        Section {
                            Button("Selected text", systemImage: "text.cursor") { attach(.selection, "Selection attached") }
                            Button("Page text", systemImage: "doc.text") { attach(.readablePage, "Page text attached") }
                            Button("Visible screenshot", systemImage: "camera.viewfinder") { attach(.viewportImage, "Screenshot attached") }
                            Button("Full page screenshot", systemImage: "rectangle.portrait") { attach(.fullPageImage, "Full page screenshot attached") }
                        }
                        .disabled(!canUsePage)
                    } label: {
                        Image(systemName: "plus").font(.system(size: 16, weight: .regular)).frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(ai.isWorking)
                    .accessibilityLabel("Attach context or files")
                    .help("Choose what to include")
                    actions
                    Spacer(minLength: 8)
                    if ai.isWorking {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Preparing context")
                    }
                    Button {
                        if ai.isStreaming { ai.stop() } else { review() }
                    } label: {
                        HStack(spacing: 6) {
                            Text(ai.isStreaming ? "Stop" : "Review")
                            Image(systemName: ai.isStreaming ? "stop.fill" : "arrow.up")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                    }
                    .buttonStyle(AIDockActionStyle(primary: true))
                    .disabled(!ai.isStreaming && !canReview)
                    .accessibilityLabel(ai.isStreaming ? "Stop generating" : "Review message before sending")
                }
                .foregroundStyle(Color.browsemiumSecondary)
            }
            .padding(14)
            .background(Color.browsemiumRaised, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(focus.wrappedValue ? Color.browsemiumFocus : Color.browsemiumBorderStrong, lineWidth: 1)
            }

            HStack(alignment: .center, spacing: 8) {
                Text("Review before sending")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.browsemiumSecondary)
                Spacer(minLength: 4)
                Toggle("Auto page", isOn: Binding(
                    get: { model.environment.loadSettings().includePageContextInAPIAI },
                    set: { value in model.updateSettings { $0.includePageContextInAPIAI = value } }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .foregroundStyle(Color.browsemiumSecondary)
                .help("Attach page text automatically; the review still shows it first")
                .accessibilityLabel("Attach page text to every message")
                .disabled(!canUsePage)
            }

            if let error = ai.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if ai.lastFailedSend != nil {
                        Button("Try again") { ai.retryLastSend() }
                            .accessibilityLabel("Retry the failed message")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.browsemiumDestructive)
            }
        }
        .padding(16)
    }

    private func review() {
        guard canReview else { return }
        ai.beginReview(tabID: model.session.activeTabID)
    }
}
