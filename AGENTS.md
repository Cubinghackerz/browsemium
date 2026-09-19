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
python3 Scripts/generate-content-rules.py --input <filter-list.txt> \
    --output <rules.json> --accept-license "<source list and license review note>"
```

Compiled rules are not bundled until redistribution rights are recorded in
`ThirdPartyNotices/README.md`. Treat a `WKContentRuleListStore` compile failure as
a release blocker.

## Release

```sh
DEVELOPMENT_TEAM=<team id> Scripts/release/build-archive.sh
Scripts/release/create-dmg.sh
NOTARY_PROFILE=<keychain profile> Scripts/release/notarize.sh
SPARKLE_BIN=<sparkle bin> DOWNLOAD_URL_PREFIX=https://… Scripts/release/generate-appcast.sh
```

Signing and notarization credentials live in the keychain or CI secrets; never in
the repository or in build logs.
