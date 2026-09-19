import CommonCrypto
import Foundation

/// Chrome's macOS password encryption.
///
/// Passwords in `Login Data` are AES-128-CBC blobs prefixed with `v10`. The key
/// is PBKDF2-HMAC-SHA1 over the secret stored in the login keychain as
/// "Chrome Safe Storage", with the fixed salt `saltysalt` and 1003 iterations.
/// Reading that keychain item is what macOS asks the user to authorise; without
/// it the blobs cannot be decrypted by anyone, including us.
public enum ChromeCredentialCrypto {
    public static let salt = Data("saltysalt".utf8)
    public static let iterations = 1003
    public static let keyLength = 16
    static let prefix = Data("v10".utf8)

    public enum CryptoError: Error, LocalizedError {
        case unsupportedPrefix
        case derivationFailed
        case decryptionFailed

        public var errorDescription: String? {
            switch self {
            case .unsupportedPrefix:
                "This password uses an encryption scheme Browsemium cannot read."
            case .derivationFailed:
                "The encryption key could not be derived."
            case .decryptionFailed:
                "The stored password could not be decrypted."
            }
        }
    }

    public static func derivedKey(safeStoragePassword: String) throws -> Data {
        let password = Data(safeStoragePassword.utf8)
        var key = Data(count: keyLength)
        let status = key.withUnsafeMutableBytes { keyBuffer -> Int32 in
            password.withUnsafeBytes { passwordBuffer -> Int32 in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBuffer.baseAddress?.assumingMemoryBound(to: Int8.self),
                    password.count,
                    [UInt8](salt),
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    UInt32(iterations),
                    keyBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    keyLength
                )
            }
        }
        guard status == kCCSuccess else { throw CryptoError.derivationFailed }
        return key
    }

    public static func decrypt(_ blob: Data, key: Data) throws -> String {
        guard blob.count > prefix.count, blob.prefix(prefix.count) == prefix else {
            throw CryptoError.unsupportedPrefix
        }
        let ciphertext = blob.dropFirst(prefix.count)
        guard !ciphertext.isEmpty else { return "" }
        // Chrome uses a fixed IV of sixteen spaces.
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)

        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBuffer -> CCCryptorStatus in
            ciphertext.withUnsafeBytes { ciphertextBuffer -> CCCryptorStatus in
                key.withUnsafeBytes { keyBuffer -> CCCryptorStatus in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBuffer.baseAddress,
                        key.count,
                        iv,
                        ciphertextBuffer.baseAddress,
                        ciphertext.count,
                        outputBuffer.baseAddress,
                        outputBuffer.count,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.decryptionFailed }
        output.removeSubrange(moved..<output.count)
        guard let value = String(data: output, encoding: .utf8) else {
            throw CryptoError.decryptionFailed
        }
        return value
    }

    /// Used by tests to build fixtures that match Chrome's format exactly.
    public static func encryptForTesting(_ plaintext: String, key: Data) throws -> Data {
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        let input = Data(plaintext.utf8)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBuffer -> CCCryptorStatus in
            input.withUnsafeBytes { inputBuffer -> CCCryptorStatus in
                key.withUnsafeBytes { keyBuffer -> CCCryptorStatus in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBuffer.baseAddress,
                        key.count,
                        iv,
                        inputBuffer.baseAddress,
                        input.count,
                        outputBuffer.baseAddress,
                        outputBuffer.count,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.decryptionFailed }
        output.removeSubrange(moved..<output.count)
        return prefix + output
    }
}
