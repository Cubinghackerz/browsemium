# Browsemium

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)

A native macOS browser for people who use AI all day. WebKit-based, written in
Swift 6 with SwiftUI and AppKit, open architecture, no account, no telemetry,
no cloud sync — browsing data stays on the Mac.

A second Chromium/CEF edition shares the same UI and data layers behind a
`BrowserEngine` protocol. The WebKit edition is the daily-driver target; the
Chromium edition is parked for power users who need it.

## Features

- **Tabs your way.** Horizontal strip or vertical sidebar — picked at first
  run, changeable in Settings — with pinned tabs, folders, drag reordering,
  and ⌘1–9 selection.
- **Spaces.** Separate tab sets with optional Touch ID lock. Locked spaces
  stay closed at launch and out of the command palette.
- **Split view.** Up to four tiled panes: right-click a tab → "Split View
  With…", or drag a tab to a window edge.
- **Peek overlays.** ⌘-click any link for a floating live preview; promote it
  to a tab or into a split, or dismiss with Esc. Optional hover-peek is off by
  default — resting a pointer must never trigger a network request.
- **Private windows.** ⇧⌘N opens a window that is private from its first
  frame: ephemeral WebKit store, no history, no closed-tab records, no
  session snapshot, no warm-tab preloading, and extensions never inject into
  private views. The private New Tab page states plainly what is protected —
  and what is not (your network and ISP can still see traffic).
- **Extensions (Beta).** Chrome/Firefox-style extensions via Apple's
  `WKWebExtension` APIs (macOS 15.4+), including Chrome Web Store installs.
  Permission prompts are explicit and never auto-granted. Known limits are
  documented in Settings.
- **AI assistant, no autonomy.** Provider web panels plus optional BYOK API
  access (OpenAI, Anthropic, Gemini, Grok, Ollama), keys in the macOS
  keychain. Page text, selections, and screenshots are captured only on
  request and reviewed in a sheet before anything is sent. The assistant
  never clicks, types, or submits.
- **Command palette.** ⌘K searches tabs, history, bookmarks, commands, and
  intent actions in one field.
- **Privacy defaults.** `WKContentRuleList` ad/tracker blocking, per-site
  permissions, clear-on-quit, address-bar suggestions sourced from local
  history and bookmarks only.
- **Downloads.** See live progress, tell completed files from failed or
  interrupted transfers, and reveal downloaded files in Finder.
- **Memory saver.** Background tabs unload after a configurable idle period
  with a ceiling on live tabs — the in-app copy states the trade-off.

## Install

Install or update from Terminal:

```sh
curl -fsSL https://browsemium.vercel.app/install.sh | bash
```

The installer fetches the latest published DMG and checks the release manifest,
SHA-256 checksum, DMG integrity, and the app's signature, sandbox entitlement,
and architectures before installing Browsemium in `/Applications`. Updating
leaves your profiles, tabs, and browsing data in place. The installer source is
available at [`Site/install.sh`](Site/install.sh) for review before running it.

