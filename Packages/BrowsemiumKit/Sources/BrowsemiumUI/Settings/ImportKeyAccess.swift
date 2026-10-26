import BrowsemiumData
import Foundation
import SwiftUI
import BrowsemiumEngineKit

struct UnlockedImportKeyProvider: BrowserCredentialKeyProviding {
    let key: Data

    func safeStorageKey(for source: BrowserImportSource) throws -> Data? { key }
}

/// Decides, once per browser, how an import gets that browser's password key.
///
/// The key is the source browser's, so it is read only when the person presses
/// Confirm on an import that selected passwords or cookies:
/// 1. A silent read that never shows a macOS dialog.
/// 2. If the key is locked, the person is asked first. Only their Continue
///    allows one interactive read, which is the standard macOS prompt.
/// 3. Denial is final for that import: no retry, passwords and cookies are
///    left out, and everything else still imports.
///
/// Nothing here runs when Settings opens or a preview is built.
enum ImportKeyAccess {
    enum SkipReason: Equatable {
        /// macOS access was refused or the prompt was dismissed.
        case declined
        /// The browser has no stored key to read.
        case notFound
    }

    struct Plan {
        /// Ready to decrypt with, keyed by browser.
        var providers: [BrowserImportSource: any BrowserCredentialKeyProviding] = [:]
        /// Locked; the person has not been asked yet.
        var needsConsent: [BrowserImportSource] = []
        /// Passwords and cookies will be left out for these browsers.
        var skipped: [BrowserImportSource: SkipReason] = [:]
    }

    static func needsKey(_ preview: BrowserImportPreview, _ options: BrowserImportOptions) -> Bool {
        preview.source.family == .chromium
            && ((options.includesPasswords && preview.credentialCount > 0)
                || (options.includesCookies && preview.cookieCount > 0))
    }

    /// `consented` is false for the first pass, which never shows a dialog, and
    /// true after the person pressed Continue on the consent sheet.
    static func plan(
        for selections: [(preview: BrowserImportPreview, options: BrowserImportOptions)],
        keychain: KeychainStore,
        consented: Bool
    ) -> Plan {
        var plan = Plan()
        var seen = Set<BrowserImportSource>()
        for selection in selections where needsKey(selection.preview, selection.options) {
            let source = selection.preview.source
            guard seen.insert(source).inserted, let service = source.safeStorageService else { continue }
            do {
                guard let password = try keychain.secretWithoutInteraction(service: service), !password.isEmpty else {
                    plan.skipped[source] = .notFound
                    continue
                }
                plan.providers[source] = UnlockedImportKeyProvider(key: try ChromeCredentialCrypto.derivedKey(safeStoragePassword: password))
            } catch is KeychainStore.KeychainError {
                guard consented else {
                    plan.needsConsent.append(source)
                    continue
                }
                let provider = ChromeSafeStorageKeyProvider(keychain: keychain, allowsAuthorizationPrompt: true)
                if let key = try? provider.safeStorageKey(for: source) {
                    plan.providers[source] = UnlockedImportKeyProvider(key: key)
                } else {
                    plan.skipped[source] = .declined
                }
            } catch {
                plan.skipped[source] = .declined
            }
        }
        plan.needsConsent.sort { $0.displayName < $1.displayName }
        return plan
    }

    static func withoutSecrets(_ options: BrowserImportOptions) -> BrowserImportOptions {
        var stripped = options
        stripped.includesPasswords = false
        stripped.includesCookies = false
        return stripped
    }

    static func withoutCookies(_ options: BrowserImportOptions) -> BrowserImportOptions {
        var stripped = options
        stripped.includesCookies = false
        return stripped
    }

    static func skipNote(for source: BrowserImportSource, _ reason: SkipReason) -> String {
        switch reason {
        case .declined:
            "Passwords and cookies were left out because macOS did not give Browsemium \(source.displayName)'s key. Everything else was imported; export a password CSV from \(source.displayName) to add passwords."
        case .notFound:
            "Passwords and cookies were left out because \(source.displayName) has no password key on this Mac."
        }
    }
}

/// Shown inside the import sheet when a browser's key is locked, before the
/// macOS prompt. Nothing is read until the person presses Continue.
@MainActor
struct ImportKeyConsentCard: View {
    let sources: [BrowserImportSource]
    let onChoice: (_ allow: Bool) -> Void

    private var names: String { sources.map(\.displayName).formatted(.list(type: .and)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Allow access to \(names)'s password key?")
                .font(BrowserType.font(.small, weight: .semibold))
            Text("Passwords and cookies are encrypted with a key \(names) keeps in your keychain. macOS will show its own prompt and may ask for your Mac password. Browsemium reads the key once, holds it in memory for this import only, and never stores it. If you say no, everything else still imports.")
                .font(BrowserType.font(.caption))
                .foregroundStyle(Color.browsemiumSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                BrowsemiumTextButton("Import without passwords and cookies") { onChoice(false) }
                Spacer()
                BrowsemiumPrimaryButton("Continue") { onChoice(true) }
            }
        }
        .padding(12)
        .background(Color.browsemiumSurface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.browsemiumWarning, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}
