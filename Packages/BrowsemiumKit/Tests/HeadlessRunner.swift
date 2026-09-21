import BrowsemiumAI
import BrowsemiumCore
import BrowsemiumData
import BrowsemiumEngine
import Foundation
import GRDB
import WebKit
import BrowsemiumEngineKit

private enum VerificationFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AIEvent] = []
    private var failure: Error?

    var events: [AIEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ event: AIEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    func record(_ error: Error) {
        lock.lock()
        failure = error
        lock.unlock()
    }
}

private final class MockKeychain: KeychainAPI, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    var failNextStore = false

    func store(service: String, account: String, data: Data) -> OSStatus {
        if failNextStore {
            failNextStore = false
            return errSecAuthFailed
        }
        storage["\(service)|\(account)"] = data
        return errSecSuccess
    }

    func read(service: String, account: String) -> (status: OSStatus, data: Data?) {
        guard let data = storage["\(service)|\(account)"] else {
            return (errSecItemNotFound, nil)
        }
        return (errSecSuccess, data)
    }

    func delete(service: String, account: String) -> OSStatus {
        storage["\(service)|\(account)"] = nil
        return errSecSuccess
    }

    func exists(service: String, account: String) -> Bool {
        storage["\(service)|\(account)"] != nil
    }
}

@main
struct HeadlessRunner {
    static func main() throws {
        try verifyIdentifiers()
        try verifyNavigation()
        try verifyDatabase()
        try verifyAIParsing()
        try verifySleepPolicy()
        try verifySleepSignalProtection()
        try verifyRuntimeLifecycleEvents()
        try verifySiteDataScopes()
        try verifyProcessMemory()
        try verifyDownloadDestinations()
        try verifyPersistence()
        try verifyPrivacyControls()
        try verifyKeychain()
        try verifySSEParsing()
        try verifyProviderRequests()
        try verifyModelCatalog()
        try verifyProviderHandoff()
        try verifyMarkdownSanitization()
        try verifyContentRules()
        print("Browsemium headless verification passed")
    }

    private static func verifySSEParsing() throws {
        var parser = SSEParser()
        var events: [SSEParser.Event] = []
        events += parser.consume("event: content_block_delta\r\ndata: {\"a\":")
        events += parser.consume("1}\r\n\r\ndata: second\n\n")
        events += parser.consume(":comment\ndata: third\n\n")
        events += parser.finish()

        try expect(events.count == 3, "SSE parser should emit three events, got \(events.count): \(events.map { "\($0.type ?? "-")|\($0.data)" })")
        try expect(events[0].type == "content_block_delta", "SSE event type was lost")
        try expect(events[0].data == "{\"a\":1}", "SSE data split across chunks was not reassembled")
        try expect(events[1].data == "second", "SSE event without a type failed")
        try expect(events[2].data == "third", "SSE comment line handling failed")

        var multiLine = SSEParser()
        let multilineEvents = multiLine.consume("data: line one\ndata: line two\n\n")
        try expect(multilineEvents.count == 1 && multilineEvents[0].data == "line one\nline two", "Multi-line SSE data must be joined with newlines")
    }