Current releases are **preview builds: ad-hoc signed, not notarized by Apple
yet**. macOS may block the first launch; allow it once in System Settings →
Privacy & Security → **Open Anyway**. The installer never removes quarantine
attributes or bypasses Gatekeeper. Developer ID signing, notarization, Sparkle
updates, and the Homebrew cask return with the stable release. Individual
builds can be browsed on
[GitHub Releases](https://github.com/Cubinghackerz/browsemium/releases/latest).

## Requirements and build

- macOS 14 or newer (extension host needs 15.4+), Apple silicon or Intel
- Xcode 16.3 or newer and XcodeGen 2.41 or newer

```sh
xcodegen generate --spec project.yml
xcodebuild -project Browsemium.xcodeproj -scheme Browsemium \
    -configuration Debug build
open "$(xcodebuild -project Browsemium.xcodeproj -scheme Browsemium \
    -configuration Debug -showBuildSettings | awk '/BUILT_PRODUCTS_DIR/ {print $3}')/Browsemium.app"
```

Package-only validation (no app build needed):

```sh
swift test --package-path Packages/BrowsemiumKit
```

Headless/core validation with Command Line Tools only:

```sh
BROWSEMIUM_HEADLESS=1 swift run --package-path Packages/BrowsemiumKit \
    BrowsemiumHeadlessTests
```

Development conventions, the Chromium edition build, content-rule
regeneration, benchmarking, and release signing are documented in
[AGENTS.md](AGENTS.md). The competitive research and phased roadmap live in
[MEGAPLAN.md](MEGAPLAN.md); the product brief in [PRODUCT.md](PRODUCT.md).

## Repository layout

| Path | Contents |
|---|---|
| `BrowsemiumApp/` | The macOS app target |
| `BrowsemiumChromiumApp/` | The CEF/Chromium edition app target |
| `BrowsemiumCEF/` | Objective-C++ bridge; the only place CEF headers cross into the build |
| `Packages/BrowsemiumKit/` | The shared core: `BrowsemiumCore`, `BrowsemiumData`, `BrowsemiumEngine`, `BrowsemiumEngineKit`, `BrowsemiumExtensions`, `BrowsemiumAI`, `BrowsemiumUI` |
| `Vendors/CEF/` | The pinned Chromium Embedded Framework binary |
| `Benchmarks/` | Memory benchmark harness and fixtures |
| `Scripts/` | Build, release, and content-rule tooling |
| `ThirdPartyNotices/` | The authoritative notices file that ships in the app bundle |
| `Site/` | Landing page, installer script, and update appcast |

## Privacy

No account, no telemetry, no cloud sync. AI features are opt-in and
review-gated. Nothing in this repository should ever contain credentials —
provider keys live in the macOS keychain.

## Credits and acknowledgements

Browsemium stands on the work below. `ThirdPartyNotices/README.md` is the
authoritative notices file and ships inside the app bundle.

### Swift packages

| Package | Version | License | Used for |
|---|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.11.1 | MIT | Local SQLite storage — history, bookmarks, downloads, permissions, settings |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) (with swift-cmark) | 0.8.0 | Apache-2.0 | Rendering assistant output as native blocks |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.9.6 | MIT (framework), BSD-style (tools) | Signed automatic updates for the direct-download build |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | 2.41+ | MIT | Generating `Browsemium.xcodeproj` from `project.yml` — build tool only, not shipped |

### Bundled resources

| Resource | Source | License | Used for |
|---|---|---|---|
| `Readability.js` | [mozilla/readability](https://github.com/mozilla/readability), commit `ab4027a8b37669745016869a37a504727992b2ba` | Apache-2.0 | Reader mode and page-text capture, only on explicit user request |
| Search engine marks (Google, DuckDuckGo, Brave) | [Simple Icons](https://github.com/simple-icons/simple-icons) | CC0-1.0 | Address-bar engine picker. The marks remain their owners' trademarks; use here is nominative, to identify the engine |
| Bing mark | Bing's own favicon (`www.bing.com/sa/simg/favicon-2x.ico`) | — | Nominative use only. Simple Icons removed the Microsoft Bing mark in 2024 at Microsoft's request, so it is not taken from that set |

### Engines and platform

- **WebKit** — the primary engine, via Apple's WebKit framework;
  `WKWebExtension`/`WKWebExtensionController` power the extension host on
  macOS 15.4+.
- **SwiftUI, AppKit, Foundation, LocalAuthentication** — Apple platform
  frameworks under the Xcode and macOS SDK license.
- **[Chromium Embedded Framework](https://github.com/chromiumembedded/cef)**
  — 152.0.6+g708dc14 (Chromium 152.0.7977.83), vendored under
  `Vendors/CEF/` for the parked Chromium edition only. BSD-3-Clause
  (Marshall A. Greenblatt, portions Google Inc.); Chromium's own third-party
  licenses ship in `Vendors/CEF/current/CREDITS.html`. CEF is `dlopen`ed at
  runtime, never linked.

### Content rules

The bundled starter content-blocker list is Browsemium's own
(`Scripts/generate-starter-rules.py`). Third-party filter lists are not
shipped; the licence gate for converting external lists is documented in
`AGENTS.md`.

### License

Browsemium is licensed under [Apache-2.0](LICENSE). Third-party components
retain their licenses above.
