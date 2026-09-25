import BrowsemiumCore
import Testing

@Test
func fuzzyMatchesSubsequences() {
    #expect(FuzzyMatcher.matches(query: "ghb", candidate: "GitHub"))
    #expect(FuzzyMatcher.matches(query: "gpr", candidate: "GitHub Pull Requests"))
    #expect(FuzzyMatcher.matches(query: "mail", candidate: "Mail"))
    #expect(!FuzzyMatcher.matches(query: "zzz", candidate: "GitHub"))
    // Order matters: the query's characters must appear in sequence.
    #expect(!FuzzyMatcher.matches(query: "bug", candidate: "GitHub"))
    #expect(FuzzyMatcher.matches(query: "bug", candidate: "GitHub Upgrade"))
}

@Test
func fuzzyIsCaseInsensitive() {
    #expect(FuzzyMatcher.matches(query: "GITHUB", candidate: "github.com"))
    #expect(FuzzyMatcher.matches(query: "github", candidate: "GitHub"))
}

@Test
func fuzzyRanksConsecutiveRunsAboveScatteredCharacters() {
    let consecutive = FuzzyMatcher.score(query: "mail", candidate: "Mail")!
    let scattered = FuzzyMatcher.score(query: "mail", candidate: "Mountain Air Island Lake")!
    #expect(consecutive > scattered)
}

@Test
func fuzzyRanksWordBoundaryMatchesAboveMiddleOfWord() {
    let initials = FuzzyMatcher.score(query: "gp", candidate: "GitHub Pull")!
    let insideWord = FuzzyMatcher.score(query: "gp", candidate: "Magpie")!
    #expect(initials > insideWord)
}

@Test
func fuzzyPrefersPrefixMatches() {
    let prefix = FuzzyMatcher.score(query: "set", candidate: "Settings")!
    let later = FuzzyMatcher.score(query: "set", candidate: "Reset Everything")!
    #expect(prefix > later)
}

@Test
func fuzzyPrefersShorterCandidates() {
    let short = FuzzyMatcher.score(query: "mail", candidate: "Mail")!
    let long = FuzzyMatcher.score(query: "mail", candidate: "Mailbox Management Interface Layer")!
    #expect(short > long)
}

@Test
func fuzzyEmptyQueryScoresZero() {
    #expect(FuzzyMatcher.score(query: "", candidate: "Anything") == 0)
    #expect(FuzzyMatcher.score(query: "   ", candidate: "Anything") == 0)
}

@Test
func fuzzyRejectsQueriesLongerThanTheCandidate() {
    #expect(FuzzyMatcher.score(query: "github", candidate: "git") == nil)
}
