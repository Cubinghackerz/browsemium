import BrowsemiumExtensions
import CryptoKit
import Foundation
import Security
import Testing

private let exampleID = "abcdefghijklmnopabcdefghijklmnop"  // 32 chars, a–p

// MARK: - Reference parsing

@Test
func aBareExtensionIDParses() throws {
    let reference = try ChromeWebStoreReference.parse(exampleID)
    #expect(reference.extensionID == exampleID)
}

@Test
func theCurrentStoreDetailURLParses() throws {
    let url = "https://chromewebstore.google.com/detail/some-extension/\(exampleID)"
    let reference = try ChromeWebStoreReference.parse(url)
    #expect(reference.extensionID == exampleID)
}

@Test
func theLegacyStoreURLAndSchemelessInputParse() throws {
    let legacy = try ChromeWebStoreReference.parse(
        "https://chrome.google.com/webstore/detail/name/\(exampleID)?hl=en"
    )
    #expect(legacy.extensionID == exampleID)

    let schemeless = try ChromeWebStoreReference.parse(
        "chromewebstore.google.com/detail/name/\(exampleID)"
    )
    #expect(schemeless.extensionID == exampleID)
}

@Test
func aRewrittenStoreURLStillYieldsTheExtensionID() throws {
    let raw = "https://chromewebstore.google.com/detail/adblock-—-block-ads-across-the-web/\(exampleID)"
    let url = try #require(URL(string: raw))
    let reference = try #require(ChromeWebStoreReference.reference(in: url))
    #expect(reference.extensionID == exampleID)
    #expect(ChromeWebStoreReference.isStoreHost(url))
}

@Test
func nonStoreInputIsRejected() {
    #expect(throws: ChromeWebStoreReference.ParseError.self) {
        try ChromeWebStoreReference.parse("https://example.com/not-the-store")
    }
    // Wrong alphabet (g–z are not in Chrome's a–p id alphabet).
    #expect(throws: ChromeWebStoreReference.ParseError.self) {
        try ChromeWebStoreReference.parse("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz")
    }
    // Wrong length.
    #expect(throws: ChromeWebStoreReference.ParseError.self) {
        try ChromeWebStoreReference.parse("abcdefghij")
    }
    // A store URL whose last component is not an id.
    #expect(throws: ChromeWebStoreReference.ParseError.self) {
        try ChromeWebStoreReference.parse("https://chromewebstore.google.com/category/extensions")
    }
    #expect(throws: ChromeWebStoreReference.ParseError.self) {
        try ChromeWebStoreReference.parse("")
    }
}

// MARK: - Update endpoint

@Test
func theUpdateURLTargetsGooglesCRXService() throws {
    let url = ChromeWebStoreDownloader.updateURL(for: exampleID)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.scheme == "https")
    #expect(components.host == "clients2.google.com")
    #expect(components.path == "/service/update2/crx")
    let query = Dictionary(
        uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    )
    #expect(query["response"] == "redirect")
    #expect(query["acceptformat"] == "crx3")
    #expect(query["x"] == "id=\(exampleID)&uc")
}

// MARK: - Downloader

