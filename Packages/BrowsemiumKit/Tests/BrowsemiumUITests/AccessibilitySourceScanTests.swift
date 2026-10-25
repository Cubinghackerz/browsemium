import Foundation
import Testing

/// Source-level accessibility rules that are cheap to break in review:
///
/// - an icon-only `Button` needs an `.accessibilityLabel`;
/// - an animation needs Reduce Motion to be considered;
/// - a control shown only while the pointer hovers needs a route that does not
///   depend on hover (an accessibility action, a menu item or a shortcut).
///
/// These prove the rules are written into the UI sources. They do not prove
/// VoiceOver or keyboard behaviour; `QUALITY_PASS.md` lists what the owner
/// still has to check by hand. Each scanner has a self-check on a known-bad
/// and a known-good snippet, so a scanner that stops matching fails the suite
/// instead of passing vacuously.
@Suite("Accessibility source rules")
struct AccessibilitySourceScanTests {
    @Test func iconOnlyButtonsCarryAnAccessibilityLabel() throws {
        var violations: [String] = []
        for file in try uiSources() {
            for line in SourceScan.unlabelledIconButtons(in: file.text) {
                violations.append("\(file.name):\(line)")
            }
        }
        #expect(violations.isEmpty, "Icon-only buttons need .accessibilityLabel: \(violations.joined(separator: ", "))")
    }

    @Test func theIconButtonScannerCatchesWhatItClaimsToCatch() {
        let unlabelled = """
        Button {
            act()
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        """
        let labelled = unlabelled + "\n.accessibilityLabel(\"Close\")"
        let titled = "Button(\"Save\") { save() }"
        let contentLabel = "Button(action: act) {\n    Image(systemName: \"key\")\n}\n.help(\"Passwords\")"
        // A closing parenthesis at the button's indentation ends a modifier, not the view.
        let wrappedModifier = "Button(action: act) {\n    Image(systemName: \"key\")\n}\n.background(\n    Capsule()\n)\n.accessibilityLabel(\"Passwords\")"

        #expect(SourceScan.unlabelledIconButtons(in: unlabelled) == [1])
        #expect(SourceScan.unlabelledIconButtons(in: labelled).isEmpty)
        #expect(SourceScan.unlabelledIconButtons(in: titled).isEmpty, "A titled button is text, not an icon")
        #expect(SourceScan.unlabelledIconButtons(in: contentLabel) == [1], "The trailing content closure counts as the label")
        #expect(SourceScan.unlabelledIconButtons(in: wrappedModifier).isEmpty, "A label after a wrapped modifier still counts")
    }

    @Test func animationsHonourReduceMotion() throws {
        var violations: [String] = []
        for file in try uiSources() {
            for line in SourceScan.unguardedAnimationLines(in: file.text) {
                violations.append("\(file.name):\(line)")
            }
        }
        #expect(violations.isEmpty, "Animations must be gated by Reduce Motion (BrowserMotion or accessibilityReduceMotion): \(violations.joined(separator: ", "))")
    }

    @Test func theAnimationScannerCatchesAnUngatedAnimation() {
        let bad = "    .animation(.easeOut(duration: 0.2), value: isOpen)\n    withAnimation(.spring()) { x = 1 }"
        let good = "    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isOpen)\n    .animation(BrowserMotion.quick(reduceMotion: reduceMotion), value: isOpen)\n    .animation(nil, value: isOpen)\n    // withAnimation(.spring()) in a comment is not code"
        #expect(SourceScan.unguardedAnimationLines(in: bad) == [1, 2])
        #expect(SourceScan.unguardedAnimationLines(in: good).isEmpty)
    }

    @Test func hoverRevealedButtonsHaveANonHoverRoute() throws {
        var violations: [String] = []
        for file in try uiSources() where SourceScan.hasHoverOnlyButton(in: file.text) {
            if !file.text.contains(".accessibilityAction(named:") {
                violations.append(file.name)
            }
        }
        #expect(violations.isEmpty, "Hover-only buttons need an accessibility action so VoiceOver and the rotor can reach them: \(violations.joined(separator: ", "))")
    }

