# Third-party notices

Browsemium ships the components below. Keep this file current whenever a
dependency or bundled resource changes, and ship it inside the app bundle.

## Swift packages

| Package | Version | License | Used for |
|---|---|---|---|
| GRDB.swift | 7.11.1 | MIT | Local SQLite storage (history, bookmarks, downloads, permissions, settings) |
| Sparkle | 2.9.6 | MIT (framework), BSD-style for tools | Signed automatic updates for the direct-download DMG |
| swift-markdown | 0.8.0 | Apache 2.0 | Parsing assistant output into native blocks |
| swift-snapshot-testing | 1.19.4 | MIT | Test-only snapshot assertions (not shipped) |

## Bundled resources

| Resource | Source | License | Notes |
|---|---|---|---|
| Readability.js | mozilla/readability, commit `ab4027a8b37669745016869a37a504727992b2ba` | Apache 2.0 | Bundled as `Readability-LICENSE.md` next to the script in `BrowsemiumEngine`; used only on explicit user capture |

## Provider marks

Provider icons and names (ChatGPT, Claude, Gemini, Grok) are trademarks of their
owners. Bundle them only from a reviewed source with its license, and confirm the
providers' brand-use requirements before shipping a release build. Until that
review completes, the app must fall back to text labels.

## Content-filter lists

EasyList and EasyPrivacy are dual-licensed GPLv3 / CC BY-SA 3.0. Compiled content
rules are **not** bundled until redistribution rights are reviewed and recorded
here, together with the exact source revision and the attribution text required
by the license. `Scripts/generate-content-rules.py` refuses to run without an
explicit `--accept-license` acknowledgement for this reason.