    private static func verifyProviderRequests() throws {
        let policy = AIContextPolicy(maxTextCharacters: 500, maxOutputTokens: 512)
        let catalog = ModelCapabilityCatalog.bundled
        let image = PageImageContext(data: Data([0x01, 0x02, 0x03]), mimeType: "image/png", width: 10, height: 10)
        let pageContext = PageTextContext(
            url: URL(string: "https://example.com/article")!,
            title: "Example",
            text: String(repeating: "a", count: 900)
        )

        let visionModel = AIModel(id: "gpt-5.6", name: "gpt-5.6", providerID: .openAI)
        let textModel = AIModel(id: "text-embedding-3", name: "embedding", providerID: .openAI)

        let openAI = OpenAIAdapter(credential: "sk-test", policy: policy, capabilities: catalog)
        let request = AIRequest(
            model: visionModel,
            messages: [AIMessage(role: .user, content: "What is this page about?")],
            attachments: [.readablePage(pageContext), .viewportImage(image)]
        )
        let urlRequest = try openAI.makeRequest(request)
        try expect(urlRequest.url?.absoluteString == "https://api.openai.com/v1/responses", "OpenAI endpoint is wrong")
        try expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test", "OpenAI credential header is wrong")

        let body = try require(
            try JSONSerialization.jsonObject(with: try require(urlRequest.httpBody, "OpenAI request body missing")) as? [String: Any],
            "OpenAI body is not JSON"
        )
        try expect(body["store"] as? Bool == false, "OpenAI requests must not be stored server side")
        try expect(body["max_output_tokens"] as? Int == 512, "OpenAI output token ceiling is wrong")
        let input = try require(body["input"] as? [[String: Any]], "OpenAI input missing")
        let content = try require(input.first?["content"] as? [[String: Any]], "OpenAI content missing")
        try expect(content.contains { $0["type"] as? String == "input_image" }, "OpenAI image part missing")
        let textParts = content.compactMap { part -> String? in
            guard part["type"] as? String == "input_text" else { return nil }
            return part["text"] as? String
        }
        try expect(!textParts.isEmpty, "OpenAI text parts are missing")
        let text = textParts.joined(separator: "\n")
        try expect(text.contains("shared_page_context"), "Page context must be wrapped as untrusted reference material")
        try expect(text.contains("truncated=\"true\""), "Truncated context must be marked")
        try expect(text.count < 900, "Context must be bounded by the policy")

        let textOnlyRequest = AIRequest(
            model: textModel,
            messages: [AIMessage(role: .user, content: "Describe")],
            attachments: [.viewportImage(image)]
        )
        do {
            _ = try openAI.makeRequest(textOnlyRequest)
            throw VerificationFailure.failed("Images must be rejected for models without verified vision support")
        } catch BrowsemiumError.captureUnavailable {
        }

        let anthropic = AnthropicAdapter(credential: "sk-ant", policy: policy, capabilities: catalog)
        let anthropicRequest = try anthropic.makeRequest(
            AIRequest(
                model: AIModel(id: "claude-sonnet-4-5", name: "Claude", providerID: .anthropic),
                messages: [AIMessage(role: .user, content: "Summarize")],
                attachments: [.selection(PageTextContext(text: "selected text"))]
            )
        )
        try expect(anthropicRequest.url?.absoluteString == "https://api.anthropic.com/v1/messages", "Anthropic endpoint is wrong")
        try expect(anthropicRequest.value(forHTTPHeaderField: "x-api-key") == "sk-ant", "Anthropic credential header is wrong")
        try expect(anthropicRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "Anthropic version header is wrong")

        let gemini = GeminiAdapter(credential: "gem-key", policy: policy, capabilities: catalog)
        let geminiRequest = try gemini.makeRequest(
            AIRequest(
                model: AIModel(id: "gemini-3-pro", name: "Gemini", providerID: .gemini),
                messages: [AIMessage(role: .user, content: "Hello")],
                attachments: []
            )
        )
        try expect(
            geminiRequest.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-pro:streamGenerateContent?alt=sse",
            "Gemini endpoint is wrong: \(geminiRequest.url?.absoluteString ?? "nil")"
        )
        try expect(geminiRequest.value(forHTTPHeaderField: "x-goog-api-key") == "gem-key", "Gemini credential header is wrong")

        let xai = XAIAdapter(credential: "xai-key", policy: policy, capabilities: catalog)
        let xaiRequest = try xai.makeRequest(
            AIRequest(
                model: AIModel(id: "grok-4.6", name: "Grok", providerID: .xAI),
                messages: [AIMessage(role: .user, content: "Hello")],
                attachments: []
            )
        )
        try expect(xaiRequest.url?.absoluteString == "https://api.x.ai/v1/responses", "xAI endpoint is wrong")

        try verifyStreamMapping()
    }