    @Test func theHoverScannerCatchesAHoverOnlyButton() {
        let hoverOnly = """
        if isHovering {
            Button { close() } label: { Image(systemName: "xmark") }
        }
        """
        let hoverWithoutButton = "if isHovering {\n    Rectangle().fill(.gray)\n}"
        #expect(SourceScan.hasHoverOnlyButton(in: hoverOnly))
        #expect(!SourceScan.hasHoverOnlyButton(in: hoverWithoutButton))
    }
}

// MARK: - Sources

private struct UISource {
    let name: String
    let text: String
}

private func uiSources() throws -> [UISource] {
    // This file lives in Packages/BrowsemiumKit/Tests/BrowsemiumUITests.
    var root = URL(fileURLWithPath: #filePath)
    root.deleteLastPathComponent()
    root.deleteLastPathComponent()
    root.deleteLastPathComponent()
    let directory = root.appendingPathComponent("Sources/BrowsemiumUI", isDirectory: true)
    guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
        throw ScanFailure("Could not read \(directory.path)")
    }
    var files: [UISource] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
        let text = try String(contentsOf: url, encoding: .utf8)
        files.append(UISource(name: url.lastPathComponent, text: text))
    }
    if files.isEmpty { throw ScanFailure("No Swift sources under \(directory.path)") }
    return files
}

private struct ScanFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Scanners

/// Lexical scans over Swift source. They understand string literals and
/// `//` comments, and they read a SwiftUI view expression by its indentation,
/// which is how the UI sources are written.
private enum SourceScan {
    typealias Bytes = [UInt8]

    private static let openParen = UInt8(ascii: "(")
    private static let closeParen = UInt8(ascii: ")")
    private static let openBrace = UInt8(ascii: "{")
    private static let closeBrace = UInt8(ascii: "}")
    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
    private static let slash = UInt8(ascii: "/")
    private static let newline = UInt8(ascii: "\n")
    private static let space = UInt8(ascii: " ")
    private static let tab = UInt8(ascii: "\t")

