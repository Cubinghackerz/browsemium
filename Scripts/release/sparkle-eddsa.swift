import CryptoKit
import Foundation

// Sparkle EdDSA key tool.
//
//   swift sparkle-eddsa.swift keygen      — generate a keypair, store the
//                                           private key outside the repo,
//                                           print the base64 public key for
//                                           SUPublicEDKey
//   swift sparkle-eddsa.swift sign <file> — print the base64 ed25519 signature
//                                           for the appcast's sparkle:edSignature
//
// Sparkle's EdDSA signature is plain ed25519 over the update archive's bytes;
// SUPublicEDKey is the base64 of the 32-byte public key.

let keyPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/browsemium/sparkle-ed25519.key")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: sparkle-eddsa.swift keygen | sign <file>") }

switch args[1] {
case "keygen":
    if FileManager.default.fileExists(atPath: keyPath.path) {
        let data = try! Data(contentsOf: keyPath)
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: String(data: data, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines))!)
        print("Key already exists at \(keyPath.path)")
        print("Public key (SUPublicEDKey): \(key.publicKey.rawRepresentation.base64EncodedString())")
        exit(0)
    }
    let key = Curve25519.Signing.PrivateKey()
    try! FileManager.default.createDirectory(
        at: keyPath.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try! key.rawRepresentation.base64EncodedString()
        .write(to: keyPath, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath.path)
    print("Private key written to \(keyPath.path) — keep it out of the repository.")
    print("Public key (SUPublicEDKey): \(key.publicKey.rawRepresentation.base64EncodedString())")

case "sign":
    guard args.count >= 3 else { fail("usage: sparkle-eddsa.swift sign <file>") }
    guard let encoded = try? String(contentsOf: keyPath, encoding: .utf8),
          let keyData = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
        fail("No private key at \(keyPath.path) — run keygen first.")
    }
    let fileData = try! Data(contentsOf: URL(fileURLWithPath: args[2]))
    let signature = try! key.signature(for: fileData)
    print(signature.base64EncodedString())

default:
    fail("usage: sparkle-eddsa.swift keygen | sign <file>")
}
