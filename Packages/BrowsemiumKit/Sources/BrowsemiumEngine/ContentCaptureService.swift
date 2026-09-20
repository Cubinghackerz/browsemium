import BrowsemiumCore
import AppKit
import Foundation
import WebKit

@MainActor
public final class ContentCaptureService {
    public struct Policy: Sendable {
        public var maxTextCharacters: Int
        public var maxImageDimension: Int
        public var maxImageBytes: Int
        public var maxFullPageHeight: Int

        public init(
            maxTextCharacters: Int = 60_000,
            maxImageDimension: Int = 2048,
            maxImageBytes: Int = 3_500_000,
            maxFullPageHeight: Int = 8_000
        ) {
            self.maxTextCharacters = maxTextCharacters
            self.maxImageDimension = maxImageDimension
            self.maxImageBytes = maxImageBytes
            self.maxFullPageHeight = maxFullPageHeight
        }
    }

    public let policy: Policy
    private let readabilitySource: String?

    public init(policy: Policy = Policy()) {
        self.policy = policy
        readabilitySource = Self.loadReadabilitySource()
    }

    public func capture(_ request: CaptureRequest, from webView: WKWebView, tabID: TabID?) async throws -> CapturedContext {
        var attachments: [AIContextAttachment] = []

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

        if request.kinds.contains(.fullPageImage) {
            let image = try await fullPageImage(from: webView)
            attachments.append(.fullPageImage(image))
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
        let bounds = webView.bounds
        guard !bounds.isEmpty else {
            throw BrowsemiumError.captureUnavailable("The page is not visible yet. Wait for it to finish loading, then capture again.")
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: bounds.size)
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

    /// Captures a bounded full-page image by taking viewport snapshots while
    /// scrolling. WKSnapshotConfiguration only accepts rectangles inside the
    /// web view's bounds, so asking WebKit for one giant rectangle is not a
    /// valid full-page strategy. The original scroll position is restored on
    /// both success and failure so capture never strands the user's page.
    private func fullPageImage(from webView: WKWebView) async throws -> PageImageContext {
        let bounds = webView.bounds
        guard !bounds.isEmpty else {
            throw BrowsemiumError.captureUnavailable("The page is not visible yet. Wait for it to finish loading, then capture again.")
        }

        _ = try? await webView.callAsyncJavaScript(
            """
            if (document.fonts && document.fonts.ready) {
              await document.fonts.ready.catch(() => undefined);
            }
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            return true;
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let metrics = try await pageMetrics(from: webView)
        let viewportHeight = max(metrics.viewportHeight, 1)
        let documentHeight = max(metrics.documentHeight, viewportHeight)
        let captureHeight = min(documentHeight, Double(policy.maxFullPageHeight))
        let positions = snapshotPositions(
            documentHeight: captureHeight,
            viewportHeight: viewportHeight
        )
        let originalX = metrics.scrollX
        let originalY = metrics.scrollY

        do {
            var canvas: CGContext?
            var canvasWidth = 0
            var canvasHeight = 0
            var scale = 1.0

            for position in positions {
                try await scroll(webView, toX: originalX, y: position)
                let configuration = WKSnapshotConfiguration()
                // Snapshot rectangles are expressed in the web view's
                // coordinate system. Normalize the origin so a non-zero NSView
                // bounds origin can never produce an empty/blank tile.
                configuration.rect = CGRect(origin: .zero, size: bounds.size)
                configuration.afterScreenUpdates = true
                let tile = try await webView.takeSnapshot(configuration: configuration)
                var tileRect = CGRect(origin: .zero, size: tile.size)
                guard let tileImage = tile.cgImage(forProposedRect: &tileRect, context: nil, hints: nil) else {
                    throw BrowsemiumError.captureFailed("A full-page screenshot tile could not be read.")
                }

                if canvas == nil {
                    scale = Double(tileImage.width) / max(metrics.viewportWidth, 1)
                    canvasWidth = max(1, tileImage.width)
                    canvasHeight = max(1, Int((captureHeight * scale).rounded()))
                    guard let created = CGContext(
                        data: nil,
                        width: canvasWidth,
                        height: canvasHeight,
                        bitsPerComponent: 8,
                        bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    ) else {
                        throw BrowsemiumError.captureFailed("The full-page screenshot could not be allocated.")
                    }
                    // Provider previews render transparent images on white.
                    // Use WebKit's actual under-page color instead, otherwise a
                    // transparent page/background is indistinguishable from a
                    // failed capture in the provider composer.
                    let background = (webView.underPageBackgroundColor ?? NSColor.windowBackgroundColor)
                        .usingColorSpace(.deviceRGB)
                        ?? NSColor.windowBackgroundColor
                    created.setFillColor(background.cgColor)
                    created.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
                    canvas = created
                }

                guard let canvas else { continue }
                let top = Int((position * scale).rounded())
                let destinationY = canvasHeight - top - tileImage.height
                let destination = CGRect(
                    x: 0,
                    y: CGFloat(destinationY),
                    width: CGFloat(canvasWidth),
                    height: CGFloat(tileImage.height)
                )
                canvas.saveGState()
                canvas.clip(to: CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
                canvas.interpolationQuality = .high
                canvas.draw(tileImage, in: destination)
                canvas.restoreGState()
            }

            guard let canvas, let image = canvas.makeImage() else {
                throw BrowsemiumError.captureFailed("The full-page screenshot was empty.")
            }
            let result = try ScreenshotEncoder.encode(
                NSImage(cgImage: image, size: NSSize(width: canvasWidth, height: canvasHeight)),
                maxDimension: policy.maxImageDimension,
                maxBytes: policy.maxImageBytes
            )
            try await scroll(webView, toX: originalX, y: originalY)
            return result
        } catch {
            try? await scroll(webView, toX: originalX, y: originalY)
            throw error
        }
    }

    private struct PageMetrics {
        let viewportWidth: Double
        let viewportHeight: Double
        let documentHeight: Double
        let scrollX: Double
        let scrollY: Double
    }

    private func pageMetrics(from webView: WKWebView) async throws -> PageMetrics {
        let script = """
        return ({
          viewportWidth: Math.max(window.innerWidth || 0, 1),
          viewportHeight: Math.max(window.innerHeight || 0, 1),
          documentHeight: Math.max(
            document.body?.scrollHeight || 0,
            document.documentElement?.scrollHeight || 0,
            document.documentElement?.offsetHeight || 0
          ),
          scrollX: window.scrollX || 0,
          scrollY: window.scrollY || 0
        })
        """
        let result = try await webView.callAsyncJavaScript(
            script,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard let values = result as? [String: Any],
              let viewportWidth = Self.number(values["viewportWidth"]),
              let viewportHeight = Self.number(values["viewportHeight"]),
              let documentHeight = Self.number(values["documentHeight"]),
              let scrollX = Self.number(values["scrollX"]),
              let scrollY = Self.number(values["scrollY"]) else {
            throw BrowsemiumError.captureFailed("The page dimensions could not be measured.")
        }
        return PageMetrics(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            documentHeight: documentHeight,
            scrollX: scrollX,
            scrollY: scrollY
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private func snapshotPositions(documentHeight: Double, viewportHeight: Double) -> [Double] {
        var positions: [Double] = []
        var position = 0.0
        while position < documentHeight {
            positions.append(position)
            position += viewportHeight
        }
        let bottom = max(0, documentHeight - viewportHeight)
        if positions.last != bottom {
            positions.append(bottom)
        }
        return positions
    }

    private func scroll(_ webView: WKWebView, toX x: Double, y: Double) async throws {
        _ = try await webView.callAsyncJavaScript(
            """
            window.scrollTo({ left: x, top: y, behavior: 'auto' });
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            return true;
            """,
            arguments: ["x": x, "y": y],
            in: nil,
            contentWorld: .page
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
