# Browsemium Megaplan — Non-Chromium Competitive Research & Roadmap

Deep research on every non-Chromium browser architecturally comparable to
Browsemium, distilled into a phased roadmap. Scope: the WebKit edition; the
Chromium/CEF edition stays parked. Written September 2026; update as phases
ship.

## What "best" means here

Be the browser that is simultaneously: native and open-architecture,
agent-ready (scriptable, MCP-aware), privacy-absolute (no account, no
telemetry, local-first AI), and honest about what it cannot measure. Every
competitor trades one of these away; we trade none.

## Competitive research

### Cohort A — same architecture (native Swift/SwiftUI + WKWebView, macOS)

**Orion (Kagi)** — the incumbent WebKit challenger.
- ~70% of WebExtensions APIs hand-ported over years; runs many Chrome +
  Firefox extensions; per-site extension permissions beyond Chrome/Firefox.
- Zero telemetry, built-in blocker, Focus Mode, Low Power Mode (~90% power
  cut), native vertical/tree tabs, per-site settings gear with compatibility
  mode, on-page Kagi Translate, iCloud sync.
- Lesson: extensions + per-site controls are what power users cite. Their
  extension effort is now partially commoditized by `WKWebExtension` (below).

**SigmaOS** — commercial WebKit+SwiftUI.
- Workspaces with separate cookie stores per workspace; private workspaces;
  Lazy Search command bar; command-hover link preview; Magic Rename; Airis AI
  (chat-with-page, interactive summaries, multi-page "Look it up", saved
  prompts); claims Chromium extension support; subscription-gated AI.
- Lesson: the AI features users pay for — summarize, multi-tab context,
  search-and-synthesize — fit inside our review-before-send contract.

**Nook** — GPL-3, Swift 6 strict concurrency; closest to our target state.
- Sidebar-first vertical tabs; extensions via `WKWebExtensionController`
  (MV2+MV3; `.zip`/`.crx`/unpacked/`.appex`); profiles with isolated
  `WKWebsiteDataStore`s; split view; command palette; AI chat
  (Gemini/OpenRouter/Ollama); link-hover preview; Arc/Safari/Dia import;
  macOS 15.5 floor.
- Worth copying: ~30 feature managers via `@Environment`; tab web-view
  configs derived from one shared configuration so the extension controller
  reaches every view.

**Refrax** — solo dev, maximalist, macOS 26-only.
- Vertical tabs; spaces lockable behind Touch ID; natural-language command
  palette; `refrax-ctl` headless CLI scripting the whole browser; built-in
  MCP server so an agent can browse beside the user; `CAPortalLayer` same
  page in two windows; SwiftData; Liquid Glass.
- Lesson: CLI + MCP is the agent-readiness play — on-brand for "a browser for
  people who use AI all day," and compatible with no-autonomy (explicit
  commands, never silent acting).

**Chord** — nearly identical architecture to BrowsemiumKit.
- `ChordCore` value types / `ChordPersistence` (GRDB) / `ChordEngine`
  (only module importing WebKit) / `ChordExtensions` (`WKWebExtension` host
  + `.crx` unpack + signature stamping) / `ChordCrypto` / `ChordStore` /
  `ChordUI`. macOS 15.4 floor because of `WKWebExtension`.
- Caveat they documented: `WKWebExtension` caps blocking rules (~50k) and
  offers no request interception or scriptlet injection — our first-party
  `WKContentRuleList` blocker stays necessary. That ceiling still holds in
  2026: Helium's default ad, tracker, cookie, and fingerprint blocking is
  Chromium request interception, which WKWebView cannot match.

**Ora** — GPL-3 SwiftUI/AppKit/WebKit; same toolchain (xcodegen, Sparkle).
- Ships spaces, vertical tabs, tab cleanup, iCloud Keychain autofill;
  roadmap: split view, passkeys, folders, extension beta.
- Reusable dependency: `SafariConverterLib`/`ContentBlockerConverter`
  converts ABP/AdGuard filter lists to `WKContentRuleList` at runtime —
  enables user-supplied filter lists.

Also surveyed: Candoa, webstack (the indie cohort converges on sidebar +
spaces), NeChrome (deliberately minimal — the anti-position).

