import AppKit
import BrowsemiumAI
import BrowsemiumCore
import BrowsemiumData
import BrowsemiumEngine
import Foundation
import Observation

public enum AIDockMode: String, CaseIterable, Identifiable, Sendable {
    case web
    case api

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .web: "Web"
        case .api: "API"
        }
    }
}

@MainActor
@Observable
public final class AIDockViewModel {
    public let environment: BrowserEnvironment

    public var mode: AIDockMode = .web
    public var provider: AIProviderID = .openAI
    public var models: [AIModel] = []
    public var selectedModelID: String?
    public var credentialInput: String = ""
    public var credentialStatus: String?
    public var hasStoredCredential: Bool = false
    public var messages: [AIMessage] = []
    public var draft: String = ""
    public var isStreaming: Bool = false
    public var isWorking: Bool = false
    public var errorMessage: String?
    public var attachments: [AIContextAttachment] = []
    public var handoff: ProviderHandoff?
    public var isReviewPresented: Bool = false
    public var reviewPrompt: String = ""

    private var streamTask: Task<Void, Never>?

    public init(environment: BrowserEnvironment) {
        self.environment = environment
        // Deliberately no keychain work here: this runs at launch, and any
        // keychain read at launch produces a macOS permission prompt.
    }

    public var descriptor: ProviderPanelDescriptor {
        ProviderPanelDescriptor.descriptor(for: provider)
    }

    public var selectedModel: AIModel? {
        guard let selectedModelID else { return models.first }
        return models.first { $0.id == selectedModelID } ?? models.first
    }

    public var attachmentLabels: [String] {
        attachments.map(label(for:))
    }

    public func label(for attachment: AIContextAttachment) -> String {
        switch attachment {
        case .selection(let context):
            "Selection · \(context.text.count) characters\(source(of: context))"
        case .readablePage(let context):
            "Page text · \(context.text.count) characters\(context.isTruncated ? " (trimmed)" : "")\(source(of: context))"
        case .viewportImage(let image):
            "Screenshot · \(image.width)×\(image.height)"
        }
    }

    public func thumbnail(for attachment: AIContextAttachment) -> NSImage? {
        guard case .viewportImage(let image) = attachment else { return nil }
        return NSImage(data: image.data)
    }

    private func source(of context: PageTextContext) -> String {
        context.url?.host.map { " · \($0)" } ?? ""
    }

