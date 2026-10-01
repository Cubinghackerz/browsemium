# Browsemium — Product Context

Written for the Impeccable skill. Everything here is drawn from the working
brief and the shipped code; assumptions are labelled.

## What it is

A native macOS browser for people who use AI all day. WebKit-based, built in
Swift, distributed as a DMG — currently ad-hoc signed preview builds verified
by checksum and bundle integrity, with Developer ID signing and notarization
planned for the stable release path.

## Who it is for

AI power users on macOS: developers, researchers, writers who keep ChatGPT,
Claude, Gemini, or Grok open beside their work and paste context into them all
day. They are comfortable with API keys and value privacy over conveniences
that require an account.

## What it promises, and what it refuses to claim

- **Faster workflows, not faster rendering.** Browsemium does not claim to
  render pages faster than Chrome; it claims to get you to the answer sooner.
- **Lower memory by unloading, and it says so.** Background tabs are unloaded
  after a configurable idle period, with a ceiling on simultaneously loaded
  tabs. The in-app copy states the trade-off: pages reload when you return.
- **No account, no product telemetry, no cloud sync.** Browser records are
  stored locally; websites, extensions, searches, and chosen AI providers
  still receive their ordinary network traffic.
- **No autonomous AI.** The assistant does not operate browsing pages.
  API requests have a native review sheet. Provider-website sends prepare
  enabled page metadata and readable text at the user's send action, without
  a separate native review sheet; that context is enabled by default.
  Screenshots, selections, and files require an explicit attachment choice.
- **Ad and tracker blocking through WebKit content rules**, reported as rule
  state only — WebKit does not expose blocked-request counts, so Browsemium
  never shows a number it cannot verify.

## Features that exist today

- Horizontal tab strip with drag reordering, pinned tabs, session restore
- Find in page, zoom, print, bookmarks bar, downloads indicator
- Private browsing, per-site permissions, clear-on-quit
- Memory saver with user-controlled idle and live-tab limits
- Built-in AI: provider websites (ChatGPT, Claude, Gemini, Grok) plus optional
  BYOK API access for all four, keys in the macOS keychain
- Password vault: explicit save, keychain storage, fill only after a choice,
  never auto-submits
- The import guide detects Chrome, Brave, Edge, Vivaldi, Arc, Dia, Helium,
  Opera, Chromium, Firefox, and Safari. It previews bookmarks, history,
  Chromium-family passwords, and cookies per profile. Direct source-key reads
  disallow authentication UI: inaccessible browser keys require CSV password
  export/import, not a bypass of macOS authorization. Cookies can carry account
  access and are off by default. Chromium-family default search engines are
  imported when selected. Password CSV from browsers, Apple Passwords, 1Password,
  Bitwarden, LastPass, and Dashlane can be mapped and imported into Keychain.
  Direct Firefox password decryption is not yet supported. Site storage does
  not transfer; detected Chromium extensions require a separate, confirmed
  reinstall and start disabled.
- Quick search-engine switching from the address bar, plus `!g` / `!d` / `!b` /
  `!br` one-off prefixes
- Address-bar suggestions from local history and bookmarks only

## Platform and distribution

- macOS 14 or newer, Apple silicon and Intel
- WebKit, Swift 6, SwiftUI and AppKit
- Release path: Terminal installer + DMG. Preview releases are ad-hoc signed
  (checksum-, signature-, and bundle-verified, not notarized); Developer ID
  signing, notarization, and Sparkle updates resume once signing credentials
  are available
- Local development runs ad-hoc signed, which is why the WebCrypto keychain
  prompt can appear during development. Signed, notarized builds do not show
  it for end users

## Voice

Plain, specific, unhurried. States limits as readily as capabilities. Never
markets a benchmark it has not measured. Sentence case. No exclamation marks.

## Assumptions (labelled)

- **Domain:** the landing page is written for a `browsemium.app` style domain,
  but every link is relative or points at GitHub, so it works anywhere.
- **Download target:** GitHub Releases for this repository, because that is
  where release builds are published.
- **Audience device:** the page is read on the same Mac the browser runs on,
  often in a wide window; it is still fully responsive for sharing.
