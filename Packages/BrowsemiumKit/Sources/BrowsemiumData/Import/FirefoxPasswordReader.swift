import CommonCrypto
import CommonCrypto
import Foundation
import GRDB

/// Reads saved logins out of a Firefox profile's `logins.json` + `key4.db`.
///
/// Layout reference: Mozilla Support KB "Use a Primary Password to protect
/// stored logins and passwords" (`logins.json` holds the encrypted fields,
/// `key4.db` holds the key, NSS is the provider, a Primary Password encrypts
/// the key) and the NSS PBE OIDs; DER shapes follow the long-stable
/// de-facto layout (`metadata` password-check row, `nssPrivate` bulk key,
/// per-field `SEQUENCE { keyID, algorithm, ciphertext }` blobs).
///
/// Two unwrapping mechanisms are supported, both with CommonCrypto and no
/// home-grown primitives:
/// - PBE with SHA-1 and Triple-DES-CBC (OID 1.2.840.113549.1.12.5.1.3),
///   keyed by the NSS `SHA1(globalSalt || password || entrySalt)` chain.
/// - PBES2 with PBKDF2-HMAC-SHA256 and AES-256-CBC
///   (OIDs 1.2.840.113549.1.5.13 / .1.5.12 / 2.16.840.1.101.3.4.1.42).
/// Anything else — including `key3.db` Berkeley-DB profiles and unknown blob
/// shapes — is classified `unsupported`, never guessed at.
///
/// Primary-password detection uses NSS's own password-check item verified
/// with the empty password (the defined unprotected path — trying it is not
/// guessing a password). A check mismatch means protected. Generic
/// decryption failures are `corrupt`/per-item `failed`, never "protected".
///
/// Fixtures are generated to the documented layout; byte compatibility with
/// real Firefox output is verified only to that extent. Reports carry
/// ordinals only — no hosts, usernames, or secrets.
public enum FirefoxPasswordReader {
    /// Boundaries before any allocation or KDF work.
    public static let maxLoginsJSONBytes = 32 * 1024 * 1024
    public static let maxLogins = 50_000
    public static let maxFieldBlobBytes = 1024 * 1024
    public static let maxMetadataBlobBytes = 64 * 1024
    public static let maxPBKDF2Iterations = 1_000_000