    public var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStreaming
    }

    private var credentialAccount: String {
        "provider.\(provider.rawValue)"
    }

    public func refreshCredentialState() {
        hasStoredCredential = (try? environment.keychain.hasSecret(account: credentialAccount)) ?? false
    }

    public func connect() async {
        credentialStatus = nil
        let credential = credentialInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else {
            credentialStatus = "Enter an API key first."
            return
        }
        isWorking = true
        defer { isWorking = false }

        do {
            let adapter = makeAdapter(credential: credential)
            let fetched = try await adapter.listModels()
            try environment.keychain.setSecret(credential, account: credentialAccount)
            hasStoredCredential = true
            credentialInput = ""
            models = fetched.sorted { $0.id < $1.id }
            if selectedModelID == nil {
                selectedModelID = models.first?.id
            }
            credentialStatus = "Connected. \(models.count) models available."
            errorMessage = nil
        } catch {
            credentialStatus = nil
            errorMessage = error.localizedDescription
        }
    }

    public func loadModels() async {
        guard let credential = try? environment.keychain.secret(account: credentialAccount), !credential.isEmpty else {
            refreshCredentialState()
            return
        }
        credentialStatus = nil
        isWorking = true
        defer { isWorking = false }
        do {
            models = try await makeAdapter(credential: credential).listModels().sorted { $0.id < $1.id }
            if selectedModelID == nil {
                selectedModelID = models.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func disconnect() {
        try? environment.keychain.deleteSecret(account: credentialAccount)
        hasStoredCredential = false
        models = []
        selectedModelID = nil
        credentialStatus = "Credential removed."
    }

    public func attach(_ kind: CaptureKind, tabID: TabID?) async {
        guard let tabID else {
            errorMessage = "Open a page before sharing context."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let captured = try await environment.runtime.capture(tabID: tabID, request: CaptureRequest(kinds: [kind]))
            // Keep one current attachment of each type. Recapturing replaces
            // stale content instead of silently sending multiple page versions.
            attachments.removeAll { attachment in
                switch (kind, attachment) {
                case (.selection, .selection), (.readablePage, .readablePage), (.viewportImage, .viewportImage):
                    true
                default:
                    false
                }
            }
            attachments.append(contentsOf: captured.attachments)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func removeAttachment(at index: Int) {
        guard attachments.indices.contains(index) else { return }
        attachments.remove(at: index)
    }

    public func clearAttachments() {
        attachments.removeAll()
    }

    public func clearConversation() {
        streamTask?.cancel()
        streamTask = nil
        messages.removeAll()
        isStreaming = false
        errorMessage = nil
    }

    public func beginReview() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        reviewPrompt = trimmed
        if mode == .web {
            handoff = ProviderHandoffBuilder().makeHandoff(
                provider: provider,
                userPrompt: trimmed,
                attachments: attachments
            )
        } else {
            handoff = nil
        }
        isReviewPresented = true
    }

    public func cancelReview() {
        isReviewPresented = false
        handoff = nil
    }

    public func confirmSend(tabID: TabID?) async {
        let prompt = reviewPrompt
        isReviewPresented = false

        switch mode {
        case .web:
            sendToProviderWebsite(prompt: prompt)
        case .api:
            await sendViaAPI(prompt: prompt)
        }
    }

    public func sendToProviderWebsite(prompt: String) {
        let handoff = ProviderHandoffBuilder().makeHandoff(
            provider: provider,
            userPrompt: prompt,
            attachments: attachments
        )
        self.handoff = handoff

        switch handoff.method {
        case .prefilledURL(let url):
            providerPanel.open(url: url, provider: provider)
            // The prompt travels inside the URL; images cannot. Put them on the
            // pasteboard so a single ⌘V attaches them in the provider's composer.
            if handoff.includesImage {
                copyImagesToPasteboard()
            }
        case .clipboardOnly:
            copyToPasteboard(handoff)
        }

        messages.append(AIMessage(role: .user, content: prompt))
        let note = handoff.note ?? "Sent to \(descriptor.displayName)."
        messages.append(AIMessage(role: .assistant, content: note))
        draft = ""
        attachments.removeAll()
    }

    public func copyToPasteboard(_ handoff: ProviderHandoff) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var objects: [NSPasteboardWriting] = [handoff.prompt as NSString]
        for attachment in attachments {
            if case .viewportImage(let image) = attachment, let nsImage = NSImage(data: image.data) {
                objects.append(nsImage)
            }
        }
        pasteboard.writeObjects(objects)
    }

    private func copyImagesToPasteboard() {
        let images: [NSPasteboardWriting] = attachments.compactMap { attachment in
            guard case .viewportImage(let image) = attachment,
                  let nsImage = NSImage(data: image.data) else { return nil }
            return nsImage
        }
        guard !images.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(images)
    }

    private func sendViaAPI(prompt: String) async {
        guard let model = selectedModel else {
            errorMessage = "Choose a model first."
            return
        }
        guard let credential = try? environment.keychain.secret(account: credentialAccount), !credential.isEmpty else {
            errorMessage = "Connect an API key for \(descriptor.displayName) first."
            return
        }

        messages.append(AIMessage(role: .user, content: prompt))
        let assistantIndex = messages.count
        messages.append(AIMessage(role: .assistant, content: ""))
        let request = AIRequest(model: model, messages: Array(messages.prefix(assistantIndex)), attachments: attachments)
        let adapter = makeAdapter(credential: credential)
        isStreaming = true
        errorMessage = nil
        draft = ""
        attachments.removeAll()

        streamTask = Task { [weak self] in
            do {
                for try await event in adapter.stream(request) {
                    guard let self else { return }
                    switch event {
                    case .textDelta(let text):
                        self.appendToAssistant(at: assistantIndex, text: text)
                    case .completed(let message):
                        self.finalizeAssistant(at: assistantIndex, content: message.content)
                    }
                }
            } catch {
                guard let self else { return }
                self.errorMessage = error.localizedDescription
                self.removeAssistantIfEmpty(at: assistantIndex)
            }
            self?.isStreaming = false
        }
    }

    public func stop() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }

    private func appendToAssistant(at index: Int, text: String) {
        guard messages.indices.contains(index) else { return }
        let current = messages[index]
        messages[index] = AIMessage(id: current.id, role: .assistant, content: current.content + text, createdAt: current.createdAt)
    }

    private func finalizeAssistant(at index: Int, content: String) {
        guard messages.indices.contains(index) else { return }
        let current = messages[index]
        messages[index] = AIMessage(id: current.id, role: .assistant, content: content, createdAt: current.createdAt)
    }

    private func removeAssistantIfEmpty(at index: Int) {
        guard messages.indices.contains(index), messages[index].content.isEmpty else { return }
        messages.remove(at: index)
    }

    private func makeAdapter(credential: String) -> any AIProviderAdapter {
        switch provider {
        case .openAI:
            OpenAIAdapter(credential: credential)
        case .anthropic:
            AnthropicAdapter(credential: credential)
        case .gemini:
            GeminiAdapter(credential: credential)
        case .xAI:
            XAIAdapter(credential: credential)
        }
    }

    public let providerPanel = ProviderPanelController()
}