    /// The index of the bracket closing the one at `open`, skipping string
    /// literals and line comments. Nil if it never closes.
    static func closing(_ bytes: Bytes, _ open: Int) -> Int? {
        let opener = bytes[open]
        let closer: UInt8
        switch opener {
        case openParen: closer = closeParen
        case openBrace: closer = closeBrace
        default: closer = UInt8(ascii: "]")
        }
        var depth = 0
        var inString = false
        var i = open
        while i < bytes.count {
            let byte = bytes[i]
            if inString {
                if byte == backslash {
                    i += 2
                    continue
                }
                if byte == quote { inString = false }
            } else if byte == quote {
                inString = true
            } else if byte == slash, i + 1 < bytes.count, bytes[i + 1] == slash {
                while i < bytes.count, bytes[i] != newline { i += 1 }
                continue
            } else if byte == opener {
                depth += 1
            } else if byte == closer {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 95 || byte == 46
    }

    /// Every `Button` token that starts a SwiftUI button, with the byte index
    /// of the bracket that opens its arguments or action.
    static func buttonOpenings(_ bytes: Bytes) -> [(token: Int, open: Int)] {
        let needle = Array("Button".utf8)
        var found: [(Int, Int)] = []
        var i = 0
        while i + needle.count <= bytes.count {
            if bytes[i..<(i + needle.count)].elementsEqual(needle), i == 0 || !isIdentifierByte(bytes[i - 1]) {
                var j = i + needle.count
                while j < bytes.count, bytes[j] == space || bytes[j] == tab || bytes[j] == newline { j += 1 }
                if j < bytes.count, bytes[j] == openParen || bytes[j] == openBrace {
                    found.append((i, j))
                }
                i += needle.count
                continue
            }
            i += 1
        }
        return found
    }

    /// The trailing label of a button: `label: { … }`, or a bare `{ … }` that
    /// follows the arguments. Returns the closure's byte range.
    private static func trailingLabel(_ bytes: Bytes, after end: Int) -> (open: Int, close: Int)? {
        var j = end + 1
        while j < bytes.count, bytes[j] == space || bytes[j] == tab || bytes[j] == newline { j += 1 }
        let labelWord = Array("label:".utf8)
        if j + labelWord.count <= bytes.count, bytes[j..<(j + labelWord.count)].elementsEqual(labelWord) {
            j += labelWord.count
            while j < bytes.count, bytes[j] == space || bytes[j] == tab || bytes[j] == newline { j += 1 }
        }
        guard j < bytes.count, bytes[j] == openBrace, let close = closing(bytes, j) else { return nil }
        return (j, close)
    }

    /// The lines of a view expression: the line with `Button`, then every
    /// deeper-indented line, every line that continues a modifier chain, and
    /// every closing or `label:` line at the button's own indentation.
    private static func expressionLines(_ lines: [String], from index: Int) -> [String] {
        let base = indentation(lines[index])
        var result = [lines[index]]
        var k = index + 1
        while k < lines.count, k < index + 400 {
            let line = lines[k]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                result.append(line)
            } else if indentation(line) > base || trimmed.hasPrefix(".") || trimmed.hasPrefix("}") || trimmed.hasPrefix(")") || trimmed.hasPrefix("label:") {
                result.append(line)
            } else {
                break
            }
            k += 1
        }
        return result
    }

    private static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    /// Line numbers (1-based) of icon-only buttons with no accessibility label.
    static func unlabelledIconButtons(in source: String) -> [Int] {
        let bytes = Array(source.utf8)
        let lines = source.components(separatedBy: "\n")
        var offending: [Int] = []
        for opening in buttonOpenings(bytes) {
            let lineIndex = bytes[0..<opening.token].reduce(0) { $1 == newline ? $0 + 1 : $0 }
            let isParen = bytes[opening.open] == openParen
            var label: (open: Int, close: Int)?
            if let end = closing(bytes, opening.open) {
                if isParen {
                    // A title in parentheses is text. `action:` arguments take a trailing label.
                    let head = String(decoding: bytes[(opening.open + 1)..<end], as: UTF8.self)
                    if head.contains("action:") || head.contains("label:") || head.isEmpty {
                        label = trailingLabel(bytes, after: end)
                    }
                } else {
                    label = trailingLabel(bytes, after: end)
                }
            }
            guard let label else { continue }
            let body = String(decoding: bytes[label.open...label.close], as: UTF8.self)
            guard body.contains("Image("), !body.contains("Text("), !body.contains("Label(") else { continue }
            let region = expressionLines(lines, from: lineIndex).joined(separator: "\n")
            if !region.contains("accessibilityLabel") {
                offending.append(lineIndex + 1)
            }
        }
        return offending
    }

    /// Line numbers of animation calls that do not consider Reduce Motion.
    static func unguardedAnimationLines(in source: String) -> [Int] {
        var offending: [Int] = []
        for (index, line) in source.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), trimmed.contains(".animation(") || trimmed.contains("withAnimation") else { continue }
            if !(trimmed.contains("reduceMotion") || trimmed.contains("BrowserMotion") || trimmed.contains("nil")) {
                offending.append(index + 1)
            }
        }
        return offending
    }

    /// Whether a hover-gated block (`if isHovering { … }` and its variants)
    /// contains a button.
    static func hasHoverOnlyButton(in source: String) -> Bool {
        let bytes = Array(source.utf8)
        let conditions = ["if isHovering", "if hovering", "if isHovered", "if hovered"].map { Array($0.utf8) }
        var i = 0
        while i < bytes.count {
            var matched = false
            for condition in conditions where i + condition.count <= bytes.count && bytes[i..<(i + condition.count)].elementsEqual(condition) {
                matched = true
                var j = i + condition.count
                while j < bytes.count, bytes[j] != openBrace, bytes[j] != newline { j += 1 }
                if j < bytes.count, bytes[j] == openBrace, let close = closing(bytes, j) {
                    let block = String(decoding: bytes[j...close], as: UTF8.self)
                    if block.contains("Button") { return true }
                }
                i += condition.count
                break
            }
            if !matched { i += 1 }
        }
        return false
    }
}
