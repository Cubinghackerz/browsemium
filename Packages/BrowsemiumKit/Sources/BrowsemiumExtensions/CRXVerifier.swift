import CryptoKit
import Foundation
import Security

/// Verifies the developer proof in a CRX3 package and binds it to the Chrome
/// Web Store id requested by the user. The parser intentionally understands
/// only the small protobuf surface CRX3 signing uses and rejects malformed or
/// oversized headers before allocating them.
public enum CRXVerifier {
    public enum VerificationError: Swift.Error, LocalizedError, Equatable {
        case invalidHeader
        case headerTooLarge
        case extensionIDMismatch
        case invalidSignature

        public var errorDescription: String? {
            switch self {
            case .invalidHeader: "The CRX3 package has an invalid signed header."
            case .headerTooLarge: "The CRX3 signed header is unreasonably large."
            case .extensionIDMismatch: "The package signature does not belong to the requested extension."
            case .invalidSignature: "The CRX3 package signature is invalid."
            }
        }
    }

    private enum Algorithm { case rsa, ecdsa }
    private struct Proof { let key: Data; let signature: Data; let algorithm: Algorithm }
    private static let maximumHeaderBytes = 1024 * 1024

    public static func verify(fileAt url: URL, expectedExtensionID: String) throws {
        guard ChromeWebStoreReference.isValidID(expectedExtensionID) else {
            throw VerificationError.extensionIDMismatch
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fixed = try handle.read(upToCount: 12) ?? Data()
        guard fixed.count == 12,
              fixed.prefix(4) == Data("Cr24".utf8),
              fixed.readLittleEndianUInt32(at: 4) == 3 else {
            throw VerificationError.invalidHeader
        }
        let headerLength = Int(fixed.readLittleEndianUInt32(at: 8))
        guard headerLength > 0 else { throw VerificationError.invalidHeader }
        guard headerLength <= maximumHeaderBytes else { throw VerificationError.headerTooLarge }
        let header = try handle.read(upToCount: headerLength) ?? Data()
        guard header.count == headerLength else { throw VerificationError.invalidHeader }
        let archiveOffset = 12 + headerLength

        let parsed = try parseHeader(header)
        guard parsed.signedData.count > 0,
              let declaredID = try parseDeclaredID(parsed.signedData),
              declaredID.count == 16 else {
            throw VerificationError.invalidHeader
        }
        guard extensionID(from: declaredID) == expectedExtensionID else {
            throw VerificationError.extensionIDMismatch
        }

        var hasher = SHA256()
        hasher.update(data: Data("CRX3 SignedData\0".utf8))
        var signedLength = UInt32(parsed.signedData.count).littleEndian
        withUnsafeBytes(of: &signedLength) { hasher.update(data: Data($0)) }
        hasher.update(data: parsed.signedData)
        try handle.seek(toOffset: UInt64(archiveOffset))
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = Data(hasher.finalize())

        var foundMatchingKey = false
        for proof in parsed.proofs {
            let keyHash = Data(SHA256.hash(data: proof.key).prefix(16))
            guard keyHash == declaredID else { continue }
            foundMatchingKey = true
            if verify(proof: proof, digest: digest) { return }
        }
        if !foundMatchingKey { throw VerificationError.extensionIDMismatch }
        throw VerificationError.invalidSignature
    }

    public static func extensionID(forPublicKey key: Data) -> String {
        extensionID(from: Data(SHA256.hash(data: key).prefix(16)))
    }

    private static func extensionID(from bytes: Data) -> String {
        let alphabet = Array("abcdefghijklmnop")
        return String(bytes.flatMap { [alphabet[Int($0 >> 4)], alphabet[Int($0 & 0x0F)]] })
    }

    private static func verify(proof: Proof, digest: Data) -> Bool {
        guard let keyData = securityKeyRepresentation(for: proof) else { return false }
        let keyType: CFString = proof.algorithm == .rsa ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom
        var attributes: [CFString: Any] = [
            kSecAttrKeyType: keyType,
            kSecAttrKeyClass: kSecAttrKeyClassPublic
        ]
        if proof.algorithm == .ecdsa {
            attributes[kSecAttrKeySizeInBits] = 256
        }
        guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil) else {
            return false
        }
        let algorithm: SecKeyAlgorithm = proof.algorithm == .rsa
            ? .rsaSignatureDigestPKCS1v15SHA256
            : .ecdsaSignatureDigestX962SHA256
        return SecKeyIsAlgorithmSupported(key, .verify, algorithm)
            && SecKeyVerifySignature(key, algorithm, digest as CFData, proof.signature as CFData, nil)
    }

    /// CRX3 proofs carry an X.509 SubjectPublicKeyInfo. Security.framework's
    /// external key representation is different for each key type, so unpack
    /// the SPKI and pass its PKCS#1 RSA key or X9.63 P-256 point to SecKey.
    private static func securityKeyRepresentation(for proof: Proof) -> Data? {
        var document = DERReader(proof.key)
        guard let sequence = document.read(tag: 0x30), document.isAtEnd else { return nil }
        var subjectPublicKeyInfo = DERReader(sequence)
        guard let algorithmIdentifier = subjectPublicKeyInfo.read(tag: 0x30),
              let bitString = subjectPublicKeyInfo.read(tag: 0x03),
              subjectPublicKeyInfo.isAtEnd,
              bitString.first == 0 else {
            return nil
        }

        var algorithm = DERReader(algorithmIdentifier)
        guard let algorithmOID = algorithm.read(tag: 0x06) else { return nil }
        let keyBytes = Data(bitString.dropFirst())

        switch proof.algorithm {
        case .rsa:
            // rsaEncryption, with the optional DER NULL parameter used by
            // standard X.509 SubjectPublicKeyInfo encodings.
            guard algorithmOID == Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]) else {
                return nil
            }
            if !algorithm.isAtEnd {
                guard let nullParameters = algorithm.read(tag: 0x05),
                      nullParameters.isEmpty,
                      algorithm.isAtEnd else {
                    return nil
                }
            }
            return keyBytes

