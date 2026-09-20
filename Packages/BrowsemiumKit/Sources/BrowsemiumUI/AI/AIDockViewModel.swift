import AppKit
import BrowsemiumAI
import BrowsemiumCore
import BrowsemiumData
import BrowsemiumEngine
import Foundation
import Observation
import UniformTypeIdentifiers

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
    private static let maximumFileBytes: Int64 = 25 * 1024 * 1024
    private static let maximumTotalFileBytes: Int64 = 50 * 1024 * 1024
    private static let allowedFileTypes: [UTType] = [
        .image,
        .pdf,
        .plainText,
        .json,
        .commaSeparatedText,
        UTType(filenameExtension: "md") ?? .plainText
    ]

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
    private let attachmentDirectory: URL
    private var providerImageURLs: [URL] = []
    /// Changes whenever the page-specific context is invalidated. Async page
    /// capture must never re-attach content from a tab the user has already
    /// left.
    private var contextGeneration: UInt64 = 0
    private var activeWebPreparationGeneration: UInt64?

    public init(environment: BrowserEnvironment) {
        self.environment = environment
        attachmentDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Browsemium-AI-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: attachmentDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
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
        case .fullPageImage(let image):
            "Full page · \(image.width)×\(image.height)"
        case .file(let file):
            "\(file.filename) · \(Self.byteCountDescription(file.byteCount))"
        }
    }

    public func thumbnail(for attachment: AIContextAttachment) -> NSImage? {
        switch attachment {
        case .viewportImage(let image), .fullPageImage(let image):
            return NSImage(data: image.data)
        case .file(let file):
            guard UTType(mimeType: file.mimeType)?.conforms(to: .image) == true else { return nil }
            return NSImage(contentsOf: file.fileURL)
        default:
            return nil
        }
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
                case (.fullPageImage, .fullPageImage):
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
        let removed = attachments.remove(at: index)
        removeStagedFile(for: removed)
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
                case (.fullPageImage, .fullPageImage):
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
        contextGeneration &+= 1
        activeWebPreparationGeneration = nil
        for attachment in attachments {
            removeStagedFile(for: attachment)
        }
        attachments.removeAll()
        removeProviderImages()
    }

    /// Presents the native picker and stages validated files in an app-owned
    /// temporary directory. The provider never receives the user's original
    /// path; only the staged copy is handed to an explicit upload boundary.
    public func addFiles() {
        let panel = NSOpenPanel()
        panel.title = "Add files to Browsemium AI"
        panel.message = "Choose images, PDFs, or text documents to attach."
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.allowedFileTypes
        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            do {
                try stageFile(at: url)
            } catch {
                errorMessage = error.localizedDescription
                break
            }
        }
    }

    private func stageFile(at sourceURL: URL) throws {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let values = try sourceURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentTypeKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw BrowsemiumError.fileNotAllowed("That item is not a regular file.")
        }
        let byteCount = Int64(values.fileSize ?? 0)
        guard byteCount <= Self.maximumFileBytes else {
            throw BrowsemiumError.fileTooLarge("\(sourceURL.lastPathComponent) is larger than 25 MB.")
        }
        let type = values.contentType
            ?? UTType(filenameExtension: sourceURL.pathExtension)
        guard let type, Self.allowedFileTypes.contains(where: { type.conforms(to: $0) }) else {
            throw BrowsemiumError.fileNotAllowed("\(sourceURL.lastPathComponent) is not a supported AI attachment.")
        }
        let total = attachments.reduce(Int64(0)) { partial, attachment in
            guard case .file(let file) = attachment else { return partial }
            return partial + file.byteCount
        }
        guard total + byteCount <= Self.maximumTotalFileBytes else {
            throw BrowsemiumError.fileTooLarge("Attachments are limited to 50 MB per message.")
        }

        let safeName = Self.safeFilename(sourceURL.lastPathComponent)
        let destination = attachmentDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(safeName)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            throw BrowsemiumError.fileUnavailable("Browsemium could not stage \(safeName).")
        }

        let mimeType = type.preferredMIMEType ?? "application/octet-stream"
        attachments.append(.file(AIFileAttachment(
            fileURL: destination,
            filename: safeName,
            mimeType: mimeType,
            byteCount: byteCount
        )))
        errorMessage = nil
    }

    private func removeStagedFile(for attachment: AIContextAttachment) {
        guard case .file(let file) = attachment else { return }
        let root = attachmentDirectory.standardizedFileURL.path
        let candidate = file.fileURL.standardizedFileURL
        guard candidate.path.hasPrefix(root + "/") else { return }
        try? FileManager.default.removeItem(at: candidate)
    }

    private static func safeFilename(_ filename: String) -> String {
        let base = URL(fileURLWithPath: filename).lastPathComponent
        let cleaned = base.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == "\\" {
                return "_"
            }
            return Character(String(scalar))
        }
        let result = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "attachment" : String(result.prefix(180))
    }

    private static func byteCountDescription(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Called by the provider bridge after the user presses Send in Web mode.
    /// The active tab is supplied at that moment, so a fast tab switch cannot
    /// attach context from the previous page. Automatic capture happens before
    /// the provider's original gesture is replayed, so a failed capture leaves
    /// the provider draft untouched instead of sending incomplete context.
    public func prepareWebProviderMessage(
        userPrompt: String,
        tab: BrowserTab?
    ) async throws -> ProviderComposerPreparation {
        let generation = contextGeneration
        var prepared = false
        isWorking = true
        defer {
            isWorking = false
            if !prepared, activeWebPreparationGeneration == generation {
                activeWebPreparationGeneration = nil
            }
            if !prepared {
                removeProviderImages()
            }
        }

        func verifyContextIsCurrent() throws {
            guard contextGeneration == generation else {
                throw BrowsemiumError.captureUnavailable("The active page changed while context was being prepared. Press Send again for the current page.")
            }
        }

        try verifyContextIsCurrent()
        let settings = environment.loadSettings()
        removeProviderImages()
        let metadata = settings.includePageMetadataInWebAI
            ? PageMetadataContext(title: tab?.title, url: tab?.lastCommittedURL)
            : nil

        if settings.includePageMetadataInWebAI,
           let tab,
           let url = tab.lastCommittedURL,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            let hasReadablePage = attachments.contains { attachment in
                if case .readablePage = attachment { return true }
                return false
            }
            let hasFullPageImage = attachments.contains { attachment in
                if case .fullPageImage = attachment { return true }
                return false
            }

            // Rich context is deliberately best-effort. A page without an
            // article, a browser PDF, or a transient WebKit snapshot failure
            // must not prevent the provider from receiving the user's query
            // and sanitized metadata. Each capture is independent so a text
            // extraction failure cannot suppress a usable screenshot.
            if !hasReadablePage,
               let captured = try? await environment.runtime.capture(
                   tabID: tab.id,
                   request: CaptureRequest(kinds: [.readablePage])
               ) {
                try verifyContextIsCurrent()
                attachments.append(contentsOf: captured.attachments)
            }
            if !hasFullPageImage,
               let captured = try? await environment.runtime.capture(
                   tabID: tab.id,
                   request: CaptureRequest(kinds: [.fullPageImage])
               ) {
                try verifyContextIsCurrent()
                attachments.append(contentsOf: captured.attachments)
            }
        }

        try verifyContextIsCurrent()
        let prompt = AIRequestBuilder.composeWebPrompt(
            userPrompt: userPrompt,
            metadata: metadata,
            attachments: attachments
        )
        var fileURLs = attachments.compactMap { attachment -> URL? in
            guard case .file(let file) = attachment else { return nil }
            return file.fileURL
        }
        for attachment in attachments {
            let image: PageImageContext?
            switch attachment {
            case .viewportImage(let value), .fullPageImage(let value):
                image = value
            default:
                image = nil
            }
            guard let image else { continue }
            let ext = image.mimeType == "image/jpeg" ? "jpg" : "png"
            let url = attachmentDirectory
                .appendingPathComponent("provider-\(UUID().uuidString).\(ext)")
            try image.data.write(to: url, options: [.atomic])
            providerImageURLs.append(url)
            fileURLs.append(url)
        }
        try verifyContextIsCurrent()
        activeWebPreparationGeneration = generation
        prepared = true
        return ProviderComposerPreparation(text: prompt, fileURLs: fileURLs)
    }

    public func finishWebProviderMessage() {
        guard let generation = activeWebPreparationGeneration,
              generation == contextGeneration else {
            // A tab switch or a new context selection invalidated this send.
            // Do not clear the new context that the user may already be
            // preparing; only discard files owned by the stale attempt.
            removeProviderImages()
            activeWebPreparationGeneration = nil
            return
        }
        draft = ""
        let stagedURLs = attachments.compactMap { attachment -> URL? in
            guard case .file(let file) = attachment else { return nil }
            return file.fileURL
        } + providerImageURLs
        attachments.removeAll()
        providerImageURLs.removeAll()
        contextGeneration &+= 1
        activeWebPreparationGeneration = nil
        scheduleCleanup(of: stagedURLs)
        errorMessage = nil
    }

    private func removeProviderImages() {
        for url in providerImageURLs {
            try? FileManager.default.removeItem(at: url)
        }
        providerImageURLs.removeAll()
    }

    /// A provider may begin its network upload after the native send gesture
    /// returns. Keep staged files briefly after a successful replay so an
    /// asynchronous provider upload cannot observe a path that Browsemium has
    /// already deleted. The files are still app-owned, bounded, and removed
    /// automatically without retaining a reference to the user-selected path.
    private func scheduleCleanup(of urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard !Task.isCancelled else { return }
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
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
            // The prompt travels inside the URL; rich attachments do not. Put
            // the full handoff on the pasteboard so a single ⌘V preserves the
            // user's explicit attachment choice when the provider requires it.
            if handoff.includesImage || handoff.includesFiles {
                copyToPasteboard(handoff)
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
        clearAttachments()
    }

    public func copyToPasteboard(_ handoff: ProviderHandoff) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var objects: [NSPasteboardWriting] = [handoff.prompt as NSString]
        for attachment in attachments {
            switch attachment {
            case .viewportImage(let image), .fullPageImage(let image):
                if let nsImage = NSImage(data: image.data) { objects.append(nsImage) }
            case .file(let file):
                objects.append(file.fileURL as NSURL)
            default:
                break
            }
        }
        pasteboard.writeObjects(objects)
    }

    private func copyImagesToPasteboard() {
        let images: [NSPasteboardWriting] = attachments.compactMap { attachment in
            let nsImage: NSImage?
            switch attachment {
            case .viewportImage(let image), .fullPageImage(let image):
                nsImage = NSImage(data: image.data)
            case .file(let file):
                nsImage = NSImage(contentsOf: file.fileURL)
            default:
                nsImage = nil
            }
            guard let nsImage else { return nil }
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
