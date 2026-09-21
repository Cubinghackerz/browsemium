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

## Chromium edition

A second, power-user edition lives next to the WebKit app. It embeds CEF
(Chromium) behind the shared `BrowserEngine` protocol, so every view, tab
model, repository and policy is the same code; only the engine differs.

```sh
Scripts/fetch-cef.sh            # one-time: download the pinned CEF (~1.5 GB, arm64)
Scripts/build-cef-wrapper.sh    # one-time: build libcef_dll_wrapper.a (no CMake needed)
xcodegen generate --spec project.yml
xcodebuild -project Browsemium.xcodeproj -scheme BrowsemiumChromium \
    -configuration Debug -destination 'platform=macOS' build
```

The app target's post-build script assembles the CEF bundle layout (framework +
five helper apps named `Browsemium Chromium Helper[ (GPU|Plugin|Renderer|Alerts)].app`)
and `Scripts/release/sign-chromium.sh` signs inside-out — ad-hoc for local
builds, Developer ID for release.

Things that are true by design, and must stay true:

- **arm64 only.** The pinned CEF is `macosarm64`. Do not add x86_64 to the
  Chromium targets; the Intel slice could not load the framework anyway.
- **CEF is loaded, never linked.** `otool -L` on both executables shows no CEF
  dependency; `CefScopedLibraryLoader` dlopens the framework at runtime.
- **No App Sandbox entitlement.** CEF cannot run under it; Chromium's own
  renderer sandbox stays on. The entitlements file only carries JIT/memory and
  network keys.
- **Bridge is Objective-C++; Swift sees only `BrowsemiumCEF.h`.** No CEF/C++
  type crosses the module boundary (`module.modulemap` in
  `BrowsemiumCEF/include`).
- **Helpers come from `cef_variables.cmake`'s `CEF_HELPER_APP_SUFFIXES`** — the
  parenthesized names are load-bearing, do not "simplify" them.

Known gaps that are deliberately honest errors, not stubs: screenshots and
reader mode (need the DevTools protocol path), credential filling, per-profile
site-data clearing, request-interception blocking, and Chrome extensions
(which require Chrome-style windows, still unproven).

## Benchmarks

```sh
python3 Benchmarks/generate-fixtures.py
python3 Benchmarks/serve-fixtures.py --port 8791   # keep running while benchmarking
Benchmarks/benchmark-memory.sh --browsemium /Applications/Browsemium.app \
    --chrome "/Applications/Google Chrome.app" --trials 5 --settle 60
```

The 20% lower-memory target is a release gate. If the gate fails, do not publish a
comparative claim and do not change the measurement method to make it pass.

What the harness measures, and why:

- **Process tree, not name matching.** Memory is summed for the launched pid and
  every descendant. Matching by name counted a second copy of the browser the
  user already had open, and missed WebKit's page processes entirely.
- **WebKit page processes are attributed by difference.** WebKit spawns
  `com.apple.WebKit.*` XPC services through launchd, so they are not children of
  the app that asked for them and no public API attributes them. The harness
  sums them before launch and after settling, and attributes the difference to
  the run. It refuses to measure while another WebKit app is active, because
  that app's page processes would otherwise be counted as Browsemium's.
- **The profile directory must be inside the app container.** Browsemium is
  sandboxed: `--profile-dir=/tmp/...` is denied and the app silently falls back
  to an in-memory database, which measures something other than the shipped
  browser. The harness uses
  `~/Library/Containers/com.browsemium.browser/Data/tmp/browsemium-bench-N`.
- **Both browsers are measured the same way**, in the same run, with the same
  ten fixture pages and the same settle period.

Chrome parents its own helpers, so its tree is complete on its own; Browsemium's
number is the app plus the page processes that appeared. Report both the total
and the app-only figure, and never a number from a run where the pre-flight
check failed.

The harness refuses to report a gate verdict when a Browsemium trial shows no
WebKit page processes, because that means the ten pages never loaded and the run
measured an empty browser. Raise `--settle` until every trial reports page
processes (cold start plus WebKit warm-up can take longer than a short settle),
then rerun.

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
(if the keychain password is known) or let the app replace the item for one run:

```sh
BROWSEMIUM_CLAIM_WEBCRYPTO_KEY=1 open -a Browsemium
```

That opt-in makes the app delete WebKit's item and create its own, which also
makes every WebCrypto key a site already stored in IndexedDB undecryptable, so it
never happens automatically. Signed builds are never affected.

## Release

```sh
DEVELOPMENT_TEAM=<team id> Scripts/release/build-archive.sh
Scripts/release/create-dmg.sh
NOTARY_PROFILE=<keychain profile> Scripts/release/notarize.sh
SPARKLE_BIN=<sparkle bin> DOWNLOAD_URL_PREFIX=https://… Scripts/release/generate-appcast.sh
```

Signing and notarization credentials live in the keychain or CI secrets; never in
the repository or in build logs.

After each published release:

1. Update `Site/checksum.txt` with the DMG's SHA-256 — `Site/install.sh`
   verifies downloads against it.
2. Sign the DMG for Sparkle: `swift Scripts/release/sparkle-eddsa.swift sign
   build/Browsemium-<version>.dmg` and update the `enclosure` in
   `Site/appcast.xml` (URL, sparkle:version, sparkle:shortVersionString,
   sparkle:edSignature, length, pubDate).
3. Deploy `Site/` so the appcast is live before announcing the release.

The Sparkle EdDSA private key lives at `~/.config/browsemium/sparkle-ed25519.key`
(chmod 600). It is the release-signing secret — never commit it. The public key
is `SUPublicEDKey` in `project.yml`/`Info.plist`. Regenerate only with
`swift Scripts/release/sparkle-eddsa.swift keygen` if the key file is lost —
rotating the key orphans every installed copy's updater.