**The 2025–26 WebKit micro-browser wave** (same architecture, shipped or
announced within months of each other — the field Browsemium must top):

**Search** (Office Commun, Paris) — the most finished of the three.
- ~3.2 MB, WebKit only, Apple silicon, macOS 14+, free, no account, open
  source (`driceroland/Search`). Advertised cold launch ~320 ms; ~51 MB idle.
- Pinned tabs that survive force-quit; network-level blocking
  (`WKContentRuleList`); per-site "hide this element" (⌘⇧H); reading mode;
  PiP video; Keychain passwords with Touch ID; import from Chrome/Dia/Arc;
  Spaces; Chrome Web Store extensions (15.4+); private windows; Web
  Inspector. Everything local; no sync; no telemetry beyond a version check.
- Lesson: radical minimalism + honest numbers is a real position. Their
  per-site element hiding is the one feature they ship that we lack.

**Athas Browser** (team behind the Athas editor) — 2.4 MB, SwiftUI + WebKit,
~1,900 lines, zero dependencies. Bookmarks bar, tab previews, vertical tabs.
A polished shell, not a daily driver yet.

**Dio** (EGOIST) — a Dia alternative in pure Swift + WebKit, claims Chrome
extension support; demo video, release "next month", possibly open source.

**Big-player context that shapes expectations:**
- **Dia** (The Browser Company) — chat sidebar with full context (every tab,
  history, logged-in sites), a skills gallery of shareable prompts, inline
  editing, natural-language address bar. The AI-native bar users now compare
  against — and its full-context model is exactly the privacy trade we reject.
- **ChatGPT Atlas** (OpenAI) — agent mode + browser memories. **Deprecated:
  stops working August 2026**, agentic browsing moves into the ChatGPT app.
  Proof that an AI browser can strand its users; a durable, local-first
  browser is the counter-position.
- **Arc Search 2.0** — Browse For Me (multi-hop research synthesis),
  Instant Answers with source cards, Zero UI mode. Sets the mobile AI-search
  bar.

**How Browsemium tops this wave while staying unique:** every one of these
ships a subset of what Browsemium already has (spaces, folders, peek, split
view, palette, extension host + CWS beta, review-gated AI, locked spaces,
real private mode). The differentiators to press: (1) privacy-first AI —
review-gated, BYOK, local-capable, no account, vs Dia/Atlas full-context
cloud; (2) honest engineering — measured launch/memory numbers, no invented claims;
(3) durability — no account, no telemetry, no dependency on a vendor's
browser strategy. Build Mode (an in-browser coding agent) and a later ACP
agent chat both shipped, were verified, and were then removed by owner
decision — they are not current differentiators. Gaps worth closing to match Search: per-site element
hiding (⌘⇧H), import from other browsers, Web Inspector in debug builds.

### Cohort B — Gecko challengers (different engine, same users)

**Zen** (Firefox fork) — minimal patching + manager-pattern modules.
- Glance (peek overlay on links; promote/split/close), split view (up to 4
  tabs, grid), Workspaces with domain→space routing rules, Essentials
  (super-pinned tabs), folders, compact mode, mods store.
- Lesson: Glance is the most-loved single feature in this cohort;
  domain→space routing is cheap automation on our existing space model.

**Firefox** — shipped vertical tabs, tab groups, sidebar AI chatbot, and
on-device smart tab grouping. Sidebar + AI panel are now table stakes.

### Cohort C — independent engines

**Ladybird** — from-scratch engine (LibWeb/LibJS/LibWasm), 501(c)(3),
multi-process (WebContent per tab, RequestServer, ImageDecoder), alpha
targeted 2026; abandoned Swift adoption in 2025. **Servo** — embedding API
maturing, still a research engine. Revisit at Ladybird alpha via the
`BrowserEngine` seam; nothing actionable now.

### Cohort D — the AI-native UX bar (Chromium, defines expectations)

**Dia** — chat on any page; @-mention tabs as context; Skills (shareable
saved prompt+workflow gallery); inline writing assistance. Our private,
local-capable, no-autonomy version of the same surface is the differentiator.