        case .ecdsa:
            // id-ecPublicKey with the named P-256 curve. CRX3 uses this curve
            // and stores the point as an ANSI X9.63 uncompressed public key.
            guard algorithmOID == Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]),
                  algorithm.read(tag: 0x06) == Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]),
                  algorithm.isAtEnd,
                  keyBytes.count == 65,
                  keyBytes.first == 0x04 else {
                return nil
            }
            return keyBytes
        }
    }

    private static func parseHeader(_ data: Data) throws -> (proofs: [Proof], signedData: Data) {
        var reader = ProtobufReader(data)
        var proofs: [Proof] = []
        var signedData = Data()
        while let field = try reader.nextField() {
            switch (field.number, field.bytes) {
            case (2, .some(let bytes)):
                proofs.append(try parseProof(bytes, algorithm: .rsa))
            case (3, .some(let bytes)):
                proofs.append(try parseProof(bytes, algorithm: .ecdsa))
            case (10_000, .some(let bytes)):
                signedData = bytes
            default:
                continue
            }
        }
        guard !proofs.isEmpty else { throw VerificationError.invalidHeader }
        return (proofs, signedData)
    }

    private static func parseProof(_ data: Data, algorithm: Algorithm) throws -> Proof {
        var reader = ProtobufReader(data)
        var key = Data()
        var signature = Data()
        while let field = try reader.nextField() {
            if field.number == 1, let bytes = field.bytes { key = bytes }
            if field.number == 2, let bytes = field.bytes { signature = bytes }
        }
        guard !key.isEmpty, !signature.isEmpty else { throw VerificationError.invalidHeader }
        return Proof(key: key, signature: signature, algorithm: algorithm)
    }

    private static func parseDeclaredID(_ data: Data) throws -> Data? {
        var reader = ProtobufReader(data)
        while let field = try reader.nextField() {
            if field.number == 1 { return field.bytes }
        }
        return nil
    }
}

private struct ProtobufReader {
    struct Field { let number: Int; let bytes: Data? }
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }

    mutating func nextField() throws -> Field? {
        guard offset < data.count else { return nil }
        let tag = try readVarint()
        let number = Int(tag >> 3)
        guard number > 0 else { throw CRXVerifier.VerificationError.invalidHeader }
        switch Int(tag & 0x07) {
        case 0:
            _ = try readVarint()
            return Field(number: number, bytes: nil)
        case 1:
            try advance(8)
            return Field(number: number, bytes: nil)
        case 2:
            let rawLength = try readVarint()
            guard let length = Int(exactly: rawLength) else {
                throw CRXVerifier.VerificationError.invalidHeader
            }
            guard length >= 0, offset <= data.count - length else {
                throw CRXVerifier.VerificationError.invalidHeader
            }
            let bytes = data.subdata(in: offset..<(offset + length))
            offset += length
            return Field(number: number, bytes: bytes)
        case 5:
            try advance(4)
            return Field(number: number, bytes: nil)
        default:
            throw CRXVerifier.VerificationError.invalidHeader
        }
    }

    private mutating func readVarint() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard offset < data.count else { throw CRXVerifier.VerificationError.invalidHeader }
            let byte = data[offset]
            offset += 1
            // A UInt64 varint's tenth byte can encode only bit 63. Reject
            // overflow instead of silently truncating high bits in the shift.
            if shift == 63, byte > 1 {
                throw CRXVerifier.VerificationError.invalidHeader
            }
            value |= UInt64(byte & 0x7F) << UInt64(shift)
            if byte & 0x80 == 0 { return value }
        }
        throw CRXVerifier.VerificationError.invalidHeader
    }

    private mutating func advance(_ count: Int) throws {
        guard offset <= data.count - count else { throw CRXVerifier.VerificationError.invalidHeader }
        offset += count
    }
}

/// Small strict DER reader for the SubjectPublicKeyInfo fields accepted above.
/// Only low-tag-number elements are needed; indefinite and non-minimal lengths
/// are rejected.
private struct DERReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    var isAtEnd: Bool { offset == data.count }

    mutating func read(tag expectedTag: UInt8) -> Data? {
        guard offset <= data.count - 2,
              data[offset] == expectedTag else {
            return nil
        }
        offset += 1

        let firstLengthByte = data[offset]
        offset += 1
        let length: Int
        if firstLengthByte & 0x80 == 0 {
            length = Int(firstLengthByte)
        } else {
            let lengthByteCount = Int(firstLengthByte & 0x7F)
            guard lengthByteCount > 0,
                  lengthByteCount <= MemoryLayout<Int>.size,
                  offset <= data.count - lengthByteCount,
                  data[offset] != 0 else {
                return nil
            }
            var decodedLength = 0
            for byte in data[offset..<(offset + lengthByteCount)] {
                guard decodedLength <= (Int.max - Int(byte)) / 256 else { return nil }
                decodedLength = decodedLength * 256 + Int(byte)
            }
            guard decodedLength >= 128 else { return nil }
            length = decodedLength
            offset += lengthByteCount
        }

        guard length >= 0, offset <= data.count - length else { return nil }
        let result = data.subdata(in: offset..<(offset + length))
        offset += length
        return result
    }
}

private extension Data {
    func readLittleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
