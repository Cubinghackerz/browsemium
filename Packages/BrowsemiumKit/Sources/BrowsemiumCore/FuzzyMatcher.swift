import Foundation

/// Subsequence matching for the command palette. `score` returns nil when the
/// query's characters do not appear in order in the candidate; a higher score
/// means a tighter match — consecutive runs and word-boundary hits rank above
/// scattered ones, so "gh" finds "GitHub" ahead of "Gmail/Hub".
public enum FuzzyMatcher {
    public static func matches(query: String, candidate: String) -> Bool {
        score(query: query, candidate: candidate) != nil
    }

    public static func score(query: String, candidate: String) -> Int? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return 0 }
        let needle = Array(query.lowercased())
        let haystack = Array(candidate.lowercased())
        guard needle.count <= haystack.count else { return nil }

        var score = 0
        var haystackIndex = 0
        var previousMatchIndex = -1

        for character in needle {
            var found = false
            while haystackIndex < haystack.count {
                if haystack[haystackIndex] == character {
                    score += 1
                    if previousMatchIndex == haystackIndex - 1 {
                        // Consecutive characters: the match reads as typed.
                        score += 4
                    }
                    if haystackIndex == 0 || !haystack[haystackIndex - 1].isLetter && !haystack[haystackIndex - 1].isNumber {
                        // Word boundary (start of string, or after a space,
                        // dash, dot, slash): initials-style matches.
                        score += 3
                    }
                    previousMatchIndex = haystackIndex
                    haystackIndex += 1
                    found = true
                    break
                }
                haystackIndex += 1
            }
            guard found else { return nil }
        }

        // Prefer shorter candidates: "Mail" beats "Mailbox Manager" for "mail".
        score -= (haystack.count - needle.count) / 8
        // Exact prefix is the strongest signal of intent.
        if candidate.lowercased().hasPrefix(query.lowercased()) {
            score += 12
        }
        return score
    }
}
