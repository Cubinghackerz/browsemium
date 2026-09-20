import BrowsemiumAI
import BrowsemiumCore
import BrowsemiumEngine
import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import WebKit

public struct ProviderComposerPreparation: Sendable {
    /// Stable identity for this preparation. The provider bridge checks it
    /// again after every asynchronous upload so a later tab/provider switch
    /// can never replay an older message.
    public let id: UUID
    public let text: String
    public let fileURLs: [URL]

    public init(text: String, fileURLs: [URL] = [], id: UUID = UUID()) {
        self.id = id
        self.text = text
        self.fileURLs = fileURLs
    }
}

/// Owns the provider WebViews and the small, allowlisted bridge that enriches
/// a user's existing provider send with Browsemium context.
@MainActor
@Observable
public final class ProviderPanelController {
    public private(set) var revision: Int = 0
    public private(set) var activeProvider: AIProviderID?

    /// Returns the prompt that should replace the provider's outgoing draft.
    /// The callback is installed by the dock so metadata is read from the
    /// active browser tab at submit time, never from a stale cached value.
    public var prepareComposerMessage: (@MainActor (AIProviderID, String) async throws -> ProviderComposerPreparation)?
    /// Called after preparation and again after provider file upload. A false
    /// result means the browser page or provider changed while work was in
    /// flight, so the original draft must remain unsent.
    public var isComposerPreparationCurrent: (@MainActor (AIProviderID, UUID) -> Bool)?
    public var didSubmitComposerMessage: (@MainActor (AIProviderID, UUID) -> Void)?
    public var didAbortComposerMessage: (@MainActor (AIProviderID, UUID) -> Void)?
    public var didFailComposerMessage: (@MainActor (AIProviderID, String) -> Void)?

    private let factory = WebViewFactory()
    private var webViews: [AIProviderID: WKWebView] = [:]
    private var bridgeHandlers: [AIProviderID: ComposerBridgeMessageHandler] = [:]
    private var uiDelegates: [AIProviderID: ProviderPanelUIDelegate] = [:]
    private var pendingURLs: [AIProviderID: URL] = [:]
    private var lastTrustedURLs: [AIProviderID: URL] = [:]
    private var pendingFileURLs: [AIProviderID: [URL]] = [:]
    private var stagedFileRoot: URL?
    /// Only one native preparation may mutate the shared page-context staging
    /// area for a provider at a time.
    private var pendingComposerTokens: [AIProviderID: String] = [:]
    private var pendingComposerTasks: [AIProviderID: Task<Void, Never>] = [:]

    public init() {}

    /// Restricts provider uploads to the per-dock staging directory. The
    /// fallback temporary-directory check keeps the controller safe when it is
    /// used independently in tests or a host integration.
    public func setStagedFileRoot(_ root: URL) {
        stagedFileRoot = root.resolvingSymlinksInPath().standardizedFileURL
    }

    public var liveWebViewCount: Int { webViews.count }

    public func webView(for provider: AIProviderID) -> WKWebView {
        if let existing = webViews[provider] {
            return existing
        }

        let configuration = factory.makeConfiguration(store: .persistent)
        let handler = ComposerBridgeMessageHandler(owner: self, provider: provider)
        let uiDelegate = ProviderPanelUIDelegate(owner: self, provider: provider)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.composerBridgeScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        configuration.userContentController.add(handler, name: Self.bridgeName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        webView.uiDelegate = uiDelegate
        bridgeHandlers[provider] = handler
        uiDelegates[provider] = uiDelegate

        let initialURL = pendingURLs.removeValue(forKey: provider)
            ?? lastTrustedURLs[provider]
            ?? ProviderPanelDescriptor.descriptor(for: provider).baseURL
        webView.load(URLRequest(url: initialURL))
        webViews[provider] = webView
        activeProvider = provider
        revision += 1
        return webView
    }

    public func open(url: URL, provider: AIProviderID) {
        guard ProviderPanelDescriptor.descriptor(for: provider).trusts(url) else { return }
        lastTrustedURLs[provider] = url
        if let webView = webViews[provider] {
            cancelPendingComposer(for: provider)
            webView.load(URLRequest(url: url))
        } else {
            pendingURLs[provider] = url
            _ = webView(for: provider)
        }
        activeProvider = provider
    }

    public func suspendInactive(except provider: AIProviderID?) {
        for (key, webView) in webViews where key != provider {
            cancelPendingComposer(for: key)
            remember(url: webView.url, for: key)
            webView.removeFromSuperview()
            webView.stopLoading()
        }
    }

    public func release(except provider: AIProviderID?) {
        let keys = webViews.keys.filter { $0 != provider }
        for key in keys { release(provider: key) }
        activeProvider = provider
        revision += 1
    }

    public func releaseAll() {
        for key in Array(webViews.keys) { release(provider: key) }
        pendingURLs.removeAll()
        activeProvider = nil
        revision += 1
    }

    private func release(provider: AIProviderID) {
        cancelPendingComposer(for: provider)
        guard let webView = webViews.removeValue(forKey: provider) else { return }
        remember(url: webView.url, for: provider)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName)
        webView.removeFromSuperview()
        bridgeHandlers.removeValue(forKey: provider)
        uiDelegates.removeValue(forKey: provider)
    }