    static let passwordCheck = Data("password-check\u{02}\u{02}".utf8)
    static let bulkKeyID = Data([0xF8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                                 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])
    static let oidPBE3DES = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x05, 0x01, 0x03])
    static let oidPBES2 = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0D])
    static let oidPBKDF2 = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0C])
    static let oidHmacSHA256 = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x09])
    static let oidAES256CBC = Data([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2A])
    static let oidDES3CBC = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x03, 0x07])

    public enum ProfileStatus: Sendable, Equatable {
        /// No logins file, or an empty login list: nothing to do.
        case empty
        case ready
        case primaryPasswordProtected
        case unsupported
        case corrupt
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case unreadable(String)
        case corrupt(String)
        case unsupported(String)
        case primaryPasswordProtected

        public var errorDescription: String? {
            switch self {
            case .unreadable(let detail):
                "Firefox passwords could not be read: \(detail)"
            case .corrupt(let detail):
                "Firefox password data is damaged: \(detail)"
            case .unsupported(let detail):
                "Firefox passwords use a format Browsemium cannot read: \(detail)"
            case .primaryPasswordProtected:
                "Firefox protects these logins with a Primary Password, which Browsemium never asks for."
            }
        }
    }

    // MARK: - Minimal DER reader

    enum ASN1: Equatable {
        case sequence([ASN1])
        case octetString(Data)
        case objectIdentifier(Data)
        case integer(Data)
    }

    static func parseDER(_ data: Data) throws -> ASN1 {
        let (item, consumed) = try parseOne(data, index: data.startIndex)
        guard consumed == data.count else { throw Failure.corrupt("trailing bytes after DER value") }
        return item
    }

    private static func parseOne(_ data: Data, index: Data.Index) throws -> (ASN1, Int) {
        guard index < data.endIndex else { throw Failure.corrupt("truncated DER") }
        let tag = data[index]
        var cursor = data.index(after: index)
        guard cursor < data.endIndex else { throw Failure.corrupt("truncated DER length") }
        let firstLength = data[cursor]
        cursor = data.index(after: cursor)
        let length: Int
        if firstLength & 0x80 == 0 {
            length = Int(firstLength)
        } else {
            let count = Int(firstLength & 0x7F)
            guard count >= 1, count <= 4 else { throw Failure.corrupt("unsupported DER length form") }
            var value = 0
            for _ in 0..<count {
                guard cursor < data.endIndex else { throw Failure.corrupt("truncated DER length") }
                value = (value << 8) | Int(data[cursor])
                cursor = data.index(after: cursor)
            }
            length = value
        }
        guard length >= 0, data.distance(from: cursor, to: data.endIndex) >= length else {
            throw Failure.corrupt("DER length overruns input")
        }
        let end = data.index(cursor, offsetBy: length)
        let content = data[cursor..<end]
        switch tag {
        case 0x30:
            var children: [ASN1] = []
            var childIndex = content.startIndex
            while childIndex < content.endIndex {
                let (child, consumed) = try parseOne(content, index: childIndex)
                children.append(child)
                childIndex = content.index(childIndex, offsetBy: consumed)
            }
            return (.sequence(children), data.distance(from: index, to: end))
        case 0x04:
            return (.octetString(Data(content)), data.distance(from: index, to: end))
        case 0x06:
            return (.objectIdentifier(Data(content)), data.distance(from: index, to: end))
        case 0x02:
            return (.integer(Data(content)), data.distance(from: index, to: end))
        default:
            // Not DER at all: damage, not a version statement. (A genuinely
            // newer NSS format would still parse as DER and fail later at its
            // unknown OID, which stays `unsupported`.)
            throw Failure.corrupt("unrecognized DER tag")
        }
    }

    static func integerValue(_ raw: Data) throws -> Int {
        var bytes = raw
        while bytes.count > 1, bytes.first == 0x00 { bytes = bytes.dropFirst() }
        guard bytes.count <= 4 else { throw Failure.corrupt("DER integer too large") }
        return bytes.reduce(0) { ($0 << 8) | Int($1) }
    }

    // MARK: - NSS unwrapping (empty password: the defined unprotected path)

    /// Unwraps a PBE blob (password-check `item2` or `nssPrivate` entry) with
    /// the empty password. Unknown mechanisms throw `unsupported`, so callers
    /// can distinguish "newer format" from damage.
    static func unwrap(_ blob: ASN1, globalSalt: Data) throws -> Data {
        guard case .sequence(let outer) = blob, outer.count == 2,
              case .sequence(let algo) = outer[0], algo.count == 2,
              case .objectIdentifier(let oid) = algo[0],
              case .octetString(let ciphertext) = outer[1] else {
            throw Failure.corrupt("PBE blob has an unexpected shape")
        }
        if oid == oidPBE3DES {
            guard case .sequence(let params) = algo[1], params.count == 2,
                  case .octetString(let entrySalt) = params[0] else {
                throw Failure.corrupt("3DES PBE parameters have an unexpected shape")
            }
            return try moz3DESDecrypt(ciphertext: ciphertext, globalSalt: globalSalt,
                                      password: Data(), entrySalt: entrySalt)
        }
        if oid == oidPBES2 {
            return try pbes2Decrypt(ciphertext: ciphertext, params: algo[1],
                                    globalSalt: globalSalt, password: Data())
        }
        throw Failure.unsupported("unknown password-wrapping algorithm")
    }

    /// The NSS Triple-DES key derivation: HMAC-SHA1 chain over
    /// `SHA1(globalSalt || password || entrySalt)`.
    static func moz3DESKeyIV(globalSalt: Data, password: Data, entrySalt: Data) -> (key: Data, iv: Data) {
        let passwordHash = sha1(globalSalt + password)
        let paddedEntry = entrySalt.prefix(20) + Data(repeating: 0, count: max(0, 20 - entrySalt.count))
        let entryHash = sha1(passwordHash + entrySalt)
        let k1 = hmacSHA1(key: entryHash, message: paddedEntry + entrySalt)
        let tk = hmacSHA1(key: entryHash, message: paddedEntry)
        let k2 = hmacSHA1(key: entryHash, message: tk + entrySalt)
        let combined = k1 + k2
        return (Data(combined.prefix(24)), Data(combined.suffix(8)))
    }

    static func moz3DESDecrypt(ciphertext: Data, globalSalt: Data, password: Data, entrySalt: Data) throws -> Data {
        guard !ciphertext.isEmpty, ciphertext.count % 8 == 0 else {
            throw Failure.corrupt("3DES ciphertext length is not a whole number of blocks")
        }
        let (key, iv) = moz3DESKeyIV(globalSalt: globalSalt, password: password, entrySalt: entrySalt)
        return try des3CBC(ciphertext, key: key, iv: iv, decrypt: true, padding: false)
    }

    static func pbes2Decrypt(ciphertext: Data, params: ASN1, globalSalt: Data, password: Data) throws -> Data {
        guard case .sequence(let pair) = params, pair.count == 2,
              case .sequence(let kdf) = pair[0], kdf.count == 2,
              case .objectIdentifier(let kdfOID) = kdf[0], kdfOID == oidPBKDF2,
              case .sequence(let kdfParams) = kdf[1], kdfParams.count == 4,
              case .octetString(let entrySalt) = kdfParams[0],
              case .integer(let iterationsRaw) = kdfParams[1],
              case .integer(let keyLengthRaw) = kdfParams[2],
              case .sequence(let prf) = kdfParams[3], prf.count == 1,
              case .objectIdentifier(let prfOID) = prf[0], prfOID == oidHmacSHA256,
              case .sequence(let enc) = pair[1], enc.count == 2,
              case .objectIdentifier(let encOID) = enc[0], encOID == oidAES256CBC,
              case .octetString(let ivSuffix) = enc[1] else {
            throw Failure.corrupt("PBES2 parameters have an unexpected shape")
        }
        let iterations = try integerValue(iterationsRaw)
        let keyLength = try integerValue(keyLengthRaw)
        guard keyLength == 32 else { throw Failure.unsupported("unexpected PBES2 key length") }
        guard iterations >= 1, iterations <= maxPBKDF2Iterations else {
            throw Failure.unsupported("PBKDF2 iteration count out of range")
        }
        // Stored IV carries its own DER tag+length prefix.
        let iv = Data([0x04, 0x0E]) + ivSuffix
        guard iv.count == 16 else { throw Failure.corrupt("AES IV has an unexpected length") }
        guard !ciphertext.isEmpty, ciphertext.count % 16 == 0 else {
            throw Failure.corrupt("AES ciphertext length is not a whole number of blocks")
        }
        let stretched = sha1(globalSalt + password)
        let key = try pbkdf2SHA256(password: stretched, salt: entrySalt,
                                   iterations: iterations, keyLength: keyLength)
        return try aesCBC(ciphertext, key: key, iv: iv, decrypt: true, padding: false)
    }

    // MARK: - Platform crypto (CommonCrypto only)

    static func sha1(_ data: Data) -> Data {
        var digest = Data(count: Int(CC_SHA1_DIGEST_LENGTH))
        _ = digest.withUnsafeMutableBytes { digestBuffer in
            data.withUnsafeBytes { dataBuffer in
                CC_SHA1(dataBuffer.baseAddress, CC_LONG(data.count),
                        digestBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self))
            }
        }
        return digest
    }

    static func hmacSHA1(key: Data, message: Data) -> Data {
        var mac = Data(count: Int(CC_SHA1_DIGEST_LENGTH))
        mac.withUnsafeMutableBytes { macBuffer in
            key.withUnsafeBytes { keyBuffer in
                message.withUnsafeBytes { messageBuffer in
                    CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1),
                           keyBuffer.baseAddress, key.count,
                           messageBuffer.baseAddress, message.count,
                           macBuffer.baseAddress)
                }
            }
        }
        return mac
    }

    static func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, keyLength: Int) throws -> Data {
        var key = Data(count: keyLength)
        let status = key.withUnsafeMutableBytes { keyBuffer in
            password.withUnsafeBytes { passwordBuffer in
                salt.withUnsafeBytes { saltBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        keyBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.corrupt("key derivation failed") }
        return key
    }

    static func blockCrypt(_ input: Data, algorithm: CCAlgorithm, key: Data, iv: Data,
                           decrypt: Bool, padding: Bool) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBuffer in
            input.withUnsafeBytes { inputBuffer in
                key.withUnsafeBytes { keyBuffer in
                    iv.withUnsafeBytes { ivBuffer in
                        CCCrypt(decrypt ? CCOperation(kCCDecrypt) : CCOperation(kCCEncrypt),
                                algorithm,
                                padding ? CCOptions(kCCOptionPKCS7Padding) : 0,
                                keyBuffer.baseAddress, key.count,
                                ivBuffer.baseAddress,
                                inputBuffer.baseAddress, input.count,
                                outputBuffer.baseAddress, capacity,
                                &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.corrupt("block cipher operation failed") }
        output.removeSubrange(moved..<output.count)
        return output
    }

    static func des3CBC(_ input: Data, key: Data, iv: Data, decrypt: Bool, padding: Bool) throws -> Data {
        guard key.count == 24, iv.count == 8 else { throw Failure.corrupt("3DES key or IV length wrong") }
        return try blockCrypt(input, algorithm: CCAlgorithm(kCCAlgorithm3DES),
                              key: key, iv: iv, decrypt: decrypt, padding: padding)
    }

    static func aesCBC(_ input: Data, key: Data, iv: Data, decrypt: Bool, padding: Bool) throws -> Data {
        guard key.count == 32, iv.count == 16 else { throw Failure.corrupt("AES key or IV length wrong") }
        return try blockCrypt(input, algorithm: CCAlgorithm(kCCAlgorithmAES),
                              key: key, iv: iv, decrypt: decrypt, padding: padding)
    }

    // MARK: - Profile reading

    public struct LoginField: Sendable {
        public let hostname: String
        public let encryptedUsername: String
        public let encryptedPassword: String
    }

    /// Hostnames and field blobs from `logins.json`, without decrypting.
    /// Presence only — no secret is touched, so previews never need a key.
    public static func summarize(loginsJSON: Data) throws -> [LoginField] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: loginsJSON, options: [])
        } catch {
            throw Failure.corrupt("logins.json is not valid JSON")
        }
        guard let top = root as? [String: Any],
              let logins = top["logins"] as? [Any] else {
            throw Failure.corrupt("logins.json has no login list")
        }
        guard logins.count <= maxLogins else { throw Failure.unsupported("login list exceeds the reader limit") }
        var fields: [LoginField] = []
        for entry in logins {
            guard let login = entry as? [String: Any],
                  let hostname = login["hostname"] as? String, !hostname.isEmpty,
                  let username = login["encryptedUsername"] as? String,
                  let password = login["encryptedPassword"] as? String else { continue }
            fields.append(LoginField(hostname: hostname, encryptedUsername: username, encryptedPassword: password))
        }
        return fields
    }

    /// The bulk login key from an open `key4.db`, verified unprotected with
    /// the empty password. Throws `primaryPasswordProtected` on a check
    /// mismatch, `unsupported` for unknown mechanisms or legacy databases.
    public static func bulkKey(database: Database) throws -> Data {
        let hasMetadata = (try? Bool.fetchOne(database, sql: "SELECT COUNT(*) > 0 FROM sqlite_master WHERE name = 'metadata'")) ?? false
        guard hasMetadata,
              let row = try Row.fetchOne(database, sql: "SELECT item1, item2 FROM metadata WHERE id = 'password'"),
              let globalSalt = row["item1"] as Data?,
              let item2 = row["item2"] as Data?,
              item2.count <= maxMetadataBlobBytes else {
            throw Failure.corrupt("key4.db has no password metadata")
        }
        let checkBlob = try parseDER(item2)
        let checkPlaintext: Data
        do {
            checkPlaintext = try unwrap(checkBlob, globalSalt: globalSalt)
        } catch let failure as Failure {
            // An unknown mechanism is a version statement, not damage.
            throw failure
        }
        guard checkPlaintext == passwordCheck else {
            throw Failure.primaryPasswordProtected
        }
        guard let keyRow = try Row.fetchOne(database,
            sql: "SELECT a11, a102 FROM nssPrivate WHERE a102 = ?",
            arguments: [bulkKeyID]) else {
            throw Failure.corrupt("key4.db has no login key")
        }
        guard let wrapped = keyRow["a11"] as Data?,
              wrapped.count <= maxMetadataBlobBytes else {
            throw Failure.corrupt("key4.db login key entry is malformed")
        }
        let raw = try unwrap(parseDER(wrapped), globalSalt: globalSalt)
        // 32 bytes feeds Triple-DES (first 24), 48 feeds AES-256 (first 32).
        guard raw.count == 32 || raw.count == 48 else {
            throw Failure.corrupt("unwrapped login key has an unexpected length")
        }
        return raw
    }

    struct DecodedField {
        let keyID: Data
        let iv: Data
        let ciphertext: Data
    }

    static func decodeField(_ base64: String) throws -> DecodedField {
        guard base64.count <= maxFieldBlobBytes,
              let raw = Data(base64Encoded: base64, options: []) else {
            throw Failure.corrupt("login field is not valid base64")
        }
        guard case .sequence(let outer) = try parseDER(raw), outer.count == 3,
              case .octetString(let keyID) = outer[0],
              case .sequence(let algo) = outer[1], algo.count == 2,
              case .objectIdentifier(let oid) = algo[0],
              (oid == oidDES3CBC || oid == oidAES256CBC),
              case .octetString(let iv) = algo[1],
              case .octetString(let ciphertext) = outer[2],
              !ciphertext.isEmpty, ciphertext.count <= maxFieldBlobBytes else {
            throw Failure.unsupported("login field has an unexpected shape")
        }
        return DecodedField(keyID: keyID, iv: iv, ciphertext: ciphertext)
    }

    /// Decrypts one base64 field with the unwrapped bulk key. The cipher
    /// follows the key length (24 → Triple-DES, 32 → AES-256), matching how
    /// the wrapping era and the field era move together.
    public static func decryptField(_ base64: String, bulkKey: Data) throws -> String {
        let field = try decodeField(base64)
        guard field.keyID == bulkKeyID else {
            throw Failure.unsupported("login field names an unknown key")
        }
        let plaintext: Data
        if bulkKey.count == 32 {
            guard field.iv.count == 8 else { throw Failure.corrupt("3DES field IV length wrong") }
            plaintext = try des3CBC(field.ciphertext, key: Data(bulkKey.prefix(24)),
                                    iv: field.iv, decrypt: true, padding: true)
        } else if bulkKey.count == 48 {
            guard field.iv.count == 16 else { throw Failure.corrupt("AES field IV length wrong") }
            plaintext = try aesCBC(field.ciphertext, key: Data(bulkKey.prefix(32)),
                                    iv: field.iv, decrypt: true, padding: true)
        } else {
            throw Failure.corrupt("bulk key has an unexpected length")
        }
        guard let value = String(data: plaintext, encoding: .utf8) else {
            throw Failure.corrupt("decrypted field is not text")
        }
        return value
    }

    // MARK: - Importer entry points

    /// Counts saved logins without decrypting. `nil` when the profile keeps
    /// no `logins.json` at all.
    public static func summarizeProfile(in profile: URL, report: inout BrowserImportReport) -> [(url: URL, username: String)]? {        let url = profile.appendingPathComponent("logins.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let fields: [LoginField]
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if (attributes[.size] as? Int ?? 0) > maxLoginsJSONBytes {
                report.record(.password, ordinal: 0, outcome: .unsupported, reason: .limitExceeded)
                return []
            }
            fields = try summarize(loginsJSON: try Data(contentsOf: url))
        } catch let failure as Failure {
            // `summarize` throws `unsupported` only for the over-limit list;
            // anything else is unreadable here.
            if failure == .unsupported("login list exceeds the reader limit") {
                report.record(.password, ordinal: 0, outcome: .unsupported, reason: .limitExceeded)
            } else {
                report.record(.password, ordinal: 0, outcome: .failed, reason: .sourceUnreadable)
            }
            return []
        } catch {
            report.record(.password, ordinal: 0, outcome: .failed, reason: .sourceUnreadable)
            return []
        }
        return fields.enumerated().compactMap { index, field in
            guard let parsed = URL(string: field.hostname),
                  let scheme = parsed.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  parsed.host?.isEmpty == false else {
                report.record(.password, ordinal: index + 1, outcome: .unsupported, reason: .unsupportedURL)
                return nil
            }
            report.record(.password, ordinal: index + 1, outcome: .accepted, reason: .parsed)
            // Usernames stay encrypted until a confirmed import decrypts them.
            return (parsed, "")
        }
    }

    /// Decrypts every login after explicit confirmation. One bad entry never
    /// aborts the rest; whole-profile states (protected/unsupported/corrupt
    /// key database) yield no logins and a single ordinal-0 record.
    public static func decryptLogins(database: Database, loginsJSON: Data, report: inout BrowserImportReport) -> [ChromeLogin] {
        let bulk: Data
        do {
            bulk = try bulkKey(database: database)
        } catch let failure as Failure {
            switch failure {
            case .primaryPasswordProtected:
                report.record(.password, ordinal: 0, outcome: .unsupported, reason: .primaryPasswordRequired)
            case .unsupported:
                report.record(.password, ordinal: 0, outcome: .unsupported, reason: .unsupportedFormat)
            case .corrupt, .unreadable:
                report.record(.password, ordinal: 0, outcome: .failed, reason: .sourceUnreadable)
            }
            return []
        } catch {
            report.record(.password, ordinal: 0, outcome: .failed, reason: .sourceUnreadable)
            return []
        }
        let fields: [LoginField]
        do {
            fields = try summarize(loginsJSON: loginsJSON)
        } catch {
            report.record(.password, ordinal: 0, outcome: .failed, reason: .sourceUnreadable)
            return []
        }
        var logins: [ChromeLogin] = []
        var seen = Set<String>()
        for (index, field) in fields.enumerated() {
            guard let url = URL(string: field.hostname),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  url.host?.isEmpty == false else {
                report.record(.password, ordinal: index + 1, stage: .transfer,
                              outcome: .unsupported, reason: .unsupportedURL)
                continue
            }
            let username: String
            let password: String
            do {
                username = try decryptField(field.encryptedUsername, bulkKey: bulk)
                password = try decryptField(field.encryptedPassword, bulkKey: bulk)
            } catch let failure as Failure {
                switch failure {
                case .unsupported:
                    report.record(.password, ordinal: index + 1, stage: .transfer,
                                  outcome: .unsupported, reason: .unsupportedFormat)
                case .corrupt, .unreadable, .primaryPasswordProtected:
                    report.record(.password, ordinal: index + 1, stage: .transfer,
                                  outcome: .failed, reason: .decryptionFailed)
                }
                continue
            } catch {
                report.record(.password, ordinal: index + 1, stage: .transfer,
                              outcome: .failed, reason: .decryptionFailed)
                continue
            }
            guard !password.isEmpty else {
                report.record(.password, ordinal: index + 1, stage: .transfer,
                              outcome: .unsupported, reason: .invalidItem)
                continue
            }
            guard seen.insert("\(url.absoluteString)\u{0}\(username)").inserted else {
                report.record(.password, ordinal: index + 1, stage: .transfer,
                              outcome: .duplicate, reason: .duplicateInSource)
                continue
            }
            report.record(.password, ordinal: index + 1, stage: .transfer,
                          outcome: .accepted, reason: .preparedForTransfer)
            logins.append(ChromeLogin(url: url, username: username, password: password))
        }
        return logins
    }

    // MARK: - Fixture generation (tests only)

    /// Builds fixtures in the documented layout. Mirrors the decrypt side in
    /// reverse with the same primitives; never ships in import behavior.
    public enum FixtureSupport {
        public static func derLength(_ count: Int) -> Data {
            if count < 128 { return Data([UInt8(count)]) }
            var value = count
            var bytes: [UInt8] = []
            while value > 0 {
                bytes.insert(UInt8(value & 0xFF), at: 0)
                value >>= 8
            }
            return Data([UInt8(0x80 | bytes.count)] + bytes)
        }

        public static func derTlv(tag: UInt8, content: Data) -> Data {
            Data([tag]) + derLength(content.count) + content
        }

        public static func derSequence(_ parts: [Data]) -> Data {
            derTlv(tag: 0x30, content: parts.reduce(Data(), +))
        }

        public static func derOctetString(_ data: Data) -> Data {
            derTlv(tag: 0x04, content: data)
        }

        public static func derOID(_ bytes: [UInt8]) -> Data {
            derTlv(tag: 0x06, content: Data(bytes))
        }

        public static func derInteger(_ value: Int) -> Data {
            var content = Data()
            var remaining = value
            repeat {
                content.insert(UInt8(remaining & 0xFF), at: 0)
                remaining >>= 8
            } while remaining > 0
            if content.first! & 0x80 != 0 { content.insert(0x00, at: 0) }
            return derTlv(tag: 0x02, content: content)
        }

        /// A password-check/`nssPrivate`-shaped PBE blob wrapping `plaintext`
        /// with the classic 3DES mechanism.
        public static func pbe3DESWrap(plaintext: Data, globalSalt: Data, password: Data, entrySalt: Data) throws -> Data {
            let (key, iv) = FirefoxPasswordReader.moz3DESKeyIV(
                globalSalt: globalSalt, password: password, entrySalt: entrySalt)
            let ciphertext = try FirefoxPasswordReader.des3CBC(
                plaintext, key: key, iv: iv, decrypt: false, padding: false)
            let params = derSequence([derOctetString(entrySalt), derInteger(1)])
            return derSequence([
                derSequence([derOID(Array(FirefoxPasswordReader.oidPBE3DES)), params]),
                derOctetString(ciphertext)
            ])
        }

        /// The same, with the PBES2/AES-256 mechanism.
        public static func pbes2Wrap(plaintext: Data, globalSalt: Data, password: Data,
                                     entrySalt: Data, iterations: Int, ivSuffix: Data) throws -> Data {
            let stretched = FirefoxPasswordReader.sha1(globalSalt + password)
            let key = try FirefoxPasswordReader.pbkdf2SHA256(
                password: stretched, salt: entrySalt, iterations: iterations, keyLength: 32)
            let iv = Data([0x04, 0x0E]) + ivSuffix
            let ciphertext = try FirefoxPasswordReader.aesCBC(
                plaintext, key: key, iv: iv, decrypt: false, padding: false)
            let kdf = derSequence([
                derOID(Array(FirefoxPasswordReader.oidPBKDF2)),
                derSequence([
                    derOctetString(entrySalt),
                    derInteger(iterations),
                    derInteger(32),
                    derSequence([derOID(Array(FirefoxPasswordReader.oidHmacSHA256))])
                ])
            ])
            let enc = derSequence([
                derOID(Array(FirefoxPasswordReader.oidAES256CBC)),
                derOctetString(ivSuffix)
            ])
            return derSequence([
                derSequence([derOID(Array(FirefoxPasswordReader.oidPBES2)), derSequence([kdf, enc])]),
                derOctetString(ciphertext)
            ])
        }

        /// A per-field login blob. The cipher follows the bulk key length,
        /// exactly like the decrypt side.
        public static func loginField(plaintext: String, bulkKey: Data, iv: Data) throws -> String {
            let input = Data(plaintext.utf8)
            let ciphertext: Data
            let oid: Data
            if bulkKey.count == 32 {
                ciphertext = try FirefoxPasswordReader.des3CBC(
                    input, key: Data(bulkKey.prefix(24)), iv: iv, decrypt: false, padding: true)
                oid = FirefoxPasswordReader.oidDES3CBC
            } else {
                ciphertext = try FirefoxPasswordReader.aesCBC(
                    input, key: Data(bulkKey.prefix(32)), iv: iv, decrypt: false, padding: true)
                oid = FirefoxPasswordReader.oidAES256CBC
            }
            let blob = derSequence([
                derOctetString(FirefoxPasswordReader.bulkKeyID),
                derSequence([derOID(Array(oid)), derOctetString(iv)]),
                derOctetString(ciphertext)
            ])
            return blob.base64EncodedString()
        }
    }
}
