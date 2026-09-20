import BrowsemiumAI
import BrowsemiumCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
struct AIDockView: View {
    @Bindable var model: BrowserWindowModel
    @Bindable var ai: AIDockViewModel
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header

            switch ai.mode {
            case .web:
                ZStack(alignment: .top) {
                    ProviderPanelHost(
                        controller: ai.providerPanel,
                        provider: ai.provider,
                        revision: ai.providerPanel.revision
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if ai.isWorking {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Preparing page context…")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Color.browsemiumPrimary)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(Color.browsemiumBorder, lineWidth: 1)
                        }
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Preparing page context")
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            case .api:
                AIChatTranscript(ai: ai)
            }

            if ai.mode == .api {
                composer
            }
        }
        .sheet(isPresented: $ai.isReviewPresented) {
            AIContextReviewSheet(model: model, ai: ai)
        }
        .onChange(of: model.session.activeTabID) {
            // Context is page-specific. Never leave a previous tab's content
            // attached after the user switches tabs.
            ai.clearAttachments()
            ai.errorMessage = nil
        }
        .onChange(of: ai.provider) {
            // A stream belonging to the previous provider must not keep
            // writing into the transcript after the switch.
            ai.providerDidChange()
            ai.providerPanel.release(except: ai.provider)
        }
        .task {
            // Only touch the keychain once the assistant is actually visible.
            ai.refreshCredentialState()
            ai.restoreLastConversationIfNeeded()
            if ai.mode == .web,
               model.environment.loadSettings().includePageMetadataInWebAI,
               !UserDefaults.standard.bool(forKey: "browsemium.webAI.pageMetadataNotice.v1") {
                model.statusMessage = "Web AI adds this page's safe text and metadata when you send. Screenshots are only attached when you choose Capture."
                UserDefaults.standard.set(true, forKey: "browsemium.webAI.pageMetadataNotice.v1")
            }
        }
        .onAppear {
            let dock = ai
            let browser = model
            dock.providerPanel.prepareComposerMessage = { [weak dock, weak browser] provider, text in
                guard let dock, let browser else {
                    return ProviderComposerPreparation(text: text)
                }
                return try await dock.prepareWebProviderMessage(
                    userPrompt: text,
                    tab: browser.activeTab,
                    provider: provider
                )
            }
            dock.providerPanel.isComposerPreparationCurrent = { [weak dock] provider, id in
                dock?.isWebProviderPreparationCurrent(provider: provider, id: id) ?? false
            }
            dock.providerPanel.didSubmitComposerMessage = { [weak dock] provider, id in
                // The controller only calls this after the preparation token
                // was validated, so the provider cannot accidentally finish a
                // newer tab's context.
                dock?.finishWebProviderMessage(provider: provider, id: id)
            }
            dock.providerPanel.didAbortComposerMessage = { [weak dock] provider, id in
                dock?.abortWebProviderMessage(provider: provider, id: id)
            }
            dock.providerPanel.didFailComposerMessage = { [weak dock, weak browser] _, message in
                dock?.errorMessage = message
                browser?.statusMessage = message
            }
            browser.memoryPressureHandler = { [weak dock] _ in
                dock?.providerPanel.releaseAll()
            }
        }
        .onDisappear {
            // Provider panels are expensive WebViews. Persisted WebKit data
            // keeps the login, while the live page is recreated on reopen.
            ai.stop()
            ai.providerPanel.prepareComposerMessage = nil
            ai.providerPanel.isComposerPreparationCurrent = nil
            ai.providerPanel.didSubmitComposerMessage = nil
            ai.providerPanel.didAbortComposerMessage = nil
            ai.providerPanel.didFailComposerMessage = nil
            ai.providerPanel.releaseAll()
            ai.clearAttachments()
            model.memoryPressureHandler = nil
        }
        .onChange(of: ai.mode) {
            // Switching modes must cancel in-flight API work. A canceled task
            // must not later flip the new mode's state back to idle.
            ai.stop()
            if ai.provider.isLocal, ai.mode == .web {
                ai.mode = .api
            } else if ai.mode == .api {
                ai.providerPanel.releaseAll()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(AIProviderID.allCases, id: \.self) { provider in
                        Button(ProviderPanelDescriptor.descriptor(for: provider).displayName) {
                            ai.provider = provider
                            // A local server has no website to embed; it is
                            // API-only by nature.
                            if provider.isLocal {
                                ai.mode = .api
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(ai.descriptor.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.browsemiumPrimary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Color.browsemiumTertiary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("AI provider")

                Spacer(minLength: 6)

                BrowsemiumTabPicker(
                    values: ai.provider.isLocal ? [.api] : AIDockMode.allCases,
                    selection: $ai.mode,
                    label: \.title
                )
                .accessibilityLabel("Assistant mode")

                if ai.mode == .web {
                    webContextMenu
                }

                BrowsemiumIconButton(systemName: "xmark", label: "Close assistant") {
                    model.toggleAIDock()
                }
            }

            if ai.mode == .api {
                apiControls
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, ai.mode == .api ? 8 : 4)
    }

    private var webContextMenu: some View {
        Menu {
            Text("Automatic text + metadata")
            Toggle(
                "Include automatic page text + title + URL",
                isOn: Binding(
                    get: { model.environment.loadSettings().includePageMetadataInWebAI },
                    set: { enabled in
                        var settings = model.environment.loadSettings()
                        settings.includePageMetadataInWebAI = enabled
                        model.environment.saveSettings(settings)
                    }
                )
            )
            Divider()
            Button("Attach selection") {
                attachContext(.selection, confirmation: "Selection attached for your next message")
            }
            Button("Attach readable page") {
                attachContext(.readablePage, confirmation: "Page text attached for your next message")
            }
            Button("Attach screenshot") {
                attachContext(.viewportImage, confirmation: "Screenshot captured for your next message")
            }
            Button("Attach full page screenshot") {
                attachContext(.fullPageImage, confirmation: "Full page screenshot captured for your next message")
            }
            Button("Add file") {
                ai.addFiles()
            }
            if !ai.attachments.isEmpty {
                Divider()
                ForEach(Array(ai.attachmentLabels.enumerated()), id: \.offset) { index, label in
                    Button("Remove \(label)") { ai.removeAttachment(at: index) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: ai.attachments.isEmpty ? "sparkles" : "sparkles.circle.fill")
                    .font(.system(size: 11))
                Text(ai.attachments.isEmpty ? "Context" : "Context · \(ai.attachments.count)")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Color.browsemiumSecondary)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose what the next web AI message can use")
        .accessibilityLabel("Web AI context")
    }

    private var apiControls: some View {
        VStack(spacing: 6) {
            if ai.provider.isLocal {
                HStack(spacing: 8) {
                    if ai.models.isEmpty {
                        BrowsemiumPrimaryButton("Look for Ollama", isDisabled: ai.isWorking) {
                            Task { await ai.connect() }
                        }
                    } else {
                        Picker("Model", selection: $ai.selectedModelID) {
                            ForEach(ai.models) { model in
                                Text(model.name).tag(String?.some(model.id))
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel("Model")

                        BrowsemiumTextButton("Refresh models") {
                            Task { await ai.loadModels() }
                        }
                    }
                }
                Text("Runs on this Mac through Ollama at localhost:11434. No key, no account, and nothing you send leaves the machine.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.browsemiumTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if ai.hasStoredCredential {
                HStack(spacing: 8) {
                    Picker("Model", selection: $ai.selectedModelID) {
                        if ai.models.isEmpty {
                            Text("No models loaded").tag(String?.none)
                        }
                        ForEach(ai.models) { model in
                            Text(model.name).tag(String?.some(model.id))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Model")

                    BrowsemiumTextButton("Remove key", role: .destructive) { ai.disconnect() }
                }
            } else {
                HStack(spacing: 6) {
                    SecureField("\(ai.descriptor.displayName) API key", text: $ai.credentialInput)
                        .font(.system(size: 12))
                        .browsemiumField()
                        .frame(height: 26)
                        .padding(.horizontal, 8)
                        .accessibilityLabel("API key")
                    BrowsemiumPrimaryButton("Connect", isDisabled: ai.isWorking) {
                        Task { await ai.connect() }
                    }
                }
                Text("Keys stay in your macOS keychain and are sent only to \(ai.descriptor.displayName). Consumer subscriptions do not include API credits.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.browsemiumTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let status = ai.credentialStatus {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.browsemiumSuccess)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            CurrentPageBar(model: model)

            if !ai.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(ai.attachments.enumerated()), id: \.offset) { index, attachment in
                            AttachmentChip(
                                label: ai.label(for: attachment),
                                thumbnail: ai.thumbnail(for: attachment),
                                dragProvider: { dragProvider(for: attachment) }
                            ) {
                                ai.removeAttachment(at: index)
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .animation(.easeOut(duration: 0.15), value: ai.attachments.count)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button(action: { ai.addFiles() }) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.browsemiumSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add file attachment")
                .help("Attach a file")

                VStack(spacing: 0) {
                    TextField("Ask about this page…", text: $ai.draft, axis: .vertical)
                        .font(.system(size: 12.5))
                        .lineLimit(1...4)
                        .textFieldStyle(.plain)
                        .focused($composerFocused)
                        .accessibilityLabel("Assistant prompt")
                        .onSubmit { if ai.canSend { ai.beginReview() } }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                        .fill(Color.browsemiumField)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                        .stroke(Color.browsemiumBorder, lineWidth: 1)
                }

                if ai.isStreaming {
                    Button(action: { ai.stop() }) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.browsemiumSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop generating")
                } else {
                    Button(action: { ai.beginReview() }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(ai.canSend ? Color.browsemiumAccentFill : Color.browsemiumTertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!ai.canSend)
                    .accessibilityLabel("Send")
                }
            }

            HStack(spacing: 6) {
                contextButton(systemName: "text.cursor", label: "Selection") {
                    attachContext(.selection, confirmation: "Selection attached")
                }
                contextButton(systemName: "doc.text", label: "Page") {
                    attachContext(.readablePage, confirmation: "Page text attached")
                }
                contextButton(systemName: "camera.viewfinder", label: "Capture") {
                    attachContext(.viewportImage, confirmation: "Screenshot attached — describe what to do with it")
                }
                contextButton(systemName: "rectangle.portrait.and.arrow.forward", label: "Full page") {
                    attachContext(.fullPageImage, confirmation: "Full page screenshot attached")
                }
                Spacer()
            }

            if let error = ai.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.browsemiumDestructive)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private func attachContext(_ kind: CaptureKind, confirmation: String) {
        Task {
            await ai.attach(kind, tabID: model.session.activeTabID)
            // A successful capture lands in the composer immediately — focus the
            // field and confirm visibly so it never looks like nothing happened.
            if ai.errorMessage == nil {
                composerFocused = true
                model.statusMessage = confirmation
            }
        }
    }

    /// Captures become real drag sources: the screenshot chip can be dragged
    /// straight into the provider's composer inside the panel, and text can be
    /// dragged into any app. Files are written on demand, so a drag that never
    /// happens costs nothing.
    private func dragProvider(for attachment: AIContextAttachment) -> NSItemProvider {
        switch attachment {
        case .viewportImage(let image), .fullPageImage(let image):
            let provider = NSItemProvider()
            let type = UTType(mimeType: image.mimeType) ?? .png
            let ext = type.preferredFilenameExtension ?? "png"
            provider.registerFileRepresentation(
                forTypeIdentifier: type.identifier,
                fileOptions: [],
                visibility: .all
            ) { completion in
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("browsemium-capture-\(UUID().uuidString).\(ext)")
                do {
                    try image.data.write(to: url)
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
                return nil
            }
            provider.suggestedName = "Browsemium capture"
            return provider
        case .file(let file):
            let provider = NSItemProvider(contentsOf: file.fileURL) ?? NSItemProvider()
            provider.suggestedName = file.filename
            return provider
        case .selection(let context):
            return NSItemProvider(object: context.text as NSString)
        case .readablePage(let context):
            return NSItemProvider(object: context.text as NSString)
        }
    }

    private func contextButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 9.5))
                Text(label)
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(Color.browsemiumSecondary)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(ai.isWorking)
        .accessibilityLabel("Attach \(label.lowercased()) context")
        .help("Attach \(label.lowercased()) to your next message")
    }
}

/// Shows which page the assistant context buttons will read from. Follows
/// the active tab automatically as the user switches pages.
@MainActor
private struct CurrentPageBar: View {
    let model: BrowserWindowModel

    private var tab: BrowserTab? {
        guard let tab = model.activeTab, tab.lastCommittedURL != nil else { return nil }
        return tab
    }

    var body: some View {
        if let tab, let url = tab.lastCommittedURL {
            HStack(spacing: 7) {
                if let favicon = model.favicons.image(for: url) {
                    Image(nsImage: favicon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 13, height: 13)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.browsemiumTertiary)
                        .frame(width: 13, height: 13)
                }

                Text(tab.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.browsemiumPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                Text(url.host ?? "")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.browsemiumTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .fill(Color.browsemiumField.opacity(0.6))
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Context will be captured from \(tab.title)")
            .animation(.easeOut(duration: 0.15), value: tab.id)
        }
    }
}

@MainActor
private struct AttachmentChip: View {
    let label: String
    var thumbnail: NSImage? = nil
    var dragProvider: (() -> NSItemProvider)? = nil
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 30, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "paperclip")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.browsemiumTertiary)
            }
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.browsemiumSecondary)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.browsemiumTertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(label)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(isHovering ? Color.browsemiumSelection : Color.browsemiumField)
        )
        .onHover { isHovering = $0 }
        .modifier(DraggableAttachment(provider: dragProvider))
    }
}

/// Makes a chip a drag source when it has something to hand over.
private struct DraggableAttachment: ViewModifier {
    let provider: (() -> NSItemProvider)?

    func body(content: Content) -> some View {
        if let provider {
            content.onDrag { provider() }
        } else {
            content
        }
    }
}

@MainActor
private struct AIChatTranscript: View {
    @Bindable var ai: AIDockViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if ai.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Attach page context, then ask.")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Color.browsemiumPrimary)
                            Text("Nothing leaves your Mac until you confirm it in the review sheet.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.browsemiumSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                                .fill(Color.browsemiumField)
                        )
                    }

                    ForEach(ai.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: ai.messages.last?.content) {
                if let last = ai.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

@MainActor
private struct MessageBubble: View {
    let message: AIMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role == .user ? "You" : "Assistant")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.browsemiumTertiary)
            messageBody
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var messageBody: some View {
        if message.role == .assistant {
            let document = SafeMarkdownDocument(source: message.content)
            VStack(alignment: .leading, spacing: 8) {
                if message.content.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                }
                ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
                if !document.links.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(document.links, id: \.url) { link in
                            Link(destination: link.url) {
                                Text(link.text.isEmpty ? link.url.absoluteString : link.text)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Color.browsemiumAccent)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        } else {
            Text(message.content)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.browsemiumPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                        .fill(Color.browsemiumField)
                )
        }
    }

    @ViewBuilder
    private func blockView(_ block: SafeMarkdownDocument.Block) -> some View {
        switch block {
        case .heading(_, let text):
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.browsemiumPrimary)
        case .paragraph(let text), .quote(let text):
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.browsemiumPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .codeBlock(_, let code):
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.browsemiumPrimary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.browsemiumCanvas)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text("• \(item)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.browsemiumPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    Text("\(index + 1). \(item)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.browsemiumPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .rule:
            Rectangle()
                .fill(Color.browsemiumBorder)
                .frame(height: 1)
        }
    }
}

@MainActor
private struct ProviderPanelHost: NSViewRepresentable {
    let controller: ProviderPanelController
    let provider: AIProviderID
    let revision: Int

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Revision is intentionally read by the representable. It forces an
        // update after memory pressure or profile changes release the current
        // WebView, instead of leaving a detached/blank panel on screen.
        _ = revision
        let webView = controller.webView(for: provider)
        // Switching providers must not leave the previous webview stacked
        // in the container — remove anything that is not the current panel.
        for subview in nsView.subviews where subview !== webView {
            subview.removeFromSuperview()
        }
        if webView.superview !== nsView {
            webView.removeFromSuperview()
            webView.frame = nsView.bounds
            webView.autoresizingMask = [.width, .height]
            nsView.addSubview(webView)
        }
    }
}

@MainActor
struct AIContextReviewSheet: View {
    @Bindable var model: BrowserWindowModel
    @Bindable var ai: AIDockViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ai.mode == .web ? "Send to \(ai.descriptor.displayName)?" : "Send to \(ai.descriptor.displayName) API?")
                .font(.system(size: 15, weight: .semibold))

            Text(destinationDescription)
                .font(.system(size: 12))
                .foregroundStyle(Color.browsemiumSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if ai.attachmentLabels.isEmpty {
                Text("No page context attached. Only your message will be sent.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.browsemiumTertiary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Attached context")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.browsemiumTertiary)
                    ForEach(Array(ai.attachmentLabels.enumerated()), id: \.offset) { index, label in
                        HStack(spacing: 6) {
                            Text(label)
                                .font(.system(size: 12))
                            Spacer()
                            Button("Remove") { ai.removeAttachment(at: index) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.browsemiumDestructive)
                        }
                    }
                }
                .padding(10)
                .background(Color.browsemiumRaised)
                .clipShape(RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius))
            }

            if let note = ai.handoff?.note {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.browsemiumWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                BrowsemiumTextButton("Cancel") { ai.cancelReview() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if ai.mode == .web, let handoff = ai.handoff, handoff.method == .clipboardOnly {
                    BrowsemiumTextButton("Copy only") {
                        ai.copyToPasteboard(handoff)
                        model.statusMessage = "Context copied — paste it into \(ai.descriptor.displayName) with ⌘V"
                        ai.cancelReview()
                    }
                }
                BrowsemiumPrimaryButton(confirmButtonTitle) {
                    Task {
                        await ai.confirmSend(tabID: model.session.activeTabID)
                        if ai.mode == .web, let handoff = ai.handoff {
                            switch handoff.method {
                            case .clipboardOnly:
                                model.statusMessage = "Context copied — paste it into \(ai.descriptor.displayName) with ⌘V"
                            case .prefilledURL where handoff.includesImage:
                                model.statusMessage = "Prompt opened — the screenshot is on your clipboard, press ⌘V in \(ai.descriptor.displayName) to attach it"
                            case .prefilledURL:
                                break
                            }
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
        .background(Color.browsemiumSurface)
        .foregroundStyle(Color.browsemiumPrimary)
    }

    private var confirmButtonTitle: String {
        guard ai.mode == .web else { return "Send to API" }
        if ai.handoff?.method == .clipboardOnly {
            return "Copy & open \(ai.descriptor.displayName)"
        }
        return "Open in \(ai.descriptor.displayName)"
    }

    private var destinationDescription: String {
        switch ai.mode {
        case .web:
            let descriptor = ai.descriptor
            let host = descriptor.baseURL.host ?? descriptor.displayName
            return "This opens \(descriptor.displayName) at \(host) inside Browsemium. Your existing subscription and that site's policies apply."
        case .api:
            let modelName = ai.selectedModel?.name ?? "the selected model"
            return "This sends your message and the attached context to the \(ai.descriptor.displayName) API using \(modelName). Browsemium never stores your key outside the macOS keychain."
        }
    }
}