    private func cancelPendingComposer(for provider: AIProviderID) {
        pendingComposerTasks.removeValue(forKey: provider)?.cancel()
        pendingComposerTokens.removeValue(forKey: provider)
        pendingFileURLs.removeValue(forKey: provider)
    }

    private func remember(url: URL?, for provider: AIProviderID) {
        guard let url,
              ProviderPanelDescriptor.descriptor(for: provider).trusts(url) else { return }
        lastTrustedURLs[provider] = url
    }

    fileprivate func receiveComposerMessage(
        _ message: WKScriptMessage,
        provider: AIProviderID
    ) {
        guard let webView = message.webView,
              webViews[provider] === webView,
              let currentURL = webView.url,
              ProviderPanelDescriptor.descriptor(for: provider).trusts(currentURL),
              message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let token = body["token"] as? String,
              let text = body["text"] as? String,
              !token.isEmpty else { return }

        guard pendingComposerTokens[provider] == nil else {
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                _ = try? await webView.callAsyncJavaScript(
                    "window.__browsemiumReject && window.__browsemiumReject(token); return true;",
                    arguments: ["token": token],
                    in: nil,
                    contentWorld: .page
                )
                self.didFailComposerMessage?(provider, "A message is already being prepared. Your draft is still in place.")
            }
            return
        }
        pendingComposerTokens[provider] = token

