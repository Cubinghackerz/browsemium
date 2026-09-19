# Browsemium — Product Context

Written for the Impeccable skill. Everything here is drawn from the working
brief and the shipped code; assumptions are labelled.

## What it is

A native macOS browser for people who use AI all day. WebKit-based, built in
Swift, distributed as a signed and notarized DMG.

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
- **No account, no telemetry, no cloud sync.** Browsing data stays on the Mac.
- **No autonomous AI.** The assistant never clicks, types, or submits. Page
  text, selection, and screenshots are captured only on request and reviewed in
  a sheet before anything is sent.
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
- Import from Chrome, Brave, Edge, Vivaldi, Arc, Chromium, Firefox, and Safari:
  bookmarks, history, reading list, default search engine, and Chromium-family
  passwords. Passwords from Firefox and Safari are not importable, and the app
  says why.
- Quick search-engine switching from the address bar, plus `!g` / `!d` / `!b` /
  `!br` one-off prefixes
- Address-bar suggestions from local history and bookmarks only

## Platform and distribution

- macOS 14 or newer, Apple silicon and Intel
- WebKit, Swift 6, SwiftUI and AppKit
- Release path: Developer ID signing, notarization, DMG, Sparkle updates
- Local development runs ad-hoc signed, which is why the WebCrypto keychain
  prompt can appear during development and never for end users

## Voice

Plain, specific, unhurried. States limits as readily as capabilities. Never
markets a benchmark it has not measured. Sentence case. No exclamation marks.

## Assumptions (labelled)

- **Domain:** the landing page is written for a `browsemium.app` style domain,
  but every link is relative or points at GitHub, so it works anywhere.
- **Download target:** GitHub Releases for this repository, because that is
  where the signed build will be published.
- **Audience device:** the page is read on the same Mac the browser runs on,
  often in a wide window; it is still fully responsive for sharing.