### The biggest single finding

`WKWebExtension`/`WKWebExtensionController` is public since macOS 15.4
(content-script injection 15.5+), built by Apple for third-party browsers,
loading MV2+MV3 from zip/crx/unpacked/appex. Nook, Chord, and Zer0 ship it.
Orion's multi-year port is no longer the entry fee. Caveats: no request
interception, no `chrome.debugger`, ~50k declarativeNetRequest cap.

### What current browsers actually ship, and what WebKit can match

Checked September 2026 against primary docs, not marketing pages.

- **Helium** blocks ads, trackers, cookie banners, and third-party cookies
  by default, plus fingerprint tampering, HTTPS enforcement, and passkeys.
  That blocking is Chromium network interception. A WKWebView app cannot
  copy it. The honest WebKit equivalent is compiled content rules, WebKit
  tracking prevention, and the signals below.
- **Zen** is a Firefox fork: workspaces, compact mode, glance, split view.
  Those UX pieces are already shipped here. Its tracking protection is
  Gecko's, not portable.
- **Dia** is an AI-first Chromium browser with memory and encrypted sync.
  That full-context cloud model is the privacy trade this product rejects.
- **Passkeys are not implemented.** Apple's browser API is
  `ASAuthorizationWebBrowserPlatformPublicKeyCredentialProvider` (macOS
  13.5+), used with the web-browser entitlement. It is not the same as
  `ASAuthorizationPlatformPublicKeyCredentialProvider`, which is for an
  app's own passkeys. Embedded WKWebViews only get passkeys for associated
  domains, so a general browser cannot promise site passkeys until that
  path is proven. The Chromium edition has a separate DevTools WebAuthn
  path. Neither is shipped.
- **macOS 26.4** adds `WKWebpagePreferences.securityRestrictionMode`.
  `.maximizeCompatibility` disables the JavaScript JIT and widens memory
  tagging. **macOS 27** adds `globalPrivacyControlEnabled` (`Sec-GPC: 1`
  and `navigator.globalPrivacyControl`) and `alternateRequest`, which can
  rewrite a navigation without a second load. This machine is macOS 26.6,
  so Strict uses the reload fallback for HTTPS and cannot send GPC yet.

## Gap analysis

Strengths to keep: `BrowserEngine` seam (`BrowserRuntimeController`,
`WebViewFactory` single config point); memory saver with real signals
(`TabSleepPolicy` + audio/capture/download/keep-awake); honest metrics +
benchmark gate; review-before-send AI (web panels + BYOK + local Ollama);
8-browser importer; spaces; per-profile isolated data stores; sandboxed
WebKit edition; Swift 6 strict-concurrency layering that matches
best-in-class.

Gaps, ranked by leverage:

1. No extensions — `WKWebExtension` now makes this attainable.
2. No sidebar/vertical tabs, tab folders, peek, or split view (`PaneID`
   already exists in the engine).
3. No automation surface — no CLI, MCP, URL scheme, or AppleScript.
4. AI dock lacks @-tab context, saved skills, inline writing assist,
   multi-tab summarization.
5. Content blocking limited to the generated starter list — no
   user-supplied lists.
6. No per-site settings surface, translation, or lockable spaces.

## Roadmap

### Phase 1 — Arc/Zen-class UX parity — SHIPPED

- Opt-in vertical tab sidebar hosting the spaces switcher; horizontal strip
  stays default. New `Browser/TabSidebar.swift`; `tabStripOrientation`
  setting; reuses `moveTab`, lifecycle badges, `keepAwake`. ✅
- Tab folders/groups: `BrowserTab.folderID` + `folders` table (schema v5),
  collapse/expand, move-in/out, pin-clears-folder, empty folders dissolve,
  folder chips in the top strip, sections in the sidebar. ✅
- Peek overlay (Glance): ⌘-click a link (or a `target=_blank` link) → live
  overlay preview; promote to tab, promote into split, or close with Esc.
  The preview never touches session persistence or history. ✅
- Split view: per-window panes over the existing `PaneID`/`activePanes`
  engine support; 2–4 panes, click-to-focus, per-pane close, splits collapse
  on space switch; not persisted (tabs are, tiling is not). ✅