private func makeCRX(zipMarker: UInt8 = 0x03) -> Data {
    // Minimal CRX3: "Cr24" + version 3 + zero-length header + a zip magic.
    var data = Data([0x43, 0x72, 0x32, 0x34, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    data.append(contentsOf: [0x50, 0x4B, zipMarker, 0x04])
    data.append(Data(repeating: 0, count: 16))
    return data
}

private func protobufVarint(_ value: UInt64) -> Data {
    var value = value
    var result = Data()
    repeat {
        var byte = UInt8(value & 0x7F)
        value >>= 7
        if value != 0 { byte |= 0x80 }
        result.append(byte)
    } while value != 0
    return result
}

private func protobufBytes(field: Int, _ value: Data) -> Data {
    protobufVarint(UInt64(field << 3 | 2)) + protobufVarint(UInt64(value.count)) + value
}

private enum TestCRXKeyAlgorithm: Equatable {
    case rsa
    case ecdsa
}

private func derElement(tag: UInt8, content: Data) -> Data {
    var result = Data([tag])
    if content.count < 128 {
        result.append(UInt8(content.count))
    } else {
        var length = content.count
        var bytes: [UInt8] = []
        while length > 0 {
            bytes.append(UInt8(length & 0xFF))
            length >>= 8
        }
        result.append(0x80 | UInt8(bytes.count))
        result.append(contentsOf: bytes.reversed())
    }
    result.append(content)
    return result
}

private func subjectPublicKeyInfo(for algorithm: TestCRXKeyAlgorithm, rawKey: Data) -> Data {
    let algorithmIdentifier: Data
    switch algorithm {
    case .rsa:
        let rsaEncryptionOID = derElement(
            tag: 0x06,
            content: Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])
        )
        algorithmIdentifier = derElement(tag: 0x30, content: rsaEncryptionOID + derElement(tag: 0x05, content: Data()))
    case .ecdsa:
        let ecPublicKeyOID = derElement(
            tag: 0x06,
            content: Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
        )
        let p256OID = derElement(
            tag: 0x06,
            content: Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        )
        algorithmIdentifier = derElement(tag: 0x30, content: ecPublicKeyOID + p256OID)
    }
    let subjectPublicKey = derElement(tag: 0x03, content: Data([0]) + rawKey)
    return derElement(tag: 0x30, content: algorithmIdentifier + subjectPublicKey)
}

private func makeSignedCRX(
    algorithm: TestCRXKeyAlgorithm = .rsa,
    malformedSignedDataTag: Bool = false
) throws -> (data: Data, extensionID: String) {
    let attributes: [CFString: Any] = [
        kSecAttrKeyType: algorithm == .rsa ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeySizeInBits: algorithm == .rsa ? 2048 : 256
    ]
    var error: Unmanaged<CFError>?
    let privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
    let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
    let rawPublicKey = try #require(SecKeyCopyExternalRepresentation(publicKey, &error) as Data?)
    let publicData = subjectPublicKeyInfo(for: algorithm, rawKey: rawPublicKey)
    let idBytes = Data(SHA256.hash(data: publicData).prefix(16))
    let extensionID = CRXVerifier.extensionID(forPublicKey: publicData)
    let signedData = protobufBytes(field: 1, idBytes)
    let archive = Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0, count: 32)

    var signedLength = UInt32(signedData.count).littleEndian
    var message = Data("CRX3 SignedData\0".utf8)
    withUnsafeBytes(of: &signedLength) { message.append(contentsOf: $0) }
    message.append(signedData)
    message.append(archive)
    let digest = Data(SHA256.hash(data: message))
    let signingAlgorithm: SecKeyAlgorithm = algorithm == .rsa
        ? .rsaSignatureDigestPKCS1v15SHA256
        : .ecdsaSignatureDigestX962SHA256
    let signature = try #require(SecKeyCreateSignature(
        privateKey,
        signingAlgorithm,
        digest as CFData,
        &error
    ) as Data?)
    let proof = protobufBytes(field: 1, publicData) + protobufBytes(field: 2, signature)
    let proofField = protobufBytes(field: algorithm == .rsa ? 2 : 3, proof)
    let signedDataField: Data
    if malformedSignedDataTag {
        var tag = protobufVarint(UInt64(10_000 << 3 | 2))
        tag[tag.count - 1] |= 0x80
        while tag.count < 9 { tag.append(0x80) }
        tag.append(0x02) // Overflows a UInt64 varint and truncates to the original tag.
        signedDataField = tag + protobufVarint(UInt64(signedData.count)) + signedData
    } else {
        signedDataField = protobufBytes(field: 10_000, signedData)
    }
    let header = proofField + signedDataField

    var result = Data("Cr24".utf8)
    var version = UInt32(3).littleEndian
    var headerLength = UInt32(header.count).littleEndian
    withUnsafeBytes(of: &version) { result.append(contentsOf: $0) }
    withUnsafeBytes(of: &headerLength) { result.append(contentsOf: $0) }
    result.append(header)
    result.append(archive)
    return (result, extensionID)
}

@Test
func anECDSASignedCRX3SubjectPublicKeyInfoVerifies() throws {
    let package = try makeSignedCRX(algorithm: .ecdsa)
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-\(UUID().uuidString).crx")
    try package.data.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    try CRXVerifier.verify(fileAt: file, expectedExtensionID: package.extensionID)
}

