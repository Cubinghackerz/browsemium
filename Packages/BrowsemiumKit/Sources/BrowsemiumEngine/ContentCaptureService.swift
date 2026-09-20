import BrowsemiumCore
import Foundation
import WebKit

@MainActor
public final class ContentCaptureService {
    public struct Policy: Sendable {
        public var maxTextCharacters: Int
        public var maxImageDimension: Int
        public var maxImageBytes: Int

        public init(
            maxTextCharacters: Int = 60_000,
            maxImageDimension: Int = 2048,
            maxImageBytes: Int = 3_500_000
        ) {
            self.maxTextCharacters = maxTextCharacters
            self.maxImageDimension = maxImageDimension
            self.maxImageBytes = maxImageBytes
        }
    }

    public let policy: Policy
    private let readabilitySource: String?

    public init(policy: Policy = Policy()) {
        self.policy = policy
        readabilitySource = Self.loadReadabilitySource()
    }

    public func capture(_ request: CaptureRequest, from webView: WKWebView, tabID: TabID?) async throws -> CapturedContext {        var attachments: [AIContextAttachment] = []

        if request.kinds.contains(.selection) {
            let text = try await selectionText(from: webView)
            guard !text.isEmpty else {
                throw BrowsemiumError.captureUnavailable("Select text on the page first, then share it with AI.")
            }
            attachments.append(.selection(pageText(text, webView: webView)))
        }

        if request.kinds.contains(.readablePage) {
            let extracted = try await readableText(from: webView)
            guard !extracted.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BrowsemiumError.captureUnavailable("No readable page text was found.")
            }
            attachments.append(.readablePage(pageText(extracted.text, webView: webView, titleOverride: extracted.title)))
        }

        if request.kinds.contains(.viewportImage) {
            let image = try await viewportImage(from: webView)
            attachments.append(.viewportImage(image))
        }

        guard !attachments.isEmpty else {
            throw BrowsemiumError.captureUnavailable("Nothing was captured.")
        }
        return CapturedContext(attachments: attachments)
    }

    /// Reader mode extraction: the same Readability pass used for AI context,
    /// returned as a titled article.
    public func extractArticle(from webView: WKWebView) async throws -> ReaderArticle {
        let extracted = try await readableText(from: webView)
        let text = extracted.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 400 else {
            throw BrowsemiumError.captureUnavailable("This page has no article to read.")
        }
        return ReaderArticle(
            title: extracted.title ?? webView.title ?? "Reader",
            url: webView.url,
            text: text
        )
    }

    private func pageText(_ text: String, webView: WKWebView, titleOverride: String? = nil) -> PageTextContext {
        let bounded = Self.bounded(text, limit: policy.maxTextCharacters)
        return PageTextContext(
            url: webView.url,
            title: titleOverride ?? webView.title,
            text: bounded.text,
            isTruncated: bounded.truncated
        )
    }

    private func selectionText(from webView: WKWebView) async throws -> String {
        let script = "return window.getSelection() ? window.getSelection().toString() : \"\";"
        let result = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        return (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private struct ExtractedText {
        let title: String?
        let text: String
    }

    private func readableText(from webView: WKWebView) async throws -> ExtractedText {
        let script = (readabilitySource ?? "") + Self.extractorSuffix
        let result = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        if let payload = result as? [String: Any], let text = payload["text"] as? String {
            return ExtractedText(title: payload["title"] as? String, text: text)
        }
        // Some pages return a bare string instead of the expected dictionary.
        if let text = result as? String {
            return ExtractedText(title: webView.title, text: text)
        }
        throw BrowsemiumError.captureFailed("Page text extraction returned an unexpected result.")
    }

    private func viewportImage(from webView: WKWebView) async throws -> PageImageContext {
        let bounds = webView.bounds.isEmpty ? webView.frame : webView.bounds
        guard !bounds.isEmpty else {
            throw BrowsemiumError.captureUnavailable("The page is not visible yet. Wait for it to finish loading, then capture again.")
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = bounds
        configuration.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: configuration)
        guard image.size.width >= 1, image.size.height >= 1 else {
            throw BrowsemiumError.captureFailed("The page produced an empty screenshot.")
        }
        return try ScreenshotEncoder.encode(
            image,
            maxDimension: policy.maxImageDimension,
            maxBytes: policy.maxImageBytes
        )
    }

    private static func bounded(_ text: String, limit: Int) -> (text: String, truncated: Bool) {
        guard text.count > limit else { return (text, false) }
        let endIndex = text.index(text.startIndex, offsetBy: limit)
        return (String(text[..<endIndex]), true)
    }

    private static func loadReadabilitySource() -> String? {
        guard let url = Bundle.module.url(forResource: "Readability", withExtension: "js") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static let extractorSuffix = """
    ;try {
      const readabilityClone = document.cloneNode(true);
      const article = new Readability(readabilityClone, { charThreshold: 500 }).parse();
      if (article && article.textContent && article.textContent.trim().length > 0) {
        return { strategy: "readability", title: article.title || document.title, text: article.textContent };
      }
    } catch (error) {
    }
    const fallbackClone = document.cloneNode(true);
    const removable = fallbackClone.querySelectorAll("script,style,noscript,iframe,form,input,textarea,select,button,template,svg,canvas,[hidden],[aria-hidden='true']");
    for (const node of removable) { node.remove(); }
    const body = fallbackClone.body;
    return { strategy: "conservative", title: document.title, text: body ? body.innerText : "" };
    """
}
