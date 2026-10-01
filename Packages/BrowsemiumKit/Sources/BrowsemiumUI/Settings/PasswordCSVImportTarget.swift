import BrowsemiumCore
import BrowsemiumData
import Foundation

/// Capture the user's destination before dismissing the browser preview.
/// Choosing a file/canceling never creates a profile or imports a password.
enum PasswordCSVImportTarget: Sendable {
    case existing(BrowserProfile)
    case newProfile(String)

    init(destination: BrowserImportDestination, currentProfile: BrowserProfile, newProfileName: String) {
        switch destination {
        case .currentProfile: self = .existing(currentProfile)
        case .newProfile:
            let trimmed = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
            self = .newProfile(trimmed.isEmpty ? "Imported passwords" : trimmed)
        }
    }

    var displayName: String {
        switch self {
        case .existing(let profile): profile.name
        case .newProfile(let name): name
        }
    }

    enum ImportError: Error, LocalizedError {
        case destinationUnavailable
        var errorDescription: String? { "The destination profile is unavailable. Choose a profile and try the CSV import again." }
    }

    @MainActor
    func importCredentials(_ credentials: [ChromeLogin], using model: BrowserWindowModel) throws -> Int {
        guard !credentials.isEmpty else { return 0 }
        let profile: BrowserProfile
        switch self {
        case .existing(let selected):
            guard let current = try model.environment.profileStore.profiles().first(where: { $0.id == selected.id }) else {
                throw ImportError.destinationUnavailable
            }
            profile = current
        case .newProfile(let name):
            guard let created = model.createProfile(named: name) else { throw ImportError.destinationUnavailable }
            profile = created
        }
        return credentials.reduce(0) { count, credential in
            let saved = model.saveCredential(host: credential.url.host ?? credential.url.absoluteString,
                                             username: credential.username, password: credential.password, profile: profile)
            return count + (saved ? 1 : 0)
        }
    }
}
