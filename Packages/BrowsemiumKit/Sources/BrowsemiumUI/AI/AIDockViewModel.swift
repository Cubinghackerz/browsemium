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
    public private(set) var conversationList: [AIConversationSummary] = []
    public private(set) var currentConversationID: ConversationID?

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
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) && !isStreaming
    }

    private var credentialAccount: String {
        environment.providerCredentialAccount(provider)
    }

    public func refreshCredentialState() {
        // A local Ollama server needs no credential; treat it as always ready.
        if provider.isLocal {
            hasStoredCredential = true
            return
        }
        hasStoredCredential = (try? environment.keychain.hasSecret(account: credentialAccount)) ?? false
    }

    public func connect() async {
        credentialStatus = nil
        if provider.isLocal {
            // No key: probe the local server and report what it offers.
            isWorking = true
            defer { isWorking = false }
            do {
                let fetched = try await OllamaAdapter().listModels()
                models = fetched
                if selectedModelID == nil {
                    selectedModelID = models.first?.id
                }
                hasStoredCredential = true
                credentialStatus = fetched.isEmpty
                    ? "Ollama is running, but it has no models yet. Pull one with `ollama pull llama3.2`."
                    : "Connected to Ollama on this Mac. \(models.count) models available."
                errorMessage = nil
            } catch {
                credentialStatus = nil
                errorMessage = "Ollama is not reachable at localhost:11434. Install it from ollama.com and run `ollama serve`."
            }
            return
        }
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
        if provider.isLocal {
            isWorking = true
            defer { isWorking = false }
            do {
                models = try await OllamaAdapter().listModels()
                if selectedModelID == nil {
                    selectedModelID = models.first?.id
                }
            } catch {
                errorMessage = "Ollama is not reachable at localhost:11434."
            }
            return
        }
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
        // If the review sheet is open the handoff was built with the removed
        // attachment — rebuild it so the note matches what will actually send.
        if isReviewPresented {
            rebuildHandoff()
        }
    }

    /// Adopts context captured outside the dock (the page context menu),
    /// replacing any attachment of the same kind so stale content never
    /// travels with a new selection.
    public func adopt(_ incoming: [AIContextAttachment]) {
        for attachment in incoming {
            attachments.removeAll { existing in
                switch (attachment, existing) {
                case (.selection, .selection), (.readablePage, .readablePage), (.viewportImage, .viewportImage):
                    true
                default:
                    false
                }
            }
            attachments.append(attachment)
        }
        errorMessage = nil
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
        currentConversationID = nil
    }

    // MARK: - Persisted conversations

    private var shouldPersistConversations: Bool {
        environment.loadSettings().persistAIConversations
    }

    public func refreshConversations() {
        conversationList = (try? environment.conversationRepository.conversations()) ?? []
    }

    /// Restores the most recent conversation once per launch, so a restart
    /// does not lose an in-progress chat.
    public func restoreLastConversationIfNeeded() {
        refreshConversations()
        guard messages.isEmpty,
              shouldPersistConversations,
              let latest = conversationList.first else { return }
        openConversation(latest.id)
    }

    public func openConversation(_ id: ConversationID) {
        guard let restored = try? environment.conversationRepository.messages(conversationID: id) else { return }
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        messages = restored
        currentConversationID = id
        errorMessage = nil
    }

    public func deleteConversation(_ id: ConversationID) {
        try? environment.conversationRepository.delete(conversationID: id)
        if currentConversationID == id {
            clearConversation()
        }
        refreshConversations()
    }

    private func persistUserMessage(_ content: String) {
        guard shouldPersistConversations else { return }
        do {
            if currentConversationID == nil {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = String(trimmed.prefix(60))
                currentConversationID = try environment.conversationRepository.createConversation(
                    title: title.isEmpty ? "Conversation" : title
                )
            }
            if let id = currentConversationID {
                try environment.conversationRepository.appendMessage(
                    conversationID: id,
                    role: .user,
                    content: content
                )
            }
            refreshConversations()
        } catch {
            // Persistence is best-effort; the chat itself keeps working.
        }
    }

    private func persistAssistantMessage(_ content: String) {
        guard shouldPersistConversations,
              let id = currentConversationID,
              !content.isEmpty else { return }
        try? environment.conversationRepository.appendMessage(
            conversationID: id,
            role: .assistant,
            content: content
        )
        refreshConversations()
    }

    public func beginReview() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        reviewPrompt = trimmed
        rebuildHandoff()
        isReviewPresented = true
    }

    /// Builds (or clears) the pending web handoff from the current prompt and
    /// attachments. Called when the review opens and again whenever an
    /// attachment is removed while it is open.
    private func rebuildHandoff() {
        if mode == .web {
            handoff = ProviderHandoffBuilder().makeHandoff(
                provider: provider,
                userPrompt: reviewPrompt,
                attachments: attachments
            )
        } else {
            handoff = nil
        }
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
        persistUserMessage(prompt)
        let note = handoff.note ?? "Sent to \(descriptor.displayName)."
        messages.append(AIMessage(role: .assistant, content: note))
        persistAssistantMessage(note)
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
        let credential: String
        if provider.isLocal {
            credential = ""
        } else {
            guard let stored = try? environment.keychain.secret(account: credentialAccount), !stored.isEmpty else {
                errorMessage = "Connect an API key for \(descriptor.displayName) first."
                return
            }
            credential = stored
        }

        messages.append(AIMessage(role: .user, content: prompt))
        persistUserMessage(prompt)
        let assistantIndex = messages.count
        messages.append(AIMessage(role: .assistant, content: ""))
        let request = AIRequest(model: model, messages: Array(messages.prefix(assistantIndex)), attachments: attachments)
        let adapter = makeAdapter(credential: credential)
        let sentAttachments = attachments
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
                        self.persistAssistantMessage(message.content)
                    }
                }
            } catch {
                guard let self else { return }
                // A user-initiated stop is not an error worth shouting about;
                // keep whatever partial answer arrived and stay quiet.
                if !(error is CancellationError) {
                    self.errorMessage = error.localizedDescription
                    // Give the attachments back so a retry keeps its context.
                    if self.attachments.isEmpty {
                        self.attachments = sentAttachments
                    }
                }
                if self.messages.indices.contains(assistantIndex),
                   !self.messages[assistantIndex].content.isEmpty {
                    // Keep the partial answer rather than losing it.
                    self.persistAssistantMessage(self.messages[assistantIndex].content)
                }
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
        case .ollama:
            OllamaAdapter()
        }
    }

    public let providerPanel = ProviderPanelController()
}