- Command palette v2: `FuzzyMatcher` in Core; tabs, history, bookmarks,
  commands, and intent rows (switch space, move tab to space/folder, split,
  open URL/search) in one ⌘K field, arrow-key navigable. ✅

Not yet done from the original Phase 1 sketch: optional local-LLM intent
parsing via the Ollama adapter (deferred to Phase 3, where the AI depth
work lands).

### Phase 2 — Extensions via WKWebExtension — CORE SHIPPED

Decision: availability-gate on macOS 15.4+ (keep the 14.0 floor). ✅

- New `BrowsemiumExtensions` module: `ExtensionStore` (installs unpacked
  folders, `.zip` via WebKit's archive loading, `.crx` with the container
  header stripped, and `.appex` bundles, under
  `Application Support/Browsemium/Extensions`), `ExtensionHost` (one
  `WKWebExtensionController` per profile, keyed to the profile's data-store
  identifier), and the `ExtensionHostBridging` protocol so extension
  `tabs.*` calls take the same path as user clicks. ✅
- `WebViewFactory.extensionController` is the single attach point: every web
  view the engine builds carries the profile's controller. ✅
- Per-profile registry: `extensions` table (profile schema v6) +
  `ExtensionRepository`; enablement is profile-scoped, reinstall keeps the
  user's choice, load errors are stored for Settings to show. ✅
- Delegate coverage: open windows, focused window, new tab (new *windows*
  are refused with a clear error), options page as a tab, and permission
  prompts for API permissions and host access — answered through the
  in-app `ExtensionPermissionCard`, never auto-granted. ✅
- Settings → Extensions: install (folder/zip/crx/appex), per-extension
  enable toggle, remove, error display, and an honest note about the
  limits below. ✅
- Tests: 17 store/manifest/CRX unit tests, 5 registry tests, and 10
  integration tests including a real WebKit load round-trip, a broken
  manifest surfacing its error, per-profile isolation, permission-prompt
  suspension, and the tab bridge. ✅

Still open in this phase:

- Toolbar action host (`WKWebExtensionAction` buttons + popovers) — the
  delegate hooks exist; the chrome does not.
- Per-site extension toggles.
- User-supplied filter lists via `ContentBlockerConverter`; the licence gate
  in `AGENTS.md` still applies to *bundled* lists.
- Honest copy already in Settings: no request interception (first-party
  blocking stays on `WKContentRuleList`), no devtools APIs, no action
  popovers yet.

### Phase 3 — AI-native depth (inside the no-autonomy contract) — PART SHIPPED

- Multi-tab context: `captureTabsForAI` reads readable text from each live
  tab the user picks (hibernated tabs are skipped with a status note, never
  woken silently); the dock carries one readable page per URL, and the
  review sheet still gates the send. "AI: Summarize Open Tabs" is a palette
  intent and a dock menu item. ✅
- Saved skills: `AISkill` + `ai_skills` table (profile schema v7), save from
  the composer, run from the palette ("Run Skill: …") or the dock menu,
  delete from the dock. Local-only; nothing is sent until the user sends. ✅
- Inline writing assist: rewrite / shorten / bullets quick actions that
  capture the selection and stage the prompt. The output is text in the
  transcript for the user to copy — Browsemium never types into a page. ✅
- Tests: 12 assistant-depth tests including the multi-page attachment rules
  and the skill round-trip. ✅

Still open in this phase:

- `browsemium-ctl` CLI + opt-in localhost MCP server (token-authed, off by
  default, read + explicit commands only) — the Refrax-style agent surface.
- Skills import/export as markdown.

### Phase 4 — Performance & privacy leadership — PART SHIPPED

- Private browsing is real: `BrowserEngine.setPrivateBrowsing` switches the
  engine to ephemeral web views, and a mode switch drops every web view so a
  persistent one is never reused in private mode. ✅
