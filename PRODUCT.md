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
  state and distinct named-host list sizes, including exception rules. These
  describe installed lists, not requests — WebKit does not expose blocked-request
  counts, so Browsemium never shows a number it cannot verify.

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
  Chromium-family passwords, and cookies per profile. A browser's encryption key
  is read only when you press Import on a selection that needs it: silently
  first, and if it is locked, only after you press Continue on an in-sheet
  consent card, which lets macOS show its own authorization prompt once per
  browser. The key is held in memory for that import and never stored. If you
  decline or macOS refuses, passwords and cookies are left out, everything else
  still imports, and a password CSV can add the passwords. Nothing reads the key
  while a preview is built or Settings is open. Cookies can carry account
  access and are off by default. Chromium-family default search engines are
  imported when selected. Password CSV from browsers, Apple Passwords, 1Password,
  Bitwarden, LastPass, and Dashlane can be mapped and imported into Keychain.
  Firefox passwords decrypt directly when no Primary Password is set; a
  Primary Password or a legacy key3.db profile is reported as unsupported.
  Site storage does not transfer; detected Chromium extensions require a separate, confirmed
  reinstall and start disabled.
- Site routing: send a site to a space; the tab moves with a notice and Undo,
  and a locked space asks before anything moves into it
- Separate groups: a group can keep its own cookies and logins, so one site can
  hold two accounts. History, bookmarks and saved passwords stay shared, and
  extensions do not run in these groups
- Page tweaks: your own CSS per site, with a live preview; CSS that could load
  anything from the network is refused
- Tracking-parameter removal from links you open (not on sign-in addresses)
- On-device assistant: Apple Intelligence runs on this Mac with no key; long pages
  are read in sections
- Tab-group suggestions and duplicate closing, previewed before anything changes
- Page watch: told when a public page changes, only while Browsemium is open; it
  loads pages without your cookies and keeps a fingerprint, not the text
- Auto-archive for tabs you have not used (off by default)
- Address-bar calculations and unit conversions, answered locally
- `browsemium://` links, Shortcuts actions and `browsemium-ctl` can open a page,
  search or switch space and nothing else
- Offer to save a password after a sign-in (explicit Save; filled only when you choose)
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

## External agent automation (opt-in preview)

Task-scoped external MCP automation, per
`Plans/7-polished-autonomous-workspace.md`, is implemented as an opt-in preview
that is off by default. A connected client that supports Streamable HTTP MCP
with custom headers works in task-owned tabs under a temporary, explicit grant.
You can Stop it at any time, and each click and each typed value needs your
separate confirmation. Task pages share your profile's browsing data and open
in a separate panel, not a sidebar space. It does not add a built-in autonomous
assistant, accounts or a cloud service, and the AI dock still never operates
pages. Not yet verified: use from the packaged app with a live client, and
native keyboard/VoiceOver checks.

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