    private static func verifyStreamMapping() throws {
        let events = [
            SSEParser.Event(data: #"{"type":"response.output_text.delta","delta":"Hel"}"#),
            SSEParser.Event(data: #"{"type":"response.output_text.delta","delta":"lo"}"#),
            SSEParser.Event(data: #"{"type":"response.completed"}"#)
        ]
        let upstream = AsyncThrowingStream<SSEParser.Event, Error> { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
        let mapped = mapProviderStream(upstream) { event, _ in
            guard let raw = event.data.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let type = object["type"] as? String else {
                return .ignore
            }
            switch type {
            case "response.output_text.delta":
                return .delta(object["delta"] as? String ?? "")
            case "response.completed":
                return .done
            default:
                return .ignore
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        let collector = StreamCollector()
        Task {
            do {
                for try await event in mapped {
                    collector.append(event)
                }
            } catch {
                collector.record(error)
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)

        let collected = collector.events
        try expect(collected.count == 3, "Expected two deltas and a completion, got \(collected.count)")
        guard case .textDelta("Hel") = collected[0], case .textDelta("lo") = collected[1] else {
            throw VerificationFailure.failed("Text deltas were not mapped in order")
        }
        guard case .completed(let message) = collected[2] else {
            throw VerificationFailure.failed("Completion event was not emitted")
        }
        try expect(message.content == "Hello", "Accumulated assistant text is wrong")
    }

    private static func verifyModelCatalog() throws {
        let catalog = ModelCapabilityCatalog.bundled
        try expect(catalog.supportsVision(provider: .openAI, modelID: "gpt-5.6-terra"), "Known OpenAI vision model was not detected")
        try expect(!catalog.supportsVision(provider: .openAI, modelID: "text-embedding-3-large"), "Embedding models must not be treated as vision models")
        try expect(!catalog.supportsVision(provider: .openAI, modelID: "unknown-model-x"), "Unknown models must default to text-only")
        try expect(catalog.supportsVision(provider: .anthropic, modelID: "claude-sonnet-4-5"), "Claude vision support was not detected")
        try expect(catalog.supportsVision(provider: .gemini, modelID: "gemini-3.8-flash"), "Gemini vision support was not detected")
        try expect(catalog.supportsVision(provider: .xAI, modelID: "grok-4.6"), "Grok vision support was not detected")
    }

    private static func verifyProviderHandoff() throws {
        let builder = ProviderHandoffBuilder(policy: AIContextPolicy(maxTextCharacters: 400))
        let context = PageTextContext(url: URL(string: "https://example.com")!, title: "Example", text: "short context")

        let chatGPT = builder.makeHandoff(provider: .openAI, userPrompt: "Summarize this", attachments: [.readablePage(context)])
        guard case .prefilledURL(let url) = chatGPT.method else {
            throw VerificationFailure.failed("ChatGPT should support a prefilled prompt URL")
        }
        try expect(url.host == "chatgpt.com", "ChatGPT handoff host is wrong")
        try expect(url.query?.contains("q=") == true, "ChatGPT handoff is missing the prompt parameter")
        try expect(chatGPT.note == nil, "Documented prefill should not warn")

        let gemini = builder.makeHandoff(provider: .gemini, userPrompt: "Summarize this", attachments: [.readablePage(context)])
        try expect(gemini.method == .clipboardOnly, "Gemini must fall back to the clipboard flow")
        try expect(gemini.note?.contains("does not accept a prompt through a link") == true, "Gemini fallback must explain itself")

        let longText = String(repeating: "x", count: 3000)
        let permissiveBuilder = ProviderHandoffBuilder(policy: AIContextPolicy(maxTextCharacters: 5000))
        let long = permissiveBuilder.makeHandoff(
            provider: .xAI,
            userPrompt: "Explain",
            attachments: [.readablePage(PageTextContext(text: longText))]
        )
        try expect(long.method == .clipboardOnly, "Over-long prompts must fall back to the clipboard flow")
        try expect(long.note?.contains("longer than") == true, "Over-long fallback must explain itself")

        let image = PageImageContext(data: Data([0x00]), mimeType: "image/png", width: 4, height: 4)
        let withImage = builder.makeHandoff(provider: .openAI, userPrompt: "Look", attachments: [.viewportImage(image)])
        try expect(withImage.includesImage, "Handoff must report that a screenshot is attached")
        try expect(withImage.note?.contains("provider attachment") == true, "Handoff must explain how the screenshot can be attached")

        let grok = builder.makeHandoff(provider: .xAI, userPrompt: "Hi", attachments: [])
        try expect(grok.note?.contains("does not officially support prompt links") == true, "Community prefill must warn")
    }

    /// The bundled rule set must ship inside the engine bundle, be valid
    /// WebKit content-blocker JSON, and use host-matching filters. WebKit's
    /// `if-domain` matches the top-level page, not the request, so a rule that
    /// relies on it would silently block nothing.
    private static func verifyContentRules() throws {
        let json = try require(ContentRuleListManager.bundledRulesJSON(), "Starter content rules are missing from the bundle")
        let data = try require(json.data(using: .utf8), "Content rules are not UTF-8")
        let rules = try require(
            try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            "Content rules are not a JSON array"
        )
        try expect(rules.count >= 10, "Expected a meaningful starter rule set, found \(rules.count)")
        try expect(ContentRuleListManager.countRules(in: json) == rules.count, "Rule count disagrees with the payload")

        for rule in rules {
            let trigger = try require(rule["trigger"] as? [String: Any], "A rule is missing its trigger")
            let action = try require(rule["action"] as? [String: Any], "A rule is missing its action")
            try expect(action["type"] as? String == "block", "Only blocking rules are supported here")
            let filter = try require(trigger["url-filter"] as? String, "A rule is missing its url-filter")
            try expect(filter.contains("^https?://"), "url-filter must anchor on the request scheme: \(filter)")
            // WebKit's rule engine rejects alternation with
            // "Disjunctions are not supported yet", which fails the whole list.
            try expect(!filter.contains("|"), "WebKit content-rule regex does not support alternation: \(filter)")
            _ = try NSRegularExpression(pattern: filter)
            try expect(trigger["if-domain"] == nil, "if-domain matches the page, not the request — do not use it to block trackers")
        }
    }

    private static func verifyMarkdownSanitization() throws {
        let source = """
            # Title

            Some **bold** text with [a link](https://example.com/docs) and [a bad link](javascript:alert(1)).

            ```swift
            let value = 1
            ```

            - first
            - second
            """
        let document = SafeMarkdownDocument(source: source)
        try expect(document.blocks.contains(.heading(level: 1, text: [.text("Title")])), "Heading block was not parsed")
        try expect(document.blocks.contains { block in
            if case .codeBlock(let language, let code) = block {
                return language == "swift" && code.contains("let value = 1")
            }
            return false
        }, "Code block was not parsed")
        try expect(document.blocks.contains(.bulletList([[.text("first")], [.text("second")]])), "List block was not parsed")
        try expect(document.links.count == 1, "Only HTTP(S) links may survive sanitization")
        try expect(document.links.first?.url.absoluteString == "https://example.com/docs", "Sanitized link URL is wrong")
        try expect(document.plainText.contains("Some bold text"), "Plain text rendering lost inline content")
        try expect(document.blocks.contains { block in
            guard case .paragraph(let inlines) = block else { return false }
            return inlines.contains { inline in
                if case .strong(let inner) = inline { return inner == [.text("bold")] }
                return false
            }
        }, "Bold inline formatting was flattened")
        try expect(document.blocks.contains { block in
            guard case .paragraph(let inlines) = block else { return false }
            return inlines.contains { inline in
                if case .link(let inner, let url) = inline {
                    return inner == [.text("a link")] && url.absoluteString == "https://example.com/docs"
                }
                return false
            }
        }, "A sanitized link must keep its destination inline")
        // The javascript: link keeps its text but loses the URL entirely.
        try expect(document.blocks.contains { block in
            guard case .paragraph(let inlines) = block else { return false }
            return inlines.contains(.text("a bad link"))
        }, "An unsafe link must degrade to plain text")
        try expect(SafeMarkdownDocument.sanitizedURL("javascript:alert(1)") == nil, "javascript: URLs must be rejected")
        try expect(SafeMarkdownDocument.sanitizedURL("data:text/html,<b>x</b>") == nil, "data: URLs must be rejected")
    }

    private static func verifyPersistence() throws {
        let database = try AppDatabase.inMemoryProfile()
        let history = HistoryRepository(database: database)
        let now = Date()
        try history.record(url: URL(string: "https://swift.org/blog")!, title: "Swift Blog", visitedAt: now)
        try history.record(url: URL(string: "https://example.com/docs")!, title: "Docs", visitedAt: now.addingTimeInterval(-86_400 * 400))
        try expect(try history.count() == 2, "History records were not stored")

        let search = try history.search("swift")
        try expect(search.count == 1 && search[0].title == "Swift Blog", "Full-text history search failed")
        let punctuation = try history.search("swift.org")
        try expect(!punctuation.isEmpty, "Search should tolerate punctuation in queries")

        let maintenance = DatabaseMaintenance(database: database)
        let settings = BrowserSettings(historyRetentionDays: 90)
        let report = try maintenance.run(settings: settings, now: now)
        try expect(report.prunedHistoryVisits == 1, "Retention should prune expired history")
        try expect(try history.count() == 1, "Retention removed the wrong history rows")

        let bookmarks = BookmarkRepository(database: database)
        let bookmark = try bookmarks.add(url: URL(string: "https://swift.org")!, title: "Swift")
        try expect(try bookmarks.contains(url: bookmark.url), "Bookmark was not stored")
        try expect(try bookmarks.search("swi").count == 1, "Bookmark search failed")
        try expect(try bookmarks.remove(id: bookmark.id), "Bookmark removal failed")
        try expect(try bookmarks.all().isEmpty, "Bookmark was not removed")

        let permissions = PermissionRepository(database: database)
        try expect(try permissions.decision(origin: "https://example.com", kind: .camera) == .ask, "Default permission decision must be ask")
        try permissions.set(origin: "https://example.com", kind: .camera, decision: .allow)
        try expect(try permissions.decision(origin: "https://example.com", kind: .camera) == .allow, "Permission decision was not stored")
        try permissions.set(origin: "https://example.com", kind: .camera, decision: .deny)
        try expect(try permissions.decision(origin: "https://example.com", kind: .camera) == .deny, "Permission decision was not updated")
        try expect(try permissions.all().count == 1, "Permission list should not duplicate origins")

        let settingsRepository = SettingsRepository(database: database)
        var stored = try settingsRepository.load()
        try expect(stored == BrowserSettings(), "Default settings must round trip")
        stored.protectionLevel = .strict
        stored.historyRetentionDays = nil
        try settingsRepository.save(stored)
        try expect(try settingsRepository.load() == stored, "Settings were not persisted")

        let closedTabs = ClosedTabRepository(database: database, maximumEntries: 2)
        let space = BrowserSpace(name: "Personal")
        let session = BrowserSessionState(
            spaces: [space],
            tabs: [],
            activeSpaceID: space.id,
            activeTabID: nil
        )
        try BrowserSessionRepository(database: database).save(session)
        for index in 0..<4 {
            let tab = BrowserTab(spaceID: space.id, title: "Tab \(index)")
            try closedTabs.record(tab, closedAt: now.addingTimeInterval(TimeInterval(index)))
        }
        let recentClosed = try closedTabs.recent(limit: 10)
        try expect(recentClosed.count == 2, "Closed tab stack must be bounded")
        try expect(recentClosed.first?.title == "Tab 3", "Closed tab stack must keep the newest entries")

        let downloads = DownloadRepository(database: database)
        let record = try downloads.start(tabID: nil, sourceURL: URL(string: "https://example.com/file.zip")!, suggestedFilename: "file.zip")
        try downloads.upsert(
            DownloadRecord(
                id: record.id,
                tabID: nil,
                sourceURL: record.sourceURL,
                destinationURL: URL(fileURLWithPath: "/tmp/file.zip"),
                suggestedFilename: "file.zip",
                state: .finished,
                bytesReceived: 1024,
                totalBytes: 1024,
                failureMessage: nil,
                createdAt: record.createdAt,
                updatedAt: Date()
            )
        )
        let storedDownloads = try downloads.recent()
        try expect(storedDownloads.count == 1 && storedDownloads[0].state == .finished, "Download state was not updated")
    }

    private static func verifyPrivacyControls() throws {
        let database = try AppDatabase.inMemoryProfile()
        let history = HistoryRepository(database: database)
        let permissions = PermissionRepository(database: database)
        let settings = SettingsRepository(database: database)
        let downloads = DownloadRepository(database: database)

        try history.record(url: URL(string: "https://private.example")!, title: "Private")
        try permissions.set(origin: "https://private.example", kind: .microphone, decision: .allow)
        try settings.setSitePreference(origin: "https://private.example", preference: "zoom", value: "1.25")
        try downloads.start(tabID: nil, sourceURL: URL(string: "https://private.example/f")!, suggestedFilename: "f.bin")

        let manager = PrivacyDataManager(database: database)
        try manager.clear([.history, .sitePermissions])

        try expect(try history.count() == 0, "History was not cleared")
        try expect(try permissions.all().isEmpty, "Permissions were not cleared")
        try expect(try settings.sitePreference(origin: "https://private.example", preference: "zoom") == "1.25", "Site preferences should survive a history-only clear")
        try expect(try downloads.recent().count == 1, "Downloads should survive a history-only clear")

        try manager.clear(.everything)
        try expect(try settings.sitePreference(origin: "https://private.example", preference: "zoom") == nil, "Site preferences were not cleared")
        try expect(try downloads.recent().isEmpty, "Downloads were not cleared")
    }

    private static func verifyKeychain() throws {
        let backend = MockKeychain()
        let store = KeychainStore(service: "com.browsemium.tests", api: backend)

        try expect(try store.secret(account: "openai") == nil, "Missing secrets must read as nil")
        try store.setSecret("sk-test-value", account: "openai")
        try expect(try store.secret(account: "openai") == "sk-test-value", "Secret round trip failed")
        try expect(try store.hasSecret(account: "openai"), "Secret presence check failed")
        try store.deleteSecret(account: "openai")
        try expect(try store.secret(account: "openai") == nil, "Secret deletion failed")

        do {
            try store.setSecret("   ", account: "openai")
            throw VerificationFailure.failed("Empty secrets must be rejected")
        } catch KeychainStore.KeychainError.emptySecret {
        }

        backend.failNextStore = true
        do {
            try store.setSecret("sk-test-value", account: "openai")
            throw VerificationFailure.failed("Keychain store failure must surface as an error")
        } catch KeychainStore.KeychainError.storeFailed {
        }
    }

    private static func verifySleepPolicy() throws {
        let spaceID = SpaceID()
        let now = Date()
        let idleTab = BrowserTab(
            spaceID: spaceID,
            title: "Idle",
            lastCommittedURL: URL(string: "https://example.com"),
            lifecycle: .active,
            lastAccessedAt: now.addingTimeInterval(-3600)
        )
        let freshTab = BrowserTab(
            spaceID: spaceID,
            title: "Fresh",
            lifecycle: .active,
            lastAccessedAt: now
        )
        let audibleTab = BrowserTab(
            spaceID: spaceID,
            title: "Playing",
            lifecycle: .active,
            lastAccessedAt: now.addingTimeInterval(-3600)
        )
        let policy = TabSleepPolicy(idleInterval: 300, maximumLiveTabs: 4)

        let candidates = policy.hibernationCandidates(
            tabs: [idleTab, freshTab, audibleTab],
            activeTabIDs: [],
            signals: [audibleTab.id: TabSleepSignals(isAudible: true)],
            now: now
        )
        try expect(candidates == [idleTab.id], "Idle tabs should be the only hibernation candidates")

        let activeProtection = policy.hibernationCandidates(
            tabs: [idleTab],
            activeTabIDs: [idleTab.id],
            signals: [:],
            now: now
        )
        try expect(activeProtection.isEmpty, "Active tabs must never be hibernated")

        let overflowTabs = (0..<6).map { index in
            BrowserTab(
                spaceID: spaceID,
                title: "Tab \(index)",
                lifecycle: .active,
                lastAccessedAt: now.addingTimeInterval(TimeInterval(-index))
            )
        }
        let overflow = policy.excessLiveTabs(tabs: overflowTabs, activeTabIDs: [], signals: [:])
        try expect(overflow.count == 2, "Live tab overflow should be trimmed to the policy limit")
        try expect(overflow == [overflowTabs[5].id, overflowTabs[4].id], "Overflow should evict least recently used tabs first")
    }

    /// Every signal the app can raise has to actually protect a tab. These are
    /// the cases that used to be unloaded mid-flight because the model passed
    /// an empty signal map.
    private static func verifySleepSignalProtection() throws {
        let spaceID = SpaceID()
        let now = Date()
        func idleTab(_ title: String) -> BrowserTab {
            BrowserTab(
                spaceID: spaceID,
                title: title,
                lifecycle: .active,
                lastAccessedAt: now.addingTimeInterval(-3600)
            )
        }
        let idle = idleTab("Idle")
        let playing = idleTab("Playing")
        let onCall = idleTab("On a call")
        let downloading = idleTab("Downloading")
        let kept = idleTab("Kept loaded")
        let tabs = [idle, playing, onCall, downloading, kept]
        let policy = TabSleepPolicy(idleInterval: 300, maximumLiveTabs: 4)

        let signals: [TabID: TabSleepSignals] = [
            playing.id: TabSleepSignals(isAudible: true),
            onCall.id: TabSleepSignals(isCapturingMedia: true),
            downloading.id: TabSleepSignals(hasActiveDownload: true),
            kept.id: TabSleepSignals(isKeepAwake: true)
        ]

        let candidates = policy.hibernationCandidates(
            tabs: tabs,
            activeTabIDs: [],
            signals: signals,
            now: now
        )
        try expect(candidates == [idle.id], "Only the truly idle tab may be hibernated")

        // The live-tab ceiling only counts tabs that are free to unload, so
        // four protected tabs plus one idle tab stay under a ceiling of four.
        let quietCeiling = policy.excessLiveTabs(tabs: tabs, activeTabIDs: [], signals: signals)
        try expect(quietCeiling.isEmpty, "Protected tabs must not count against the live-tab ceiling")

        // Push past the ceiling with unprotected tabs and confirm the eviction
        // set is drawn only from those, least recently used first. Index 0 is
        // the oldest of these.
        let extraIdle = (0..<5).map { index in
            BrowserTab(
                spaceID: spaceID,
                title: "Idle \(index)",
                lifecycle: .active,
                lastAccessedAt: now.addingTimeInterval(TimeInterval(-7200 + index))
            )
        }
        let overflow = policy.excessLiveTabs(
            tabs: tabs + extraIdle,
            activeTabIDs: [],
            signals: signals
        )
        try expect(!overflow.contains(playing.id), "An audible tab must not be evicted by the live-tab ceiling")
        try expect(!overflow.contains(onCall.id), "A tab holding a call must not be evicted by the live-tab ceiling")
        try expect(!overflow.contains(downloading.id), "A downloading tab must not be evicted by the live-tab ceiling")
        try expect(!overflow.contains(kept.id), "A tab the user kept loaded must not be evicted by the live-tab ceiling")
        try expect(overflow.count == 2, "Six unloadable tabs under a ceiling of four evicts two, got \(overflow.count)")
        let overflowTitles = overflow.compactMap { id in
            (tabs + extraIdle).first { $0.id == id }?.title
        }
        try expect(
            overflow == [extraIdle[0].id, extraIdle[1].id],
            "The least recently used unloadable tabs must be evicted first, got \(overflowTitles)"
        )
        try expect(
            overflow == [extraIdle[0].id, extraIdle[1].id],
            "The least recently used unloadable tabs must be evicted first"
        )

        // A hibernated tab is not a hibernation candidate again, which is what
        // keeps the policy from re-picking tabs that already released memory.
        let alreadySleeping = BrowserTab(
            spaceID: spaceID,
            title: "Sleeping",
            lifecycle: .hibernated,
            lastAccessedAt: now.addingTimeInterval(-7200)
        )
        let recheck = policy.hibernationCandidates(
            tabs: [alreadySleeping, idle],
            activeTabIDs: [],
            signals: [:],
            now: now
        )
        try expect(recheck == [idle.id], "Hibernated tabs must not be hibernation candidates")
    }

    /// The model only learns that a tab was hibernated through this event, so
    /// it has to fire exactly once per real state change.
    private static func verifyRuntimeLifecycleEvents() throws {
        try MainActor.assumeIsolated {
            let runtime = TabRuntime(
                tabID: TabID(),
                isPrivate: false,
                factory: WebViewFactory(),
                captureService: ContentCaptureService(),
                downloadCoordinator: DownloadCoordinator()
            )
            var events: [TabRuntimeEvent] = []
            runtime.onEvent = { events.append($0) }

            func lifecycleChanges() -> [TabLifecycle] {
                events.compactMap { event in
                    if case .lifecycleChanged(let lifecycle) = event { return lifecycle }
                    return nil
                }
            }

            runtime.hibernate()
            try expect(runtime.lifecycle == .hibernated, "Hibernating must move the runtime to .hibernated")
            try expect(lifecycleChanges() == [.hibernated], "Hibernation must emit one lifecycle change")

            // A second hibernate is a no-op, not a second event.
            runtime.hibernate()
            try expect(lifecycleChanges() == [.hibernated], "Re-hibernating must not emit another lifecycle change")

            // Suspending an already-hibernated tab must not resurrect it.
            runtime.suspend()
            try expect(runtime.lifecycle == .hibernated, "A hibernated tab must stay hibernated when suspended")
            try expect(lifecycleChanges() == [.hibernated], "Suspending a sleeping tab must not emit an event")

            // A crash is a real state change the model needs to see.
            runtime.report(.crashed)
            try expect(runtime.lifecycle == .crashed, "A crashed page must move the runtime to .crashed")
            try expect(lifecycleChanges() == [.hibernated, .crashed], "A crash must emit a lifecycle change")
        }
    }

    /// "Clear cache" must not sign the user out of every site, so the cache
    /// set and the cookie set have to stay distinct.
    private static func verifySiteDataScopes() throws {
        let cacheTypes = BrowserRuntimeController.cacheDataTypes()
        try expect(!cacheTypes.isEmpty, "The cache scope must name at least one data type")
        try expect(
            !cacheTypes.contains(WKWebsiteDataTypeCookies),
            "Clearing the cache must not delete cookies"
        )

        let everything = BrowserRuntimeController.siteDataTypes(includeCache: true)
        try expect(everything.contains(WKWebsiteDataTypeCookies), "The site-data scope must include cookies")
        try expect(
            everything.isSuperset(of: cacheTypes),
            "The site-data scope must include everything the cache scope clears"
        )

        let withoutCache = BrowserRuntimeController.siteDataTypes(includeCache: false)
        try expect(withoutCache.contains(WKWebsiteDataTypeCookies), "Cookies are not cache")
        try expect(
            withoutCache.isDisjoint(with: cacheTypes),
            "A site-data clear that skips the cache must not touch cached responses"
        )
    }

    /// The memory figure the UI shows has to be honest about its scope. WebKit
    /// keeps page processes in XPC services owned by launchd, so this process
    /// tree cannot contain them and the app must say so rather than implying
    /// the number covers every page.
    private static func verifyProcessMemory() throws {
        let own = ProcessMemory.footprintBytes()
        try expect(own > 0, "The app's own footprint must be measurable")

        // With a real child process the group path must measure it. The
        // Chromium edition's helpers are genuine children of the browser
        // process, so this is the path a CEF runtime actually exercises — and
        // proc_pid_rusage must not corrupt the stack on a foreign pid.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let group = ProcessMemory.groupFootprint()
        try expect(group.measuredProcesses >= 2, "A live child process must be measured in the group")
        try expect(group.bytes >= own, "The process group cannot be smaller than this process")
        try expect(group.isComplete, "This runner owns no unreadable processes")
        try expect(ProcessMemory.formattedFootprint() != "Unavailable", "The app figure must format")

        let summary = ProcessMemory.summary()
        child.terminate()
        try expect(summary.bytes > 0, "The summary must carry a figure")
        try expect(
            summary.includesPageProcesses,
            "Visible page processes must be reported as included"
        )

        // The sandbox decides whether helpers answer; the flag has to reflect
        // that honestly rather than silently under-reporting.
        let partial = ProcessMemory.GroupFootprint(bytes: own, measuredProcesses: 1, isComplete: false)
        try expect(!partial.isComplete, "An incomplete measurement must be flagged as such")
    }

    private static func verifyDownloadDestinations() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("browsemium-download-\(UUID().uuidString)")
        let policy = DownloadDestinationPolicy(directoryOverride: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let traversal = try require(policy.sanitizedFilename("../../etc/passwd"), "Traversal filename should still be usable after sanitizing")
        try expect(!traversal.contains("/") && !traversal.contains("\\"), "Path separators must be removed")
        try expect(!traversal.hasPrefix("."), "Leading dots must be removed")
        try expect(policy.sanitizedFilename(".hidden") == "hidden", "Leading dots must be removed")
        try expect(policy.sanitizedFilename("..") == nil, "Dot-only filenames must be rejected")
        try expect(policy.sanitizedFilename("   ") == nil, "Empty filenames must be rejected")

        let first = try policy.destination(forSuggestedFilename: "report.pdf")
        try Data("first".utf8).write(to: first)
        let second = try policy.destination(forSuggestedFilename: "report.pdf")
        try expect(second.lastPathComponent == "report (1).pdf", "Duplicate downloads must not overwrite existing files")
        try expect(second.path.hasPrefix(directory.path), "Downloads must stay inside the destination directory")
    }

    private static func verifyIdentifiers() throws {
        try roundTrip(TabID())
        try roundTrip(SpaceID())
        try roundTrip(PaneID())
        try roundTrip(ConversationID())
    }

    private static func roundTrip<Value: Codable & Equatable>(_ value: Value) throws {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(Value.self, from: data)
        try expect(decoded == value, "Identifier Codable round trip failed")
    }

    private static func verifyNavigation() throws {
        let resolver = NavigationResolver()
        try expect(
            try resolver.resolve("  example.com/path?q=swift  \n").url.absoluteString == "https://example.com/path?q=swift",
            "Domain navigation failed"
        )
        let unicodeURL = try resolver.resolve("café browser").url
        let components = try require(URLComponents(url: unicodeURL, resolvingAgainstBaseURL: false), "Search URL is invalid")
        try expect(components.host == "www.google.com", "Search host is incorrect")
        try expect(components.queryItems?.first(where: { $0.name == "q" })?.value == "café browser", "Unicode query was not preserved")
        try expect(
            try resolver.resolve("localhost:8080/settings?tab=privacy").url.absoluteString == "https://localhost:8080/settings?tab=privacy",
            "Localhost navigation failed"
        )
        for value in ["javascript:alert(1)", "data:text/plain,hello", "file:///tmp/file"] {
            do {
                _ = try resolver.resolve(value)
                throw VerificationFailure.failed("Blocked scheme was accepted: \(value)")
            } catch BrowsemiumError.blockedScheme {
            }
        }
        do {
            _ = try resolver.resolve("https://user:secret@example.com")
            throw VerificationFailure.failed("Credential URL was accepted")
        } catch BrowsemiumError.credentialsNotAllowed {
        }
        do {
            _ = try resolver.resolve(" \n\t ")
            throw VerificationFailure.failed("Empty input was accepted")
        } catch BrowsemiumError.emptyNavigationInput {
        }
    }

    private static func verifyDatabase() throws {
        let appDatabase = try AppDatabase.inMemoryProfile()
        let names = try appDatabase.databaseQueue.read { database in
            try String.fetchAll(database, sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'view')")
        }
        let required = Set([
            "spaces", "tabs", "closed_tabs", "history_visits", "history_visits_fts",
            "bookmarks", "downloads", "site_permissions", "site_preferences",
            "ai_provider_settings", "ai_conversations", "ai_messages", "schema_metadata"
        ])
        try expect(required.isSubset(of: Set(names)), "Database migration is incomplete")
        let foreignKeys = try appDatabase.databaseQueue.read { database in
            try Int.fetchOne(database, sql: "PRAGMA foreign_keys")
        }
        try expect(foreignKeys == 1, "Foreign keys are disabled")

        let space = BrowserSpace(name: "Private")
        let tab = BrowserTab(spaceID: space.id, title: "New Tab")
        let session = BrowserSessionState(
            spaces: [space],
            tabs: [tab],
            activeSpaceID: space.id,
            activeTabID: tab.id,
            isPrivate: true
        )
        do {
            try BrowserSessionRepository(database: appDatabase).save(session)
            throw VerificationFailure.failed("Private session was persisted")
        } catch BrowsemiumError.privateSessionPersistenceUnsupported {
        }
    }

    private static func verifyAIParsing() throws {
        let source = "**Browsemium**"
        try expect(AIMarkdownDocument(source: source).source == source, "AI document source changed")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw VerificationFailure.failed(message) }
    }

    private static func require<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else { throw VerificationFailure.failed(message) }
        return value
    }
}
