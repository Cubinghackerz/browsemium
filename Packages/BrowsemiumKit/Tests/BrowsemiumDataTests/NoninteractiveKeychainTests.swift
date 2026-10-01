@testable import BrowsemiumData
import Foundation
import LocalAuthentication
import Security
import Testing

private final class NoninteractiveKeychainFixture: KeychainAPI, @unchecked Sendable {
    private(set) var interactiveReads = 0
    private(set) var accounts: [String?] = []
    var statuses: [OSStatus]

    init(statuses: [OSStatus]) { self.statuses = statuses }
    func store(service: String, account: String, data: Data) -> OSStatus { errSecSuccess }
    func delete(service: String, account: String) -> OSStatus { errSecSuccess }
    func exists(service: String, account: String) -> Bool { false }
    func read(service: String, account: String) -> (status: OSStatus, data: Data?) {
        interactiveReads += 1
        return (errSecSuccess, Data("fixture-only".utf8))
    }
    func readWithoutInteraction(service: String, account: String?) -> (status: OSStatus, data: Data?) {
        accounts.append(account)
        let status = statuses.isEmpty ? errSecItemNotFound : statuses.removeFirst()
        return (status, status == errSecSuccess ? Data("fixture-only".utf8) : nil)
    }
}

private final class LegacyKeychainFixture: KeychainAPI, @unchecked Sendable {
    private(set) var interactiveReads = 0
    func store(service: String, account: String, data: Data) -> OSStatus { errSecSuccess }
    func delete(service: String, account: String) -> OSStatus { errSecSuccess }
    func exists(service: String, account: String) -> Bool { false }
    func read(service: String, account: String) -> (status: OSStatus, data: Data?) {
        interactiveReads += 1
        return (errSecSuccess, Data("fixture-only".utf8))
    }
}

@Suite
struct NoninteractiveKeychainTests {
    @Test(arguments: [Optional(""), nil])
    func systemQueryDisallowsBothAuthenticationPaths(account: String?) throws {
        let query = NoninteractiveKeychainQuery.make(service: "fixture-browser", account: account)
        let context = try #require(query[kSecUseAuthenticationContext as String] as? LAContext)
        #expect(context.interactionNotAllowed)
        #expect((query[kSecUseAuthenticationUI as String] as? String) == (kSecUseAuthenticationUIFail as String))
        #expect((query[kSecAttrAccount as String] as? String) == account)
        #expect((query[kSecAttrService as String] as? String) == "fixture-browser")
        #expect((query[kSecReturnData as String] as? Bool) == true)
        #expect(query[kSecUseDataProtectionKeychain as String] == nil)
    }

    @Test
    func aBackendWithoutNoninteractiveSupportFailsClosed() {
        let backend = LegacyKeychainFixture()
        #expect(throws: KeychainStore.KeychainError.self) {
            _ = try KeychainStore(api: backend).secretWithoutInteraction(service: "fixture-browser")
        }
        #expect(backend.interactiveReads == 0)
    }

    @Test
    func accountlessFallbackUsesOnlyNoninteractiveReads() throws {
        let backend = NoninteractiveKeychainFixture(statuses: [errSecItemNotFound, errSecSuccess])
        let secret = try KeychainStore(api: backend).secretWithoutInteraction(service: "fixture-browser")
        #expect(secret == "fixture-only")
        #expect(backend.accounts == ["", nil])
        #expect(backend.interactiveReads == 0)
    }

    @Test(arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled])
    func denialNeverRetriesWithAnAccountlessOrInteractiveQuery(status: OSStatus) {
        let backend = NoninteractiveKeychainFixture(statuses: [status, errSecSuccess])
        #expect(throws: KeychainStore.KeychainError.self) {
            _ = try KeychainStore(api: backend).secretWithoutInteraction(service: "fixture-browser")
        }
        #expect(backend.accounts == [""])
        #expect(backend.interactiveReads == 0)
    }
}