        let task = Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            var preparationID: UUID?
            defer {
                if self.pendingComposerTokens[provider] == token {
                    self.pendingComposerTokens.removeValue(forKey: provider)
                    self.pendingComposerTasks.removeValue(forKey: provider)
                }
            }
            do {
                let preparation = try await self.prepareComposerMessage?(provider, text)
                    ?? ProviderComposerPreparation(text: text)
                preparationID = preparation.id
                try Task.checkCancellation()
                guard self.webViews[provider] === webView,
                      let currentURL = webView.url,
                      ProviderPanelDescriptor.descriptor(for: provider).trusts(currentURL) else {
                    throw BrowsemiumError.providerUploadFailed("The AI provider changed pages while the message was being prepared. Your draft is still in place.")
                }
                guard self.isComposerPreparationCurrent?(provider, preparation.id) ?? true else {
                    throw BrowsemiumError.captureUnavailable("The active page changed while the message was being prepared. Your draft is still in place.")
                }
                if !preparation.fileURLs.isEmpty {
                    try await self.uploadFiles(preparation.fileURLs, to: provider)
                }
                try Task.checkCancellation()
                guard self.webViews[provider] === webView,
                      let currentURL = webView.url,
                      ProviderPanelDescriptor.descriptor(for: provider).trusts(currentURL),
                      self.isComposerPreparationCurrent?(provider, preparation.id) ?? true else {
                    throw BrowsemiumError.providerUploadFailed("The page or provider changed while the attachment was uploading. Your draft is still in place.")
                }
                let payload: [String: String] = ["token": token, "text": preparation.text]
                let resolved = try await webView.callAsyncJavaScript(
                    "return window.__browsemiumResolve(payload);",
                    arguments: ["payload": payload],
                    in: nil,
                    contentWorld: .page
                )
                guard resolved as? Bool == true else {
                    throw BrowsemiumError.providerUploadFailed("The provider composer timed out. Your draft is still in place; press Send again.")
                }
                try Task.checkCancellation()
                self.didSubmitComposerMessage?(provider, preparation.id)
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription
                    ?? "The message could not be sent with its context."
                let isCurrentWebView = self.webViews[provider] === webView
                if let preparationID {
                    self.didAbortComposerMessage?(provider, preparationID)
                }
                if isCurrentWebView {
                    _ = try? await webView.callAsyncJavaScript(
                        "window.__browsemiumReject && window.__browsemiumReject(token); return true;",
                        arguments: ["token": token],
                        in: nil,
                        contentWorld: .page
                    )
                    if !Task.isCancelled {
                        self.didFailComposerMessage?(provider, reason)
                    }
                }
            }
        }
        pendingComposerTasks[provider] = task
    }

    /// Uploads staged files through the provider's own file input. WebKit
    /// calls the UI delegate for the input click; the delegate supplies only
    /// URLs that were explicitly staged by Browsemium.
    public func uploadFiles(_ urls: [URL], to provider: AIProviderID) async throws {
        guard !urls.isEmpty,
              let webView = webViews[provider],
              let currentURL = webView.url,
              ProviderPanelDescriptor.descriptor(for: provider).trusts(currentURL) else {
            throw BrowsemiumError.providerUploadFailed("The AI provider page is not ready for file upload.")
        }
        guard urls.allSatisfy(isSafeStagedFile) else {
            throw BrowsemiumError.fileUnavailable("One of the selected files is no longer available.")
        }

        pendingFileURLs[provider] = urls
        defer { pendingFileURLs[provider] = nil }
        try Task.checkCancellation()
        let result = try await webView.callAsyncJavaScript(
            Self.fileUploadScript,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        try Task.checkCancellation()
        guard webViews[provider] === webView,
              let currentURL = webView.url,
              ProviderPanelDescriptor.descriptor(for: provider).trusts(currentURL) else {
            throw BrowsemiumError.providerUploadFailed("The AI provider changed pages during file upload. Your draft is still in place.")
        }
        let uploadedNames = (result as? [String]) ?? []
        let expectedNames = urls.map(\.lastPathComponent)
        guard Self.containsFileNames(uploadedNames, expected: expectedNames) else {
            throw BrowsemiumError.providerUploadFailed("The provider did not confirm all selected files.")
        }
    }

    private static func containsFileNames(_ uploaded: [String], expected: [String]) -> Bool {
        var remaining = uploaded
        for name in expected {
            guard let index = remaining.firstIndex(of: name) else { return false }
            remaining.remove(at: index)
        }
        return true
    }

    fileprivate func takePendingFileURLs(for provider: AIProviderID) -> [URL]? {
        pendingFileURLs.removeValue(forKey: provider)
    }

    fileprivate func showNativeFilePanel(
        for provider: AIProviderID,
        parameters: WKOpenPanelParameters,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        guard let webView = webViews[provider],
              let currentURL = webView.url,
              ProviderPanelDescriptor.descriptor(for: provider).trusts(currentURL) else {
            completionHandler(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Upload to \(ProviderPanelDescriptor.descriptor(for: provider).displayName)"
        panel.prompt = "Upload"
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.allowedContentTypes = [
            .image,
            .pdf,
            .plainText,
            .json,
            .commaSeparatedText,
            UTType(filenameExtension: "md") ?? .plainText
        ]
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }

    private func isSafeStagedFile(_ url: URL) -> Bool {
        let root = stagedFileRoot ?? FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let candidate = url
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return false }
        guard let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static let bridgeName = "browsemiumComposer"

    /// The bridge only observes a user gesture in a provider composer. It
    /// never finds or submits a message by itself. A timeout leaves the draft
    /// in place and reports failure, so a provider DOM change cannot create a
    /// duplicate send or silently discard the user's message.
    private static let composerBridgeScript = #"""
    (() => {
      if (window.__browsemiumComposerInstalled) return;
      window.__browsemiumComposerInstalled = true;
      const pending = new Map();
      let replaying = false;

      const editable = (element) => element && (
        element instanceof HTMLTextAreaElement ||
        element.isContentEditable ||
        element.getAttribute?.('contenteditable') === 'true'
      );

      const visible = (element) => {
        if (!element || !editable(element)) return false;
        const style = window.getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
      };

      const visibleControl = (element) => {
        if (!element || !element.isConnected) return false;
        const style = window.getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.display !== 'none' && style.visibility !== 'hidden' &&
          style.pointerEvents !== 'none' && rect.width > 0 && rect.height > 0;
      };

      const enabledControl = (element) => visibleControl(element) &&
        element.getAttribute('aria-disabled') !== 'true' &&
        element.disabled !== true;

      const valueOf = (element) => !element ? '' : element instanceof HTMLTextAreaElement
        ? element.value
        : element.innerText || element.textContent || '';

      const liveInput = (preferred) => {
        if (preferred && preferred.isConnected && visible(preferred)) return preferred;
        const candidates = [...document.querySelectorAll('textarea,[contenteditable]')].filter(visible);
        return candidates.find((candidate) => valueOf(candidate).trim()) || candidates[0] || null;
      };

      const currentInput = (event) => {
        const target = event.target instanceof Element ? event.target : null;
        const form = target?.closest('form');
        const candidates = [];
        const targetedEditor = target?.closest('textarea,[contenteditable]');
        if (targetedEditor && editable(targetedEditor)) candidates.push(targetedEditor);
        if (target && editable(target)) candidates.push(target);
        if (form) candidates.push(...form.querySelectorAll('textarea,[contenteditable]'));
        candidates.push(...document.querySelectorAll('textarea,[contenteditable]'));
        return candidates.find(visible);
      };

      const sendButton = (event, input) => {
        const target = event.target instanceof Element ? event.target : null;
        const clicked = target?.closest('button,[role="button"]');
        if (clicked && visibleControl(clicked) && visible(input)) return clicked;
        const form = input?.closest('form');
        const selector = 'button[type="submit"],[role="button"][aria-label*="send" i],button[aria-label*="send" i],[data-testid*="send" i]';
        const candidates = [
          ...(form ? [...form.querySelectorAll(selector)] : []),
          ...document.querySelectorAll(selector)
        ];
        return candidates.find(enabledControl) || candidates.find(visibleControl) || null;
      };

      const setValue = (element, value) => {
        if (element instanceof HTMLTextAreaElement) {
          const prototype = Object.getPrototypeOf(element);
          const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
          setter?.call(element, value);
          element.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
          element.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
        } else {
          element.focus();
          const selection = window.getSelection();
          const range = document.createRange();
          range.selectNodeContents(element);
          selection?.removeAllRanges();
          selection?.addRange(range);
          let inserted = false;
          try {
            inserted = document.execCommand('insertText', false, value);
          } catch (_) {
          }
          if (!inserted) {
            element.textContent = value;
            element.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: value }));
          }
        }
      };

      const waitForSendControl = (entry) => new Promise((resolve) => {
        const started = Date.now();
        const deadline = started + 15000;
        const poll = () => {
          const input = liveInput(entry.input);
          const button = sendButton({ target: null }, input);
          if (button && enabledControl(button)) {
            resolve({ input, button, hasButton: true });
            return;
          }
          // If a provider has no identifiable button, give its attachment
          // UI a short chance to render before using the editor's Enter path.
          // If it does expose a disabled button, wait for it rather than
          // firing a no-op click and falsely reporting success.
          if (!button && Date.now() - started >= 500) {
            resolve({ input, button: null, hasButton: false });
            return;
          }
          if (Date.now() >= deadline) {
            resolve({ input, button, hasButton: Boolean(button) });
            return;
          }
          setTimeout(poll, 80);
        };
        poll();
      });

      const replay = async (entry, text) => {
        if (!entry) return false;
        let input = liveInput(entry.input);
        if (!input) return false;
        if (text !== null) setValue(input, text);
        replaying = true;
        try {
          // Providers commonly replace the composer and its Send button after
          // an attachment finishes uploading. Never rely on the original DOM
          // node; reacquire the live control before replaying the user's send.
          const ready = await waitForSendControl(entry);
          input = ready.input || liveInput(entry.input);
          if (ready.button && enabledControl(ready.button) && visible(input)) {
            ready.button.click();
          } else if (!ready.hasButton && visible(input)) {
            input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true }));
            input.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true }));
          } else {
            return false;
          }
        } finally {
          queueMicrotask(() => { replaying = false; });
        }
        return true;
      };

      window.__browsemiumResolve = (payload) => {
        const entry = pending.get(payload?.token);
        if (!entry) return false;
        pending.delete(payload.token);
        clearTimeout(entry.timer);
        return replay(entry, typeof payload.text === 'string' ? payload.text : null);
      };

      window.__browsemiumReject = (token) => {
        const entry = pending.get(token);
        if (!entry) return false;
        pending.delete(token);
        clearTimeout(entry.timer);
        return true;
      };

      const intercept = (event) => {
        if (replaying || event.defaultPrevented) return;
        if (event.type === 'keydown' && (event.key !== 'Enter' || event.shiftKey || event.isComposing)) return;
        if (event.type === 'click') {
          const target = event.target instanceof Element ? event.target : null;
          const button = target?.closest('button,[role="button"]');
          if (!button) return;
          const label = [button.getAttribute('aria-label'), button.getAttribute('title'), button.getAttribute('data-testid'), button.textContent]
            .filter(Boolean).join(' ').toLowerCase();
          if (button.type !== 'submit' && !/send|submit|ask|message/.test(label)) return;
        }
        const input = currentInput(event);
        const text = valueOf(input).trim();
        if (!input || !text) return;
        if ([...pending.values()].some((entry) => entry.input === input)) {
          event.preventDefault();
          event.stopImmediatePropagation();
          return;
        }

        event.preventDefault();
        event.stopImmediatePropagation();
        const token = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
        const entry = { input, button: sendButton(event, input), timer: null };
        entry.timer = setTimeout(() => {
          pending.delete(token);
        }, 60000);
        pending.set(token, entry);
        try {
          window.webkit.messageHandlers.browsemiumComposer.postMessage({ token, text });
        } catch (_) {
          pending.delete(token);
          clearTimeout(entry.timer);
          void replay(entry, null);
        }
      };

      document.addEventListener('keydown', intercept, true);
      document.addEventListener('click', intercept, true);
    })();
    """#

    private static let fileUploadScript = #"""
    (() => {
      const inputs = Array.from(document.querySelectorAll('input[type="file"]'));
      const input = inputs.find((candidate) => {
        const rect = candidate.getBoundingClientRect();
        const style = window.getComputedStyle(candidate);
        return style.display !== 'none' && style.visibility !== 'hidden' && (rect.width > 0 || rect.height > 0);
      }) || inputs[0];
      if (!input) throw new Error('No provider file input was found.');
      return new Promise((resolve, reject) => {
        let finished = false;
        const finish = () => {
          if (finished) return;
          finished = true;
          resolve(Array.from(input.files || []).map((file) => file.name));
        };
        input.addEventListener('change', finish, { once: true });
        try { input.click(); } catch (error) { reject(error); return; }
        setTimeout(finish, 15000);
      });
    })()
    """#
}

@MainActor
private final class ComposerBridgeMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: ProviderPanelController?
    let provider: AIProviderID

    init(owner: ProviderPanelController, provider: AIProviderID) {
        self.owner = owner
        self.provider = provider
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "browsemiumComposer" else { return }
        owner?.receiveComposerMessage(message, provider: provider)
    }
}

@MainActor
private final class ProviderPanelUIDelegate: NSObject, WKUIDelegate {
    weak var owner: ProviderPanelController?
    let provider: AIProviderID

    init(owner: ProviderPanelController, provider: AIProviderID) {
        self.owner = owner
        self.provider = provider
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        guard frame.isMainFrame, let owner else {
            completionHandler(nil)
            return
        }
        if let staged = owner.takePendingFileURLs(for: provider) {
            completionHandler(staged)
        } else {
            owner.showNativeFilePanel(
                for: provider,
                parameters: parameters,
                completionHandler: completionHandler
            )
        }
    }
}
