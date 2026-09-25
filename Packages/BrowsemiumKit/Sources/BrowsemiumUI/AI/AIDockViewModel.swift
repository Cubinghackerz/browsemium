import AppKit
import BrowsemiumAI
import BrowsemiumCore
import BrowsemiumData
import BrowsemiumEngine
import Foundation
import Observation
import UniformTypeIdentifiers
import BrowsemiumEngineKit

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
    private var streamGeneration: UInt64 = 0
    private var activeStreamAttachments: [AIContextAttachment] = []
    private var activeStreamAssistantID: UUID?
    private var activeStreamRestoreAllowed = true
    private let attachmentDirectory: URL
    private var providerImageURLsByPreparation: [UUID: [URL]] = [:]
    /// The send that most recently failed mid-flight. Retrying resends this
    /// exact payload — the user already reviewed it — without duplicating the
    /// user message in the transcript or the stored conversation.
    public private(set) var lastFailedSend: (prompt: String, attachments: [AIContextAttachment])?
    private var workGeneration: UInt64 = 0
    /// Changes whenever the page-specific context is invalidated. Async page
    /// capture must never re-attach content from a tab the user has already
    /// left.
    private var contextGeneration: UInt64 = 0
    private struct WebPreparationState {
        let id: UUID
        let provider: AIProviderID
        let generation: UInt64
    }
    private var activeWebPreparation: WebPreparationState?

    public init(environment: BrowserEnvironment) {
        self.environment = environment
        attachmentDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Browsemium-AI-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: attachmentDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        providerPanel.setStagedFileRoot(attachmentDirectory)
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

    private func beginWork() -> UInt64 {
        workGeneration &+= 1
        isWorking = true
        return workGeneration
    }

    private func endWork(_ generation: UInt64) {
        guard workGeneration == generation else { return }
        isWorking = false
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

    /// Resets provider-scoped UI and cancels work that belongs to the old
    /// provider. Keeping the old model list here makes a provider switch look
    /// successful while sending the next prompt to the wrong model.
    public func providerDidChange() {
        stop()
        contextGeneration &+= 1
        invalidateWebProviderPreparation()
        if provider.isLocal {
            mode = .api
        }
        models = []
        selectedModelID = nil
        credentialInput = ""
        credentialStatus = nil
        errorMessage = nil
        refreshCredentialState()
        if isReviewPresented {
            rebuildHandoff()
        }

        let requestedProvider = provider
        if requestedProvider.isLocal || hasStoredCredential {
            Task { [weak self] in
                await self?.loadModels(for: requestedProvider)
            }
        }
    }

    public func connect() async {
        let requestedProvider = provider
        let requestedAccount = environment.providerCredentialAccount(requestedProvider)
        credentialStatus = nil
        if requestedProvider.isLocal {
            // No key: probe the local server and report what it offers.
            let work = beginWork()
            defer { endWork(work) }
            do {
                let fetched = try await OllamaAdapter().listModels()
                guard provider == requestedProvider else { return }
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
                guard provider == requestedProvider else { return }
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
        let work = beginWork()
        defer { endWork(work) }

        do {
            let adapter = makeAdapter(for: requestedProvider, credential: credential)
            let fetched = try await adapter.listModels()
            try environment.keychain.setSecret(credential, account: requestedAccount)
            guard provider == requestedProvider else { return }
            hasStoredCredential = true
            credentialInput = ""
            models = fetched.sorted { $0.id < $1.id }
            if selectedModelID == nil {
                selectedModelID = models.first?.id
            }
            credentialStatus = "Connected. \(models.count) models available."
            errorMessage = nil
        } catch {
            guard provider == requestedProvider else { return }
            credentialStatus = nil
            errorMessage = error.localizedDescription
        }
    }

    public func loadModels() async {
        await loadModels(for: provider)
    }

    private func loadModels(for requestedProvider: AIProviderID) async {
        if requestedProvider.isLocal {
            let work = beginWork()
            defer { endWork(work) }
            do {
                let fetched = try await OllamaAdapter().listModels()
                guard provider == requestedProvider else { return }
                models = fetched
                if selectedModelID == nil {
                    selectedModelID = models.first?.id
                }
            } catch {
                guard provider == requestedProvider else { return }
                errorMessage = "Ollama is not reachable at localhost:11434."
            }
            return
        }
        let account = environment.providerCredentialAccount(requestedProvider)
        guard let credential = try? environment.keychain.secret(account: account), !credential.isEmpty else {
            refreshCredentialState()
            return
        }
        credentialStatus = nil
        let work = beginWork()
        defer { endWork(work) }
        do {
            let fetched = try await makeAdapter(for: requestedProvider, credential: credential)
                .listModels()
                .sorted { $0.id < $1.id }
            guard provider == requestedProvider else { return }
            models = fetched
            if selectedModelID == nil {
                selectedModelID = models.first?.id
            }
        } catch {
            guard provider == requestedProvider else { return }
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
        guard !isWorking else { return }
        let generation = contextGeneration
        let work = beginWork()
        defer { endWork(work) }
        do {
            let captured = try await environment.engine.capture(tabID: tabID, request: CaptureRequest(kinds: [kind]))
            guard contextGeneration == generation else { return }
            // Replace stale content instead of sending several versions of
            // the same thing. Page text is keyed by URL, so re-capturing the
            // active page leaves other tabs' text attached; selections and
            // screenshots stay singular.
            var capturedURLs = Set<URL>()
            var capturedPagesWithoutURL = false
            for attachment in captured.attachments {
                guard case .readablePage(let context) = attachment else { continue }
                if let url = context.url {
                    capturedURLs.insert(url)
                } else {
                    capturedPagesWithoutURL = true
                }
            }
            attachments.removeAll { attachment in
                switch (kind, attachment) {
                case (.selection, .selection), (.viewportImage, .viewportImage), (.fullPageImage, .fullPageImage):
                    true
                case (.readablePage, .readablePage(let existing)):
                    if let url = existing.url {
                        capturedURLs.contains(url)
                    } else {
                        capturedPagesWithoutURL
                    }
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

    /// One-tap workflow: capture the action's context, load its prompt, and
    /// open the review sheet. The sheet still gates the send — a quick action
    /// is a shortcut to a review, never a silent transmit.
    public func runQuickAction(_ action: AIQuickAction, tabID: TabID?) async {
        guard let tabID else {
            errorMessage = "Open a page before using assistant actions."
            return
        }
        guard !isWorking else { return }
        await attach(action.captureKind, tabID: tabID)
        if errorMessage == nil && attachments.isEmpty {
            errorMessage = "Nothing on this page could be captured."
        }
        guard errorMessage == nil else { return }
        // Respect a draft the user already typed: it stays the instruction for
        // the captured context. The canned prompt only fills an empty field.
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = action.prompt
        }
        beginReview()
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

    /// Adopts context captured outside the dock (the page context menu, or
    /// several tabs at once), replacing stale content so nothing from a
    /// previous capture travels with a new request.
    ///
    /// Page text is keyed by URL: re-capturing one page replaces its own
    /// entry, while other tabs' text stays — multi-tab requests carry one
    /// readable page per tab. Selections and screenshots stay singular.
    public func adopt(_ incoming: [AIContextAttachment]) {
        contextGeneration &+= 1
        activeStreamRestoreAllowed = false
        invalidateWebProviderPreparation()
        for attachment in incoming {
            attachments.removeAll { existing in
                switch (attachment, existing) {
                case (.selection, .selection), (.viewportImage, .viewportImage), (.fullPageImage, .fullPageImage):
                    true
                case (.readablePage(let new), .readablePage(let old)):
                    new.url == old.url || (new.url == nil && old.url == nil)
                default:
                    false
                }
            }
            attachments.append(attachment)
        }
        errorMessage = nil
    }

    /// Adopts page text from several tabs and stages the multi-tab prompt.
    /// The review sheet still gates the send.
    public func adoptTabsContext(_ incoming: [AIContextAttachment], prompt: String) {
        adopt(incoming)
        guard !attachments.isEmpty else { return }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = prompt
        }
        beginReview()
    }

    /// Fills the composer from a saved skill. Nothing is sent: the user
    /// still reads the prompt and presses send.
    public func applySkill(_ skill: AISkill) {
        draft = skill.prompt
        errorMessage = nil
    }

    /// Multi-tab summarization: capture each live tab's readable text and
    /// stage the prompt. The window model is passed in because tab state
    /// lives there, not in the assistant; tabs that never loaded are skipped
    /// by the capture with a status note, never woken silently.
    public func runMultiTabSummary(windowModel: BrowserWindowModel) async {
        let tabs = windowModel.tabsAvailableForAIContext()
        guard !tabs.isEmpty else {
            errorMessage = "Open another page first — there is only one live tab."
            return
        }
        let attachments = await windowModel.captureTabsForAI(tabs.map(\.id))
        guard !attachments.isEmpty else { return }
        adoptTabsContext(
            attachments,
            prompt: "Summarize these \(attachments.count) pages in a few short paragraphs, then note what they disagree about."
        )
    }

    public func clearAttachments() {
        contextGeneration &+= 1
        activeStreamRestoreAllowed = false
        activeWebPreparation = nil
        for attachment in attachments {
            removeStagedFile(for: attachment)
        }
        attachments.removeAll()
        removeProviderImages()
        if isReviewPresented {
            rebuildHandoff()
        }
    }

    /// Invalidates a pending web send without removing files the user has
    /// explicitly staged for a different provider.
    public func invalidateWebProviderPreparation() {
        activeWebPreparation = nil
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
        let root = attachmentDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let candidate = file.fileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return }
        try? FileManager.default.removeItem(at: candidate)
    }

    private func removeCapturedAttachments(_ captured: [AIContextAttachment]) {
        for generated in captured {
            guard let index = attachments.firstIndex(where: { sameAttachment($0, generated) }) else { continue }
            let removed = attachments.remove(at: index)
            removeStagedFile(for: removed)
        }
    }

    private func sameAttachment(_ lhs: AIContextAttachment, _ rhs: AIContextAttachment) -> Bool {
        switch (lhs, rhs) {
        case (.selection(let left), .selection(let right)):
            left == right
        case (.readablePage(let left), .readablePage(let right)):
            left == right
        case (.viewportImage(let left), .viewportImage(let right)):
            left == right
        case (.fullPageImage(let left), .fullPageImage(let right)):
            left == right
        case (.file(let left), .file(let right)):
            left == right
        default:
            false
        }
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
        tab: BrowserTab?,
        provider: AIProviderID
    ) async throws -> ProviderComposerPreparation {
        let generation = contextGeneration
        let preparationID = UUID()
        var generatedAttachments: [AIContextAttachment] = []
        var prepared = false
        let work = beginWork()
        defer {
            endWork(work)
            if !prepared, activeWebPreparation?.id == preparationID {
                activeWebPreparation = nil
            }
            if !prepared {
                removeCapturedAttachments(generatedAttachments)
                removeProviderImages(for: preparationID)
            }
        }

        func verifyContextIsCurrent() throws {
            try Task.checkCancellation()
            guard contextGeneration == generation, self.provider == provider else {
                throw BrowsemiumError.captureUnavailable("The active page or provider changed while context was being prepared. Press Send again.")
            }
        }

        try verifyContextIsCurrent()
        let settings = environment.loadSettings()
        removeProviderImages()
        let metadata = settings.includePageMetadataInWebAI
            ? PageMetadataContext(title: tab?.title, url: tab?.lastCommittedURL)
            : nil

        let hasReadablePage = attachments.contains { attachment in
            if case .readablePage = attachment { return true }
            return false
        }
        let automaticKinds = WebAIContextPolicy.automaticCaptureKinds(
            includePageContext: settings.includePageMetadataInWebAI,
            hasReadablePage: hasReadablePage,
            pageURL: tab?.lastCommittedURL
        )

        if automaticKinds.contains(.readablePage), let tab {
            // Automatic context is deliberately text and sanitized metadata
            // only. Screenshots and files remain explicit user attachments,
            // so a normal Send can never trigger an unexpected image upload.
            do {
                let captured = try await environment.engine.capture(
                    tabID: tab.id,
                    request: CaptureRequest(kinds: [.readablePage])
                )
                try verifyContextIsCurrent()
                generatedAttachments.append(contentsOf: captured.attachments)
                attachments.append(contentsOf: captured.attachments)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Readable text is best-effort; metadata and the user's query
                // still proceed when a page has no extractable article text.
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
            providerImageURLsByPreparation[preparationID, default: []].append(url)
            fileURLs.append(url)
        }
        try verifyContextIsCurrent()
        activeWebPreparation = WebPreparationState(
            id: preparationID,
            provider: provider,
            generation: generation
        )
        prepared = true
        return ProviderComposerPreparation(text: prompt, fileURLs: fileURLs, id: preparationID)
    }

    public func isWebProviderPreparationCurrent(provider: AIProviderID, id: UUID) -> Bool {
        guard let activeWebPreparation else { return false }
        return self.provider == provider
            && activeWebPreparation.id == id
            && activeWebPreparation.provider == provider
            && activeWebPreparation.generation == contextGeneration
    }

    public func finishWebProviderMessage(provider: AIProviderID, id: UUID) {
        guard isWebProviderPreparationCurrent(provider: provider, id: id) else {
            // A tab switch or a new context selection invalidated this send.
            // Do not clear the new context that the user may already be
            // preparing; only discard files owned by the stale attempt.
            removeProviderImages(for: id)
            if activeWebPreparation?.id == id {
                activeWebPreparation = nil
            }
            return
        }
        draft = ""
        let stagedURLs = attachments.compactMap { attachment -> URL? in
            guard case .file(let file) = attachment else { return nil }
            return file.fileURL
        } + (providerImageURLsByPreparation.removeValue(forKey: id) ?? [])
        attachments.removeAll()
        contextGeneration &+= 1
        activeWebPreparation = nil
        scheduleCleanup(of: stagedURLs)
        errorMessage = nil
    }

    public func abortWebProviderMessage(provider: AIProviderID, id: UUID) {
        removeProviderImages(for: id)
        if activeWebPreparation?.id == id,
           activeWebPreparation?.provider == provider {
            activeWebPreparation = nil
        }
    }

    private func removeProviderImages() {
        for urls in providerImageURLsByPreparation.values {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
        providerImageURLsByPreparation.removeAll()
    }

    private func removeProviderImages(for preparationID: UUID) {
        guard let urls = providerImageURLsByPreparation.removeValue(forKey: preparationID) else { return }
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
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
        stop()
        messages.removeAll()
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
        stop()
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

    public func beginReview(tabID: TabID? = nil) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        // API mode can opt into automatic page context. The capture must land
        // before the sheet opens so the review lists exactly what will send.
        if mode == .api,
           environment.loadSettings().includePageContextInAPIAI,
           !attachments.contains(where: { $0.isPageText }),
           let tabID {
            Task {
                await attach(.readablePage, tabID: tabID)
                presentReview()
            }
            return
        }
        presentReview()
    }

    private func presentReview() {
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

    /// Resends the last failed payload. The review sheet already gated this
    /// exact prompt and context, so retry goes straight to the provider.
    public func retryLastSend() {
        guard let failed = lastFailedSend, !isStreaming else { return }
        lastFailedSend = nil
        // The failed send left its user bubble in the transcript; remove it
        // so the resend does not show the question twice.
        if let index = messages.lastIndex(where: { $0.role == .user && $0.content == failed.prompt }) {
            messages.remove(at: index)
        }
        if attachments.isEmpty {
            attachments = failed.attachments
        }
        errorMessage = nil
        Task { await sendViaAPI(prompt: failed.prompt, skipPersistingUser: true) }
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

    private func sendViaAPI(prompt: String, skipPersistingUser: Bool = false) async {
        guard !isStreaming else { return }
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
        // A retry reuses the persisted copy of its user message — writing it
        // again would list the same question twice in the stored conversation.
        if !skipPersistingUser {
            persistUserMessage(prompt)
        }
        let assistantIndex = messages.count
        let assistant = AIMessage(role: .assistant, content: "")
        messages.append(assistant)
        let request = AIRequest(model: model, messages: Array(messages.prefix(assistantIndex)), attachments: attachments)
        let adapter = makeAdapter(credential: credential)
        let sentAttachments = attachments
        let sentStagedURLs = sentAttachments.compactMap { attachment -> URL? in
            guard case .file(let file) = attachment else { return nil }
            return file.fileURL
        }
        streamGeneration &+= 1
        let generation = streamGeneration
        isStreaming = true
        errorMessage = nil
        lastFailedSend = nil
        draft = ""
        attachments.removeAll()
        activeStreamAttachments = sentAttachments
        activeStreamAssistantID = assistant.id
        activeStreamRestoreAllowed = true

        streamTask = Task { [weak self] in
            var didComplete = false
            var didFail = false
            do {
                for try await event in adapter.stream(request) {
                    guard let self else { return }
                    guard self.streamGeneration == generation else { return }
                    switch event {
                    case .textDelta(let text):
                        self.appendToAssistant(at: assistantIndex, text: text)
                    case .completed(let message):
                        didComplete = true
                        self.finalizeAssistant(at: assistantIndex, content: message.content)
                        self.persistAssistantMessage(message.content)
                    }
                }
            } catch {
                guard let self else { return }
                guard self.streamGeneration == generation else { return }
                didFail = true
                // A user-initiated stop is not an error worth shouting about;
                // keep whatever partial answer arrived and stay quiet.
                _ = self.restoreOrCleanupStreamAttachments(sentAttachments)
                if !(error is CancellationError) {
                    self.errorMessage = error.localizedDescription
                    self.lastFailedSend = (prompt: prompt, attachments: sentAttachments)
                }
                if self.messages.indices.contains(assistantIndex),
                   !self.messages[assistantIndex].content.isEmpty {
                    // Keep the partial answer rather than losing it.
                    self.persistAssistantMessage(self.messages[assistantIndex].content)
                }
                self.removeAssistantIfEmpty(id: assistant.id)
            }
            guard let self, self.streamGeneration == generation else { return }
            if !didComplete {
                if !didFail {
                    _ = self.restoreOrCleanupStreamAttachments(sentAttachments)
                }
                self.removeAssistantIfEmpty(id: assistant.id)
            } else {
                self.scheduleCleanup(of: sentStagedURLs)
            }
            self.clearActiveStream()
            self.isStreaming = false
            self.streamTask = nil
        }
    }

    public func stop() {
        streamGeneration &+= 1
        streamTask?.cancel()
        streamTask = nil
        if let assistantID = activeStreamAssistantID {
            removeAssistantIfEmpty(id: assistantID)
        }
        if !activeStreamAttachments.isEmpty {
            _ = restoreOrCleanupStreamAttachments(activeStreamAttachments)
        }
        clearActiveStream()
        isStreaming = false
        workGeneration &+= 1
        isWorking = false
        contextGeneration &+= 1
        invalidateWebProviderPreparation()
    }

    private func stagedURLs(in attachments: [AIContextAttachment]) -> [URL] {
        attachments.compactMap { attachment in
            guard case .file(let file) = attachment else { return nil }
            return file.fileURL
        }
    }

    /// Restores the context for a retry unless the user has already supplied
    /// newer context. In that case the canceled request's staged files are
    /// cleaned up without touching the new attachments.
    @discardableResult
    private func restoreOrCleanupStreamAttachments(_ sent: [AIContextAttachment]) -> Bool {
        guard !sent.isEmpty else { return false }
        if activeStreamRestoreAllowed, attachments.isEmpty {
            attachments = sent
            return true
        }
        let retainedURLs = Set(stagedURLs(in: attachments))
        let discardedURLs = stagedURLs(in: sent).filter { !retainedURLs.contains($0) }
        scheduleCleanup(of: discardedURLs)
        return false
    }

    private func clearActiveStream() {
        activeStreamAttachments.removeAll()
        activeStreamAssistantID = nil
        activeStreamRestoreAllowed = true
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

    private func removeAssistantIfEmpty(id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].content.isEmpty else { return }
        messages.remove(at: index)
    }

    private func makeAdapter(credential: String) -> any AIProviderAdapter {
        makeAdapter(for: provider, credential: credential)
    }

    private func makeAdapter(for provider: AIProviderID, credential: String) -> any AIProviderAdapter {
        AIAdapterFactory.make(for: provider, credential: credential)
    }

    public let providerPanel = ProviderPanelController()
}
