import Foundation
import Security

/// Stops macOS asking for permission to read WebKit's WebCrypto master key.
///
/// WebKit keeps a keychain item (`<App> WebCrypto Master Key`) that encrypts
/// WebCrypto keys pages store in IndexedDB. macOS checks that item's access
/// control against the app's code signature. A signed app has a stable
/// signature, so the permission sticks — but an ad-hoc signed build gets a new
/// signature on every rebuild, so macOS treats each build as a stranger and
/// asks again, and "Always Allow" cannot help.
///
/// Replacing the item belongs to the user's keychain, and the replacement key
/// makes every WebCrypto key a site already stored in IndexedDB undecryptable,
/// so this is **off by default**. Developers who would rather not see the
/// prompt can opt in for one run:
///
///     BROWSEMIUM_CLAIM_WEBCRYPTO_KEY=1 open -a Browsemium
///
/// Signed builds are never touched, so released apps keep their WebCrypto keys
/// across launches.
public enum WebCryptoKeychainItem {
    public static let accountPrefix = "com.apple.WebKit.WebCrypto.master+"
    public static let optInVariable = "BROWSEMIUM_CLAIM_WEBCRYPTO_KEY"

    /// The service name WebKit uses: the application name plus this suffix.
    public static func serviceName(appName: String) -> String {
        "\(appName) WebCrypto Master Key"
    }

    public static var currentServiceName: String? {
        guard let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
              !name.isEmpty else {
            return nil
        }
        return serviceName(appName: name)
    }

    /// True when the running binary is ad-hoc signed, which is the only case
    /// that needs this workaround.
    public static var isAdHocSigned: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return true }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return true
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let dictionary = information as? [String: Any] else {
            return true
        }
        if let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            return false
        }
        if let flags = dictionary[kSecCodeInfoFlags as String] as? UInt32 {
            // kSecCodeSignatureAdhoc
            return flags & 0x2 != 0
        }
        return true
    }

    /// True when the developer asked for the replacement to happen. The item
    /// is the user's, so this is never automatic.
    public static func isOptedIn(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let value = environment[optInVariable]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    /// Replaces the item so it belongs to this build. Only for ad-hoc builds
    /// that explicitly opted in; signed builds and every default run are
    /// no-ops.
    @discardableResult
    public static func claimForAdHocBuilds() -> Bool {
        guard isOptedIn(),
              isAdHocSigned,
              let service = currentServiceName,
              let bundleID = Bundle.main.bundleIdentifier else {
            return false
        }

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        // Removes an item created by an earlier build, whose access control no
        // longer matches. Deleting does not require the user's keychain
        // password; reading the old item would.
        SecItemDelete(base as CFDictionary)

        // `&key` would hand SecRandomCopyBytes a pointer to the Data *struct*
        // and overwrite its internal buffer pointer, corrupting memory. The
        // bytes have to be filled through withUnsafeMutableBytes.
        var key = Data(count: 16)
        let randomStatus = key.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        guard randomStatus == errSecSuccess else {
            return false
        }

        var attributes = base
        attributes[kSecAttrAccount as String] = accountPrefix + bundleID
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        attributes[kSecValueData as String] = key
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
