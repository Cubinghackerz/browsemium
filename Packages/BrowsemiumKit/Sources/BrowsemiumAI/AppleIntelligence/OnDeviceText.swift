import Foundation

/// Pure helpers for working inside a small on-device context window. They
/// know nothing about Apple's framework, so they run (and are tested) on any
/// machine and in the headless build.
public enum OnDeviceText {
    /// Characters per token used for budgeting. Deliberately pessimistic: an
    /// estimate that is too generous overflows the window, while one that is
    /// too cautious only summarises a little sooner.
    public static let charactersPerToken = 3

    /// Tokens kept back for the instructions and the model's own wrapper.
    public static let overheadTokens = 600

    /// How many characters of prompt a window can take once room for the
    /// reply and the fixed overhead is set aside. Never below a floor, so a
    /// misreported window cannot produce a zero budget.
    public static func inputCharacterBudget(
        contextTokens: Int,
        reservedOutputTokens: Int
    ) -> Int {
        let usable = contextTokens - reservedOutputTokens - overheadTokens
        return max(1_500, usable * charactersPerToken)
    }

    /// Splits text into pieces no longer than `maxCharacters`, preferring
    /// paragraph breaks, then sentence ends, then spaces, and only cutting
    /// mid-word when a single word is longer than the limit. Concatenating
    /// the pieces reproduces the input exactly.
    public static func chunks(of text: String, maxCharacters: Int) -> [String] {
        let limit = max(1, maxCharacters)
        guard text.count > limit else { return text.isEmpty ? [] : [text] }
        var result: [String] = []
        var remaining = Substring(text)
        while remaining.count > limit {
            let window = remaining.prefix(limit)
            let cut = breakIndex(in: window) ?? window.endIndex
            result.append(String(remaining[remaining.startIndex..<cut]))
            remaining = remaining[cut...]
        }
        if !remaining.isEmpty { result.append(String(remaining)) }
        return result
    }

    /// The index just after the best boundary in the second half of the
    /// window, so pieces never collapse to a few characters.
    private static func breakIndex(in window: Substring) -> Substring.Index? {
        let floor = window.index(window.startIndex, offsetBy: window.count / 2)
        let tail = window[floor...]
        for separator in ["\n\n", "\n", ". ", "? ", "! ", " "] {
            if let range = tail.range(of: separator, options: .backwards) {
                return range.upperBound
            }
        }
        return nil
    }

    /// Streaming snapshots are cumulative. This returns only the text that is
    /// new relative to what has already been emitted, or nil when the model
    /// rewrote earlier text (a delta cannot express that, so the caller keeps
    /// what it has until the text extends again).
    public static func delta(emitted: String, snapshot: String) -> String? {
        guard snapshot.hasPrefix(emitted) else { return nil }
        let new = snapshot.dropFirst(emitted.count)
        return new.isEmpty ? nil : String(new)
    }
}
