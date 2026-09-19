# Browsemium Development

## Prerequisites

Building the macOS app requires the full Xcode installation, not only the Command Line Tools. Use Xcode 16.3 or newer for Swift 6.1 support, select it with `xcode-select`, accept its license, and install `xcodegen` 2.41 or newer.

Core package validation can run with Command Line Tools by excluding SwiftUI targets:

```sh
BROWSEMIUM_HEADLESS=1 swift package resolve --package-path Packages/BrowsemiumKit
BROWSEMIUM_HEADLESS=1 swift build --package-path Packages/BrowsemiumKit
BROWSEMIUM_HEADLESS=1 swift run --package-path Packages/BrowsemiumKit BrowsemiumHeadlessTests
```

With full Xcode selected, validate the complete package including SwiftUI:

```sh
swift build --package-path Packages/BrowsemiumKit
swift test --package-path Packages/BrowsemiumKit
```

Generate the Xcode project from the repository root only when full Xcode and XcodeGen are available:

```sh
xcodegen generate --spec project.yml
```

Build and test the generated app project:

```sh
xcodebuild -project Browsemium.xcodeproj -scheme Browsemium -configuration Debug build
xcodebuild -project Browsemium.xcodeproj -scheme Browsemium test
```

Do not edit generated Xcode project files. Update `project.yml` and regenerate instead.

## Benchmarks

```sh
python3 Benchmarks/generate-fixtures.py
python3 Benchmarks/serve-fixtures.py --port 8791   # keep running while benchmarking
Benchmarks/benchmark-memory.sh --browsemium /Applications/Browsemium.app \
    --chrome "/Applications/Google Chrome.app" --trials 5 --settle 60
```

The 20% lower-memory target is a release gate. If the gate fails, do not publish a
comparative claim and do not change the measurement method to make it pass.

## Content rules

```sh
# Regenerate the bundled starter list (Browsemium's own host list).
python3 Scripts/generate-starter-rules.py > \
    Packages/BrowsemiumKit/Sources/BrowsemiumEngine/Resources/StarterContentRules.json

# Convert an external filter list. Requires a recorded licence review.
python3 Scripts/generate-content-rules.py --input <filter-list.txt> \
    --output <rules.json> --accept-license "<source list and license review note>"
```

Compiled rules are not bundled until redistribution rights are recorded in
`ThirdPartyNotices/README.md`. Treat a `WKContentRuleListStore` compile failure as
a release blocker.

WebKit's content-rule regex engine is a restricted subset:

- **No alternation.** `a|b` fails with "Disjunctions are not supported yet" and
  the entire list fails to compile. Emit one rule per host. The headless runner
  asserts this, and `Scripts/generate-starter-rules.py` refuses to emit it.
- **`if-domain` matches the top-level page, not the request.** Use `url-filter`
  to match the request host, and `unless-domain` for first-party exceptions.

Verify a rule list compiles before shipping it. `WKContentRuleListStore` writes
the compiled list to the app container, so a successful launch leaves
`ContentRuleLists/ContentRuleList-*` behind — an empty directory means the rules
did not compile.

## Development loop

```sh
Scripts/dev-loop.sh   # rebuild + relaunch the app whenever sources change
```

## Keychain behaviour

Opening Settings must never trigger a macOS keychain prompt. Check for stored
secrets with `KeychainStore.hasSecret(account:)`, which queries attributes only;
reading `secret(account:)` decrypts the item and macOS asks for permission.

## The "… WebCrypto Master Key" prompt

WebKit creates a keychain item named `<App> WebCrypto Master Key` (account
`com.apple.WebKit.WebCrypto.master+<bundle id>`) the first time a page uses
WebCrypto. It encrypts WebCrypto keys that sites keep in IndexedDB. This app
never reads that item itself.

macOS ties keychain access to the code signature:

- **Ad-hoc signing** (the default for local Debug builds, `Signature=adhoc`,
  `TeamIdentifier=not set`) produces a different signature on every build, so
  macOS treats each rebuild as a new app and asks for permission again.
  "Always Allow" only holds until the next rebuild.
- **Stable signing** keeps the designated requirement constant, so permission
  is granted once and never asked again. Release builds sign with a Developer
  ID via `Scripts/release/build-archive.sh`, so **end users never see this
  prompt**.

Do not try to silence it by weakening the item's ACL, and do not delete the
item automatically — it is the user's keychain. `Scripts/create-dev-signing-identity.sh`
can create a stable local identity, but macOS requires the login keychain
password to authorize the key the first time; without that password the build
fails with `errSecInternalComponent`, so ad-hoc signing is the safe default.

If the prompt is in the way during development, either click **Always Allow**
(if the keychain password is known) or delete the stale item once so WebKit
recreates it under the current build:

```sh
security delete-generic-password -s "Browsemium WebCrypto Master Key"
```

## Release

```sh
DEVELOPMENT_TEAM=<team id> Scripts/release/build-archive.sh
Scripts/release/create-dmg.sh
NOTARY_PROFILE=<keychain profile> Scripts/release/notarize.sh
SPARKLE_BIN=<sparkle bin> DOWNLOAD_URL_PREFIX=https://… Scripts/release/generate-appcast.sh
```

Signing and notarization credentials live in the keychain or CI secrets; never in
the repository or in build logs.

After each published release, update `Site/checksum.txt` with the DMG's SHA-256.
`Site/install.sh` verifies downloads against that file, which is served from a
different host than the release asset.
