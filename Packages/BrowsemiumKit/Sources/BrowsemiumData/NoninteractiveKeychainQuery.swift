import Foundation
import LocalAuthentication
import Security

/// The source browser owns these keys. Do not authorize, unlock, modify ACLs,
/// or retry interactively on its behalf. The CSV route is the recovery path.
enum NoninteractiveKeychainQuery {
    static func make(service: String, account: String?) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
            // Keep the explicit legacy-keychain fail policy as well as LAContext.
            // Chromium source keys may live in the file-based login keychain.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }
}