- **Incognito windows shipped**: ⇧⌘N / toolbar mask button / ⌘K opens a
  private window that is private from its first frame — one "Private" space,
  ephemeral WebKit store, no history, no closed-tab records, no session
  snapshot, no warm-tab preloading, no history in the address-bar
  suggestions, and **extensions never inject into ephemeral views** (the
  factory attaches the extension controller only on persistent stores). The
  toolbar shows an unmistakable Private badge, and the private New Tab page
  states plainly what is protected and what is not (IP/ISP visibility,
  downloads, deliberate bookmarks). ✅
- Locked spaces: `BrowserSpace.isLocked` (profile schema v8), Touch ID /
  login-password gate on `switchGroup` via `LocalAuthentication`, launch
  never opens a locked space, locked spaces' tabs stay out of ⌘K, "Lock Now"
  re-locks, and locking the last unlocked space is refused. The copy is
  honest: the lock protects the window, not the disk. ✅
- `selectTab` now switches spaces instead of showing another space's tab
  (a pre-existing cross-space leak, fixed while adding the lock). ✅

Still open in this phase:

- Per-space cookie isolation (`WKWebsiteDataStore` per space).
- On-device translation (`Translation` framework).
- Per-site compatibility mode (disable blocking for a site — Orion's gear).
- Per-site element hiding (⌘⇧H) — the one Search feature we lack.
- The 20% memory gate still needs a release-time run; no comparative claim
  may be published before it passes.
- Third-party cookie blocking and fingerprint resistance at Helium's level.
  WKWebView cannot intercept requests. Do not claim that parity.
- Passkeys. See the research note above. A spike, not a stub.

### Phase 4.6 — Protection levels that do something — SHIPPED (WebKit)

`ProtectionLevel` was a stored setting with no effect, shown in Settings
and onboarding. It is now the only blocking switch.

- **Off** runs no bundled content rules. WebKit tracking prevention stays on.
- **Balanced** runs the bundled content rules. This is the default.
- **Strict** keeps the rules, upgrades main-frame `http` navigations to
  `https` (not localhost, not a non-standard port), and on macOS 26.4+
  sets `securityRestrictionMode` to `.maximizeCompatibility`. On macOS 27+
  it also sets `globalPrivacyControlEnabled`. Below 27, HTTPS upgrade
  cancels and reloads; `alternateRequest` is used when the OS has it.
- A saved `contentBlockingEnabled: false` decodes as Off, even when the
  unused protection picker was set to something else, because that toggle
  was the control that actually worked. The dead `remoteSearchSuggestions`
  field is no longer written.
- Turning protection off removes rules from tabs that are already open, and
  a protection change drops the warm spare so the next tab is not created
  under the old level.
- Settings and first-run copy name only the behaviors this macOS version
  can actually perform.

Not in this phase: the Chromium edition's `apply` still does not enforce
the level. Downloads and subframe loads are not rewritten. Passkeys remain
unshipped.

### Phase 4.7 — Site shield and on-device translation — SHIPPED (WebKit)

- A toolbar shield shows the current site, the protection level, and whether
  bundled rules are on. No blocked-count.
- **Pause blocking on this site** is a site preference. It removes the
  compiled rule list from that tab and reloads. Another host is unaffected.
  Navigating away restores the rules. A private window does not remember it.
- The same panel keeps per-site Reader and zoom.
- **Translate page** extracts the article and translates it on this Mac into
  Reader, using Apple's translation session so a missing language can use
  the system download prompt. It needs macOS 15. The original page is not
  rewritten.

### Phase 4.5 — Build Mode — REMOVED

Build Mode shipped: a coding-agent panel (View → Build Mode) where the model
wrote files and an ephemeral WebKit view previewed them, with BYOK providers
plus Vercel v0, and a strict fenced-file output contract. It was then removed.
An ACP agent chat (Claude Code, Codex, Gemini CLI, and others, with streaming
transcripts and explicit permission prompts) was built afterwards, fully
test-verified, and removed by owner decision — the ACP client went with it.
Do not treat either as a current feature. The assistant dock (review-gated,
no autonomy) is the AI surface that remains.

### Quality-of-life batch — SHIPPED

- **Tab hover previews**: the hover card (top strip + sidebar) now shows a
  real snapshot of the tab's live page via `pageScreenshot`, with state,
  folder, audio, and the honest memory figures. Sleeping tabs say so
  instead of faking a thumbnail. ✅
- **Link previews**: the status bar grew into a link card (favicon, host,
  full URL, "⌘-click to preview"), plus an opt-in **hover peek**
  (`linkPreviewOnHover`, default off — hovering must not become a network
  request): rest the pointer on a link ~700 ms and the peek overlay opens;
  it never replaces an open peek and refuses non-page schemes. ✅
- **Tab commands**: Duplicate Tab, Copy Link (⇧⌘C), Close Other Tabs, Close
  Tabs to the Right/Below (shared `TabMenuContent` so strip and sidebar
  never drift), ⌘1–9 strip selection, ⌃⇥/⌃⇧⇥ cycling, all in the context
  menus, the Tabs menu, and ⌘K. ✅

### Phase 5 — Distribution & trust

Current distribution state (2.1.0): **command-first preview.** The Terminal
installer is the only promoted install path; preview builds are ad-hoc signed
and not notarized, and every public surface says so. The installer checks the
release manifest (`Site/release.json`: version, filename, SHA-256, signing
mode), DMG integrity, the app signature, bundle id and version, the sandbox
entitlement, absence of `get-task-allow`, and both architectures — and keeps
the existing Developer ID / notarization checks for when the manifest flips
to `notarized`. It never removes quarantine attributes or bypasses
Gatekeeper. Sparkle, the Homebrew cask, and direct-DMG promotion stay off
until signing credentials exist.

- Keep `MEGAPLAN.md` and release notes current. Keep refusing: accounts,
  telemetry, autonomous agents, invented metrics.
- Remaining milestone: Developer ID signing + notarization, then re-enable
  Sparkle updates and the Homebrew cask (the CI release workflow already
  encodes that path).

### 2.2 — Per-site element hiding — SHIPPED

- `⌘⇧H` enters element-selection mode: the page draws a highlight and a
  tag/id/class badge under the pointer; a click reports a selector that was
  verified against the live document (unique id, else an exact child path),
  and the site shield panel asks for confirmation before saving. Esc cancels.
- Cosmetic rules persist scoped to the hostname, per profile
  (`cosmetic_rules` table, profile schema v10); the whole host→CSS map is
  injected at document start, so matching happens in the page and a rule
  change never rebuilds per-navigation state.
- Rule changes update the open page in place — no reload — and the site
  shield lists each rule with an enable toggle and a "show again" undo.
- Private windows can hide elements but never persist the rules; they live
  for the window's lifetime only.
- The picker is WebKit-only: the Chromium edition keeps the engine default
  (a no-op), listed with the other CEF gaps in AGENTS.md.

### 2.3 — Smart space routing — NEXT

- Route domains (e.g. github.com, company tools) into a chosen space.
- Configure rules from the tab context menu and Settings.
- Never route private-window navigation; never silently unlock a locked
  space — the user is asked.
- A reversible notice appears when a navigation moves to another space.

### 2.4 — Advanced blocking controls — NEXT

- Import user-selected ABP/AdGuard lists from a local file or HTTPS source.
- Lists compile in the background; on failure the last working version stays
  active and the error is shown.
- Report compilation state honestly — no blocked-request counts (WebKit does
  not expose them).
- Per-site extension enablement alongside the existing host-permission
  controls.

### Later

- Markdown import/export for saved AI skills.
- Opt-in `browsemium-ctl` CLI and token-authenticated localhost MCP, scoped to
  reads and explicit user commands.
- Research spikes for passkeys and per-space WebKit data isolation before
  either is promised publicly.
- The corrected memory benchmark stays a release gate: no comparative claim
  until the 20% target passes.

## Verification

- `BROWSEMIUM_HEADLESS=1 swift build/test` on `Packages/BrowsemiumKit` stays
  green; full `swift test` + `xcodebuild -scheme Browsemium` under Xcode.
- UI/snapshot tests per feature; extensions tested with a known MV3 blocker
  and a content-script extension; CLI/MCP round-trip in a test harness.
- `Benchmarks/benchmark-memory.sh` ≥20% vs Chrome after each phase.
- No UI claims a number the engine cannot verify.