@Test
func anOverflowingHeaderVarintIsRejectedEvenWhenItWouldTruncateToAValidTag() throws {
    let package = try makeSignedCRX(malformedSignedDataTag: true)
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-\(UUID().uuidString).crx")
    try package.data.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    #expect(throws: CRXVerifier.VerificationError.invalidHeader) {
        try CRXVerifier.verify(fileAt: file, expectedExtensionID: package.extensionID)
    }
}

@Test
func aCRXResponseBecomesANamedCRXFile() async throws {
    let package = try makeSignedCRX()
    let downloader = ChromeWebStoreDownloader { _ in
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try package.data.write(to: temp)
        let response = HTTPURLResponse(
            url: URL(string: "https://clients2.google.com/service/update2/crx")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (temp, response)
    }

    let file = try await downloader.downloadPackage(for: package.extensionID)
    defer { try? FileManager.default.removeItem(at: file) }

    #expect(file.pathExtension == "crx")
    #expect(file.deletingPathExtension().lastPathComponent.hasPrefix("browsemium-\(package.extensionID)-"))
}

@Test
func aPackageSignedForAnotherExtensionIDIsRejected() async throws {
    let package = try makeSignedCRX()
    let downloader = ChromeWebStoreDownloader { _ in
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try package.data.write(to: temp)
        let response = HTTPURLResponse(
            url: URL(string: "https://clients2.google.com/service/update2/crx")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (temp, response)
    }
    await #expect(throws: CRXVerifier.VerificationError.extensionIDMismatch) {
        try await downloader.downloadPackage(for: exampleID)
    }
}

@Test
func anOffAllowlistRedirectIsRejected() async throws {
    let package = try makeSignedCRX()
    let downloader = ChromeWebStoreDownloader { _ in
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try package.data.write(to: temp)
        let response = HTTPURLResponse(
            url: URL(string: "https://evil.example/package.crx")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (temp, response)
    }
    await #expect(throws: ChromeWebStoreDownloader.DownloadError.unsafeRedirect) {
        try await downloader.downloadPackage(for: package.extensionID)
    }
}

@Test
func anUnsignedBareZIPResponseIsRejected() async throws {
    let payload = Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0, count: 24)
    let downloader = ChromeWebStoreDownloader { _ in
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try payload.write(to: temp)
        let response = HTTPURLResponse(
            url: URL(string: "https://clients2.google.com/service/update2/crx")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (temp, response)
    }

    await #expect(throws: ChromeWebStoreDownloader.DownloadError.notAPackage) {
        try await downloader.downloadPackage(for: exampleID)
    }
}

@Test
func anErrorPageIsNotAPackage() async throws {
    let downloader = ChromeWebStoreDownloader { _ in
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("<html>not found</html>".utf8).write(to: temp)
        let response = HTTPURLResponse(
            url: URL(string: "https://clients2.google.com/service/update2/crx")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (temp, response)
    }
    await #expect(throws: ChromeWebStoreDownloader.DownloadError.notAPackage) {
        try await downloader.downloadPackage(for: exampleID)
    }
}

@Test
func nonHTTPResponsesAreRejectedBeforeReadingPackageData() async throws {
    let package = try makeSignedCRX()
    let downloader = ChromeWebStoreDownloader { _ in
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try package.data.write(to: temp)
        return (temp, URLResponse())
    }

    await #expect(throws: ChromeWebStoreDownloader.DownloadError.unavailable) {
        try await downloader.downloadPackage(for: package.extensionID)
    }
}

@Test
func aFailedHTTPStatusIsUnavailable() async throws {
    let downloader = ChromeWebStoreDownloader { _ in
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try makeCRX().write(to: temp)
        let response = HTTPURLResponse(
            url: URL(string: "https://clients2.google.com/service/update2/crx")!,
            statusCode: 404, httpVersion: nil, headerFields: nil
        )!
        return (temp, response)
    }
    await #expect(throws: ChromeWebStoreDownloader.DownloadError.self) {
        try await downloader.downloadPackage(for: exampleID)
    }
}
