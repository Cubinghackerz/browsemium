import BrowsemiumCore
import BrowsemiumData
@testable import BrowsemiumUI
import Foundation
import Testing

@Suite @MainActor
struct BatchImportProfileTests {
    private func candidate(_ source: BrowserImportSource = .chrome, folder: String = "Profile 1", name: String = "Work") -> BrowserProfileCandidate {
        BrowserProfileCandidate(
            source: source, label: "\(source.displayName) — \(name)",
            folder: URL(fileURLWithPath: "/fixture/\(folder)"), isReadable: true, profileName: name
        )
    }

    private func makeModel() -> BrowserWindowModel {
        BrowserWindowModel(environment: .inMemory(engine: StubEngine()))
    }

    @Test
    func theFirstBatchImportCreatesAProfileWithoutSwitchingToIt() throws {
        let model = makeModel()
        let active = model.activeProfile
        let before = model.profiles.count

        let destination = try #require(model.profileForImport(of: candidate()))

        #expect(!destination.reused)
        #expect(destination.profile.name == "Work")
        #expect(model.profiles.count == before + 1)
        #expect(model.activeProfile.id == active.id, "A batch import never changes the active profile")
    }

    @Test
    func importingTheSameSourceAgainReusesTheLinkedProfile() throws {
        let model = makeModel()
        let first = try #require(model.profileForImport(of: candidate()))
        let count = model.profiles.count

        let second = try #require(model.profileForImport(of: candidate()))

        #expect(second.reused)
        #expect(second.profile.id == first.profile.id)
        #expect(model.profiles.count == count, "A re-run creates no profile")
    }

    @Test
    func differentSourceProfilesAndBrowsersGetTheirOwnProfiles() throws {
        let model = makeModel()
        let a = try #require(model.profileForImport(of: candidate(folder: "Profile 1")))
        let b = try #require(model.profileForImport(of: candidate(folder: "Profile 2", name: "Home")))
        let c = try #require(model.profileForImport(of: candidate(.brave, folder: "Profile 1")))
        #expect(Set([a.profile.id, b.profile.id, c.profile.id]).count == 3)
    }

    @Test
    func aDeletedLinkedProfileIsCreatedAgain() async throws {
        let model = makeModel()
        let first = try #require(model.profileForImport(of: candidate()))
        await model.deleteProfile(first.profile)

        let again = try #require(model.profileForImport(of: candidate()))

        #expect(!again.reused)
        #expect(again.profile.id != first.profile.id)
    }
}
