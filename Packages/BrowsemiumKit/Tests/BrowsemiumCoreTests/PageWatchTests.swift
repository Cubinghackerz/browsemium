import BrowsemiumCore
import Foundation
import Testing

@Test
func visibleTextIgnoresScriptsStylesCommentsAndMarkup() {
    let html = """
    <html><head><title>T</title><style>.a{color:red}</style><script>var x = "Price: 5";</script></head>
    <body><!-- hidden note --><h1>Hello&nbsp;World</h1><p class="x">Tickets &amp; seats: <b>12</b></p>
    <noscript>Enable JS</noscript><svg><text>icon</text></svg></body></html>
    """
    #expect(PageTextNormalizer.visibleText(fromHTML: html) == "T Hello World Tickets & seats: 12")
}

@Test
func hashesAreStableAndSensitiveToRealChanges() {
    let a = PageTextNormalizer.visibleText(fromHTML: "<p>Tickets on sale now</p><script>t=1</script>")
    let sameTextNewScript = PageTextNormalizer.visibleText(fromHTML: "<p>Tickets on sale now</p><script>t=2</script>")
    let changed = PageTextNormalizer.visibleText(fromHTML: "<p>Tickets sold out</p>")
    #expect(PageTextNormalizer.hash(a) == PageTextNormalizer.hash(sameTextNewScript))
    #expect(PageTextNormalizer.hash(a) != PageTextNormalizer.hash(changed))
    #expect(PageTextNormalizer.hash(a).count == 64)
}

@Test
func signInPagesAreRecognised() {
    #expect(PageTextNormalizer.looksLikeSignIn(html: "<form><input type=\"password\" name=p></form>"))
    #expect(PageTextNormalizer.looksLikeSignIn(html: "<INPUT TYPE=password>"))
    #expect(!PageTextNormalizer.looksLikeSignIn(html: "<input type=\"text\" name=\"password-hint\">"))
}

@Test
func theDiffQuotesWhatIsNewAndIgnoresNoise() {
    let before = "The shop opens at nine. Tickets are on sale. Visit us soon."
    let after = "The shop opens at nine. Tickets are sold out for Saturday. Visit us soon."
    let previous = PageWatchDiff.sentenceHashes(before)
    #expect(PageWatchDiff.change(previous: previous, newText: after) == "Tickets are sold out for Saturday")
    #expect(PageWatchDiff.change(previous: previous, newText: before) == nil)
    // Case and spacing alone are not a change.
    #expect(PageWatchDiff.change(previous: previous, newText: before.uppercased()) == nil)
    // A tiny addition (a counter) is noise.
    #expect(PageWatchDiff.change(previous: previous, newText: before + " 42") == nil)
}

@Test
func removedTextIsReportedOnlyWhenSubstantial() {
    let before = "One thing here. Another thing there. A third thing. A fourth thing. Last bit."
    let previous = PageWatchDiff.sentenceHashes(before)
    #expect(PageWatchDiff.change(previous: previous, newText: "One thing here. Another thing there.") == "Some text was removed.")
    #expect(PageWatchDiff.change(previous: previous, newText: "One thing here. Another thing there. A third thing. A fourth thing.") == nil)
}

@Test
func sentenceHashesAreShortOrderedAndBounded() {
    let hashes = PageWatchDiff.sentenceHashes("Alpha one. Beta two. Alpha one. Gamma three.")
    #expect(hashes.count == 3)
    #expect(hashes.allSatisfy { $0.count == 16 })
    let many = (0..<5_000).map { "Sentence number \($0)" }.joined(separator: ". ")
    #expect(PageWatchDiff.sentenceHashes(many).count == PageWatchDiff.maximumSentences)
}

@Test
func theScheduleHonoursIntervalsBackoffAndPausing() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let fresh = PageWatch(url: URL(string: "https://a.example/")!, title: "a")
    var dueByAge = PageWatch(url: URL(string: "https://b.example/")!, title: "b", intervalMinutes: 60)
    dueByAge.lastCheckedAt = now.addingTimeInterval(-61 * 60)
    var notYet = PageWatch(url: URL(string: "https://c.example/")!, title: "c", intervalMinutes: 60)
    notYet.lastCheckedAt = now.addingTimeInterval(-30 * 60)
    var backedOff = PageWatch(url: URL(string: "https://d.example/")!, title: "d", intervalMinutes: 15, consecutiveFailures: 2)
    backedOff.lastCheckedAt = now.addingTimeInterval(-30 * 60) // 15 min doubled twice = 60
    var paused = PageWatch(url: URL(string: "https://e.example/")!, title: "e", consecutiveFailures: PageWatchLimits.maximumConsecutiveFailures)

    let due = PageWatchSchedule.due([fresh, dueByAge, notYet, backedOff, paused], now: now)
    #expect(due.map(\.title) == ["a", "b"])
    #expect(PageWatchLimits.effectiveInterval(minutes: 5, failures: 0) == PageWatchLimits.minimumIntervalMinutes)
    #expect(PageWatchLimits.effectiveInterval(minutes: 720, failures: 5) == 24 * 60)
}
