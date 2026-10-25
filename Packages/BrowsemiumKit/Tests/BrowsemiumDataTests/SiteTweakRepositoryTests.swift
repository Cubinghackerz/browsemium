import BrowsemiumCore
import BrowsemiumData
import Foundation
import Testing

@Test
func tweaksRoundTripPerHostAndStayLowercase() throws {
    let repository = SiteTweakRepository(database: try AppDatabase.inMemoryProfile())
    let first = try repository.add(host: "Example.COM", name: "Calm", css: "body { background: #111 }", now: Date(timeIntervalSince1970: 1))
    _ = try repository.add(host: "example.com", name: "Wide", css: ".page { max-width: none }", now: Date(timeIntervalSince1970: 2))
    _ = try repository.add(host: "other.test", name: "X", css: "p { margin: 0 }")

    let tweaks = try repository.tweaks(host: "example.com")
    #expect(tweaks.map(\.name) == ["Calm", "Wide"])
    #expect(tweaks.first?.id == first.id)
    #expect(try repository.tweaks(host: "other.test").count == 1)
    #expect(try Set(repository.hosts()) == ["example.com", "other.test"])
}

@Test
func theRepositoryRefusesWhatTheValidatorRefuses() throws {
    let repository = SiteTweakRepository(database: try AppDatabase.inMemoryProfile())
    #expect(throws: SiteTweakProblem.self) {
        try repository.add(host: "example.com", name: "Beacon", css: "a[href^='x'] { background: url(https://evil.example/x) }")
    }
    #expect(throws: SiteTweakProblem.self) {
        try repository.add(host: "example.com", name: "Empty", css: "   ")
    }
    #expect(throws: SiteTweakProblem.self) {
        let id = try repository.add(host: "example.com", name: "Fine", css: "p { color: red }").id
        try repository.update(id: id, name: "Fine", css: "@import 'x.css';")
    }
    // The valid one is untouched by the refused update.
    #expect(try repository.tweaks(host: "example.com").first?.css == "p { color: red }")
}

@Test
func togglingUpdatingAndRemovingWork() throws {
    let repository = SiteTweakRepository(database: try AppDatabase.inMemoryProfile())
    let tweak = try repository.add(host: "example.com", name: "A", css: "p { color: red }")
    try repository.setEnabled(false, id: tweak.id)
    #expect(try repository.tweaks(host: "example.com").first?.isEnabled == false)
    #expect(SiteTweakRepository.css(for: try repository.tweaks(host: "example.com")) == "")

    try repository.update(id: tweak.id, name: "  Renamed  ", css: "p { color: blue }")
    let updated = try #require(try repository.tweaks(host: "example.com").first)
    #expect(updated.name == "Renamed")
    #expect(updated.css == "p { color: blue }")

    try repository.setEnabled(true, id: tweak.id)
    #expect(SiteTweakRepository.css(for: try repository.tweaks(host: "example.com")) == "p { color: blue }")
    try repository.remove(id: tweak.id)
    #expect(try repository.tweaks(host: "example.com").isEmpty)
}

@Test
func enabledTweaksAreJoinedOldestFirst() throws {
    let repository = SiteTweakRepository(database: try AppDatabase.inMemoryProfile())
    _ = try repository.add(host: "example.com", name: "1", css: "a { x: 1 }", now: Date(timeIntervalSince1970: 1))
    let off = try repository.add(host: "example.com", name: "2", css: "b { x: 2 }", now: Date(timeIntervalSince1970: 2))
    _ = try repository.add(host: "example.com", name: "3", css: "c { x: 3 }", now: Date(timeIntervalSince1970: 3))
    try repository.setEnabled(false, id: off.id)
    #expect(SiteTweakRepository.css(for: try repository.tweaks(host: "example.com")) == "a { x: 1 }\nc { x: 3 }")
}

@Test
func theCountPerHostIsBounded() throws {
    let repository = SiteTweakRepository(database: try AppDatabase.inMemoryProfile())
    for index in 0..<SiteTweakRepository.maximumPerHost {
        _ = try repository.add(host: "example.com", name: "t\(index)", css: "p { order: \(index) }")
    }
    #expect(throws: BrowsemiumError.self) {
        try repository.add(host: "example.com", name: "extra", css: "p { order: 99 }")
    }
    // Another site is unaffected.
    _ = try repository.add(host: "other.test", name: "ok", css: "p { order: 1 }")
}
