import BrowsemiumUI
import Foundation
import SwiftUI
import Testing

@Test
func legacySizesMapOntoThreeTextStepsAndTitle() {
    #expect(BrowserType.step(forLegacySize: 10) == .caption)
    #expect(BrowserType.step(forLegacySize: 10.5) == .caption)
    #expect(BrowserType.step(forLegacySize: 11) == .caption)
    #expect(BrowserType.step(forLegacySize: 11.5) == .small)
    #expect(BrowserType.step(forLegacySize: 12) == .small)
    #expect(BrowserType.step(forLegacySize: 12.5) == .body)
    #expect(BrowserType.step(forLegacySize: 13.5) == .body)
    #expect(BrowserType.step(forLegacySize: 15) == .title)
    // Icon glyph sizes and display sizes are not chrome text.
    #expect(BrowserType.step(forLegacySize: 9) == nil)
    #expect(BrowserType.step(forLegacySize: 22) == nil)
}

@Test
func chromeTextNeverDropsBelowElevenPoints() {
    for step in [BrowserType.Step.caption, .small, .body, .title] {
        #expect(step.size >= 11)
    }
}

/// Keeps the scale from eroding: text sizes between 10 and 16 pt are set only
/// through `BrowserType`. Larger display sizes and smaller icon glyph sizes
/// may stay local.
@Test
func noChromeTextSizeIsHardCodedOutsideTheScale() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<2 { root.deleteLastPathComponent() } // …/Tests
    root.deleteLastPathComponent()                    // …/BrowsemiumKit
    let sources = root.appendingPathComponent("Sources/BrowsemiumUI", isDirectory: true)
    let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
    #expect(files.count > 20)
    let pattern = try NSRegularExpression(pattern: #"\.system\(size: (1[0-6](?:\.[0-9]+)?)\b"#)
    var offenders: [String] = []
    for file in files where file.lastPathComponent != "Theme.swift" {
        let text = try String(contentsOf: file, encoding: .utf8)
        let range = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: range) {
            let size = (text as NSString).substring(with: match.range(at: 1))
            if let value = Double(size), value >= 10, value <= 16 { offenders.append("\(file.lastPathComponent): size \(size)") }
        }
    }
    #expect(offenders.isEmpty, Comment(rawValue: offenders.joined(separator: "\n")))
}
