# Plan 8 — Landscape-informed upgrade (October 2026)

Status: owner approved 2026-10-04 with sync permanently off. Units are marked
shipped in this file only when implemented and verified; a unit that cannot be
enforced or measured stays open with the reason recorded.

## Status — 2026-10-04 (executed)

Verified with the package suite, headless runner, `xcodebuild` build and test,
and `Scripts/verify-project.sh`. Nothing is committed and the app was never
launched; every "shipped" below means implemented and covered by automated
tests, not native-QA'd. Release claims are unchanged.

| Unit | State | Notes |
|---|---|---|
| A1 landscape record | done | this file, `MEGAPLAN.md` |
| A2 memory gate | **not run** | needs a quiet machine and launching the app |
| A3 smart space routing | done | matcher, repository, coordinator, notice with Undo, Settings, tab menu |
| A3 filter-list QA, extension site controls, import completion | **partly** | extension site controls done (spike passed, see `Plans/2.4-extension-site-controls.md`): profile migration v17 `extension_site_policies`, pure policy + repository, host wiring with denial winning over grants/activeTab/prompts, Settings + site-shield Allow/Ask/Deny with reload note, 19 tests + 4 renders. Import completion units 2–3 done and covered by generated-fixture tests: session/pinned tabs (Firefox LZ4 recovery, Safari plist, idempotent reopen, never private) and Firefox passwords (CommonCrypto 3DES + PBES2/AES unwrap, honest protected/unsupported/corrupt classification, secret-free reports). Filter-list QA unchanged and still open; native QA and real-Firefox confirmation remain open |
| B1 Inspect | done | `isInspectable` plus WebKit's internal `developerExtrasEnabled`/`_inspector`, probed on macOS 27: the inspector opens, including on a live view |
| B1 `willSubmitForm` | **dropped** | the callback never fired in any configuration tried (JS click, `requestSubmit`, `submit`, loopback server). Replaced by an isolated-world script that reads field types, which also works below macOS 27 |
| B1 `cookies(for:)` | not adopted | nothing in the code scans cookie stores |
| B2 tracking parameters | done | allowlist only; sign-in URLs never touched; verified in real WebKit |
| B3 `browsemium://`, App Intents, `browsemium-ctl` | done | build output contains 5 actions and 2 entities; Shortcuts runtime is manual QA |
| B3 AppleScript | **skipped** | spike inconclusive, so no `Browsemium.sdef` ships. On 2026-10-05 a throwaway sandboxed ad-hoc bundle (not Browsemium; `Scripts/spikes/apple-events/`) accepted `open location` over Apple events and returned a result, so a sandboxed app does receive events. A read-only property (`get tab titles`) then timed out (-1712) with an sdef that lacked the Cocoa standard suite, and `xmllint --dtdvalid` reported that sdef as invalid. The rerun with the standard suite was not done (the owner asked for no further app launches). Finish with `bash Scripts/spikes/apple-events/run.sh`; if the read works and the dictionary validates, add `open location`, `search` and read-only `tabs` through `AppAutomation` |
| B4 Spotlight, Handoff | done | both opt-in, default off, Settings → General → Spotlight & Handoff. Spotlight: bookmark title + address only through `CSSearchableIndex`; eligibility fixed at save time (migration v19: never from a private window, locked space or separate-data space), one clearable domain, resync on setting/bookmark/profile change, nothing sent when unchanged, results resolve by bookmark id and open through `newTab`. Handoff: `NSUserActivityTypeBrowsingWeb` for the active tab's https URL (fragment dropped, query kept), never private/locked/separate-data, never searchable or public; incoming web activities open only plain https and only while on. Covered by 19 tests; the real Spotlight index, Handoff delivery and result opening have not been exercised (needs launching the app and a second device) |
| C1 Apple Intelligence provider | done | ran against the real on-device model: a long page was read in sections and answered correctly |
| C2 tab groups, duplicates | done | suggestion-only; same-site fallback when the model is unavailable |
| C3 history ranking | done | address-bar suggestions rank by bm25, visit count and recency, one row per page |
| C3 text index, resume topics | done | opt-in FTS5 page-text index (migration v18, 4 KB snippets, default off, unencrypted copy disclosed): after-load capture for eligible pages only — never private, locked, separate-data, or credentialed; per-site exclude with purge, visible size, Clear, history-retention and clear-data interplay. Page-text rows in address suggestions and palette. Resume topics on new tab from NLContextualEmbedding clusters (threshold calibrated on-device 0.85, term-overlap fallback, n-gram labels, max 3), one click reopens. Covered by unit, model, and render tests |
| C4 page watch | done | https only, no cookies, only while open, stores hashes not text |
| D1 CSS tweaks | done | validator refuses every network-loading construct, including escaped spellings |
| D1 "Describe a tweak" | done | on-device only: sends the page's tag/id/class outline (no text, verified in real WebKit) to Apple Intelligence; output is previewed and still validated on save |
| D1 JS tweaks | not done | |
| D2 containers | done | no extension injection in containers; real-WebKit test shows two containers do not share a login |
| D3 quick answers | done | |
| D4 auto-archive | done | off by default |
| E1 finish Plan 7 | **partly** | done and tested without launching the app: Take over / Hand back / Stop (Stop works while paused), key equivalents, labels, hints and VoiceOver announcements, gate tests for takeover in flight, Stop and expiry during takeover, a real `URLSession` loopback test, entitlement pin. Still open: launching the packaged app, a live MCP client session, and keyboard/VoiceOver QA (owner checklist in `Plans/7-polished-autonomous-workspace.md`) |
| E2 injection suite | done | `Plans/8-injection-controls.md` |
| E3 WebMCP bridge | done | experimental, off by default, task tabs only (never the person's tabs): `webmcp` grant, MCP `browsemium_page_tool_list`/`_call`, per-call native confirmation with exact arguments, small schema check, untrusted envelope, 56 parametrized injection cases over the fourteen vectors. WebKit position confirmed `oppose` against the repository (issue 670). Verified in real WebKit; no live MCP client or live WebMCP site has been tried. Plan deviations are listed in `Plans/8-injection-controls.md` |
| F1 launch benchmark | **partly** | `Benchmarks/benchmark-launch.sh` and `Benchmarks/parse-launch-metrics.py` written (median and p90 per `LaunchMetrics` milestone, refuses while other WebKit apps or Browsemium run, INVALID unless every trial reaches first-frame and idle), runbook in `AGENTS.md`, parsing covered by 25 tests in `Scripts/tests/launch-benchmark/` run in CI. No number has been measured: the app was never launched for this, and it is not a cold-launch figure (milliseconds since the app's first mark, warm file cache). Owner run and the blank memory-gate template are in `QUALITY_PASS.md` |

Passkeys, tested instead of assumed: an ad-hoc signed binary carrying
`com.apple.developer.web-browser.public-key-credential` is killed at launch
(exit 137), so the platform route cannot ship without Developer ID. An
unentitled `WKWebView` reports no platform authenticator and no conditional
mediation, so sites fall back to passwords rather than offering a broken
passkey button. The workaround shipped is the save-password offer after a
sign-in.

Bug found and fixed on the way: renaming a locked space dropped its lock.

## Context

`MEGAPLAN.md` already studies ~15 non-Chromium browsers. The ask was broader: research the top 50 browsers in the world (Chromium, Gecko, WebKit, AI-native, privacy, regional, enterprise) and learn how to make Browsemium significantly better. This file is the result: findings, a 50-browser catalogue, a code-grounded gap analysis, and an ordered, cold-executable work plan. No code is changed by this plan file.

Host facts verified 2026-10-04: **macOS 27.0.1, Xcode 27.0, Swift 6.4**. `MEGAPLAN.md` still says "this machine is macOS 26.6", which is stale. CI still builds with Xcode 26.3 / Swift 6.2.3, so every macOS 27 API must sit behind `#if compiler(>=6.4)` plus `#available(macOS 27, *)` (rule in `AGENTS.md`). Deployment floor stays macOS 14.

Constraints this plan respects, from `AGENTS.md`, `PRODUCT.md`, `MEGAPLAN.md` and `Plans/7-polished-autonomous-workspace.md`:
- No accounts, no telemetry, no cloud sync, no built-in autonomous AI.
- Ad-hoc signing only: no restricted entitlements, no CloudKit, no Sparkle, no notarization-dependent features.
- WebKit edition only; no CEF feature work.
- No claim without a measurement. Private and locked content never reaches AI, agent or an index.
- Task-scoped external MCP automation is owner-approved (Plan 7). A built-in agent loop is not.

## Method and confidence

- "Top 50" is not an official ranking. It is chosen from StatCounter share plus 2026 influence on the features people compare.
- Sources used this session: StatCounter, WebKit blog (WWDC26 and Safari 27.0), Apple Developer (Foundation Models), Chrome I/O 2026 post, Brave, Orion and Zen release notes, TechCrunch, MacRumors, 9to5Mac, Mac-specific reviews. Full list at the end.
- Primary sources: WebKit blog, Apple, Chrome. Everything else is secondary. A `†` marks catalogue entries written from background knowledge and not re-verified in this session.
- Conflicts and weak spots to re-check before relying on them:
  - Comet pricing: one source says free everywhere, TechCrunch (Jul 2026) says the $200/month Max plan.
  - Atlas shutdown date: July 2026 in one source, 9 Aug 2026 in another. Either way it is retired.
  - WebKit "opposed" on WebMCP is confirmed against `WebKit/standards-positions` issue 670 (`position: oppose`, 3 Jun 2026); Mozilla "neutral" is still unverified against its repository.
  - Foundation Models details (8,192-token window, the PCC model, `LanguageModel` protocol) come from Apple's session page via a summarizer. Confirm against the macOS 27 SDK headers.

## What the research says

1. **Concentration is extreme.** Desktop, Aug 2026: Chrome 73.3%, Edge 10.5% (down from 11.7% a year earlier), Firefox 5.3%, Safari 5.2%, Opera 2.0%, Brave ~1.2%. Challengers win on a single sharp promise, not on breadth.
2. **The AI-browser shakeout has started.** ChatGPT Atlas is retired. Arc has been in maintenance since May 2025. Dia is now an Atlassian subsidiary with cross-device sync. Opera Neon charges $19.90/month. Chrome's auto browse is limited to AI Pro/Ultra in the US. Durability and no vendor lock-in are real selling points.
3. **Agentic browsing is unsafe by default.** At Black Hat 2026 a Brave engineer showed prompt injection against Opera's AI browser, Comet and Atlas. Zenity's "PleaseFix" (Mar 2026) was a zero-click hijack of Comet-class browsers. Norton Neo now markets prompt-injection defence. The market gap is a scoped, consent-gated, auditable agent surface, which is what Plan 7 is building.
4. **Safari 27 made "agent-ready" table stakes for developers.** Safari ships a local MCP server (DOM, network, screenshots, console) behind Settings → Developer → "Allow remote automation and external agents". Chrome ships "DevTools for agents" and WebMCP (origin trial from Chrome 149). The Prompt API is stable in Chrome 148.
5. **Apple Intelligence features set the Mac baseline.** Safari 27 adds Automatic Tab Groups, Notify Me (page-change alerts), Reader summaries, "Describe an Extension" and the profile switcher in the toolbar. Most need an Apple Intelligence-capable Mac.
6. **Apple opened the on-device model to third parties.** The Foundation Models framework gives apps the system model with no key and no account. It has an 8,192-token context, vision input and tool calling. A `LanguageModel` protocol lets Anthropic/Google packages, MLX and a Private Cloud Compute model (32k context, reasoning) plug in. Browsemium has nothing here yet.
7. **Containers are the 2026 convergence.** Orion 1.1 (Jun 2026), Brave 1.92 (Jul 2026), Safari Profiles, Firefox containers and Zen workspaces all ship isolated cookie jars. Browsemium isolates per profile but spaces share one store.
8. **Per-site customization is the most loved "small" feature.** Arc Boosts, Zen mods and Vivaldi panels. Browsemium ships element hiding only.
9. **Same-engine competitors are closing in.** Orion has ~70% of the WebExtensions API plus Chrome and Firefox extensions, and is going to Linux and Windows. DuckDuckGo's Mac browser ships a free Scam Blocker and cookie-popup handling. Brave Origin (Jun 2026) shows a paid, minimal variant can sell.
10. **The Mac-native moat is unused.** The code has no App Intents, AppleScript, Handoff, Spotlight, notifications or Foundation Models (0 matches each). Chromium and Electron browsers cannot copy those cheaply. Safari will not copy them for a third-party workflow.

## Catalogue: 50 browsers

Columns: engine, what to study, what Browsemium takes. "No" means deliberately skipped.

| # | Browser (engine) | Worth studying | Browsemium take |
|---|---|---|---|
| 1 | Chrome (Blink) | Gemini side panel, auto browse, vertical tabs, split view, Prompt API, WebMCP, DevTools for agents | Agent-readiness is table stakes; local-first answer |
| 2 | Safari (WebKit) | Auto Tab Groups, Notify Me, summaries, MCP server, profiles | Local equivalents of tab groups and page watch |
| 3 | Edge (Blink) | Copilot Actions, Journeys (topic resume) | "Resume topics" computed on-device |
| 4 | Firefox (Gecko) | Smart Window beta (US/CA/FR), tab groups, vertical tabs, containers | Containers; AI stays opt-in |
| 5 | Samsung Internet (Blink) | Browsing Assist via Perplexity: natural-language history and tab help | Local history search |
| 6 | Opera One (Blink) | 4-tab split, Gemini, native blocker, workspaces | Already have split; no |
| 7 | Opera GX (Blink) | Resource limiters, panic button, Playground | Memory saver already similar; no |
| 8 | Opera Neon (Blink) | Paid agent layer ($19.90/mo) | Price is the cautionary tale; no |
| 9 | Brave (Blink) | Containers (1.92), Shields, Leo auto-model, Origin | Containers; honest shield counts |
| 10 | Vivaldi (Blink) | 8.x layout presets, address-bar calculator, PDF reader, command chains | Quick answers in the address bar |
| 11 | DuckDuckGo (WebKit on Mac†) | Scam Blocker, cookie-popup handling, Fire button | Scam warning check, tracking-parameter strip |
| 12 | Tor Browser (Gecko) | Anonymity, letterboxing | Cannot match on WKWebView; honest private-mode copy |
| 13 | Mullvad Browser (Gecko) | Standardized fingerprint | Infeasible on WKWebView; no |
| 14 | Arc (Blink) | Boosts, auto-archive, spaces; now in maintenance | Site tweaks, auto-archive; import already covers Arc users |
| 15 | Dia (Blink) | Skills, tab-aware chat, sync (1.26), Arc features returning | Skills exist; no cloud memory |
| 16 | Perplexity Comet (Blink) | Research agent, background assistants, injection incidents | Containment over autonomy |
| 17 | ChatGPT Atlas (Blink) | Retired Jul/Aug 2026 | Durability pitch |
| 18 | Zen (Gecko) | Glance, Essentials, workspaces, auto-folders from GitHub/RSS, mods | Routing rules (Plan 2.3), peek exists |
| 19 | Orion (WebKit) | 1.0 (Nov 2025), containers (1.1), extensions, Linux/Windows coming | Direct competitor; match containers and finish extensions |
| 20 | SigmaOS (WebKit) | Workspaces, command bar, AI | Parity reached |
| 21 | Helium (Blink) | Bundled uBlock Origin, fingerprint noise, hibernation, vertical tabs | Cannot intercept requests; stay honest |
| 22 | Norton Neo (Blink) | VPN, anti-phishing, agent protections | Injection suite (E2) |
| 23 | Genspark Browser (Blink) | Free on-device models (169 open-weight), MCP store | On-device provider (C1) |
| 24 | BrowserOS (Blink) | Open-source agent browser | Open MCP surface instead of built-in agent |
| 25 | Fellou (Blink) | Workflow agent; public security case study | Cautionary tale |
| 26 | Strawberry (Blink) | Skill-automation | Skills exist; no autonomy |
| 27 | Ladybird (own engine) | Alpha 2026, PR queue closed Jun 2026, WPT 2.07M | Revisit via `BrowserEngine` seam |
| 28 | Yandex Browser (Blink) | Alice AI, voice-preserving video translation (7 languages added Jul 2026) | Translation exists; video dubbing no |
| 29 | UC Browser (Blink)† | Download manager, data saver | No |
| 30 | QQ Browser (Blink)† | AI toolbox, China-market | No |
| 31 | Quark (Blink)† | Alibaba AI-first | No |
| 32 | Naver Whale (Blink) | Papago translation, built-in conferencing | Translation exists |
| 33 | Coc Coc (Blink)† | Media downloader | No |
| 34 | Floorp (Gecko)† | Vertical tabs, workspaces, PWAs | Parity |
| 35 | LibreWolf (Gecko)† | Hardened Firefox | No |
| 36 | Waterfox (Gecko)† | Privacy fork | No |
| 37 | Pale Moon (XUL fork)† | Legacy | No |
| 38 | Thorium (Blink)† | Perf-optimized builds | Only credible if benchmarked |
| 39 | Island (Blink) | Enterprise DLP, audit | No |
| 40 | Prisma Browser (Blink) | Palo Alto SASE browser | No |
| 41 | Wavebox (Blink)† | Work-app workspaces | Spaces cover it |
| 42 | Sidekick (Blink)† | Work-app sidebar | Same |
| 43 | Polypane (Blink)† | Developer multi-viewport | Inspect first (B1) |
| 44 | GNOME Web / Epiphany (WebKitGTK)† | Minimal WebKit | Anti-position |
| 45 | Native WebKit indie wave (Nook, Ora, Search, Refrax, Chord) | See `MEGAPLAN.md` | Done; keep honest numbers |
| 46 | Opera Mini (proxy)† | Data compression | No |
| 47 | Ecosia (Blink)† | Search-funded climate | No |
| 48 | Avast Secure Browser (Blink)† | Bundled suite security | No |
| 49 | Quetta (Blink) | Mobile extensions plus video saving | No |
| 50 | Opera Air (Blink) | Mindfulness shell | Tone only |

## Where Browsemium stands (code evidence, 2026-10-04)

About 50k lines of Swift across the package and tests. Ahead or at parity: spaces, folders, peek, split view, ⌘K palette, extension host (`WKWebExtension`), locked spaces, real private windows, site shield, on-device translation, element hiding, 11-browser importer, review-gated AI (BYOK and Ollama), memory saver, MCP v1 in development.

Gaps, by search of `Packages/BrowsemiumKit/Sources`:

| Gap | Evidence |
|---|---|
| No Inspect / Web Inspector | `isInspectable` 0 matches; `developerExtras` 0 |
| No macOS automation surface | `AppIntent`, `NSAppleScript`, `NSUserActivity`, `CSSearchableItem` all 0 |
| No on-device Apple model | `FoundationModels` 0; `AIProviderID` is openAI, anthropic, gemini, xAI, ollama, vercelV0 (`BrowsemiumCore/Models.swift:58`) |
| No tracking-parameter stripping | `fbclid` 0 |
| History ranking is recency only | Search already uses an FTS5 table (`history_visits_fts`); an earlier version of this table wrongly said `LIKE`. Results are ordered by time, not relevance |
| No semantic / text index | `NaturalLanguage` 0 |
| No notifications (so no page watch) | `UNUserNotification` 0 |
| No per-space cookie isolation | Spaces share the profile store; `forIdentifier` is used at profile level only |
| No passkeys, no card/address autofill | `ASAuthorization` 0, `creditCard` 0 |
| macOS 27 WebKit APIs unused | `willSubmitForm` 0, `mainFrameNavigation` 0; GPC already used (`WebViewFactory.swift:81`) |
| No reading list | `ReadingList` 0 |

## Strategy

Position: **the Mac browser for people who run agents, local-first and honest about limits.** Three pillars that Chromium browsers cannot copy cheaply, built on a "switch and stay" base:
1. **Native Mac depth:** Inspect, App Intents, AppleScript, CLI, Spotlight and Handoff (opt-in).
2. **Local-first AI:** the Apple on-device model as a key-less provider, powering tab groups, resume topics and page watch. Nothing leaves the Mac by default.
3. **Safest agent surface:** finish Plan 7, publish an injection test suite, offer a WebMCP bridge. The claim is containment, not immunity.

If only five things ship, in this order:
1. Finish the queued switchability work (filter-list QA, extension site controls, smart routing, import completion). It is the adoption gate.
2. Apple Intelligence provider plus auto tab groups (C1, C2).
3. Containers plus smart routing (D2).
4. Automation surface plus Inspect (B1, B3).
5. Plan 7 completion plus the injection suite (E1, E2).

Deliberately not chasing:
- Chromium-grade request interception and fingerprint standardization. WKWebView cannot do either; never claim it.
- Cloud sync or accounts. Enterprise DLP. A built-in autonomous agent. A paid agent tier. Mobile.
- Video downloaders and gaming shells. CEF edition work.

## Work units (execute in order)

Conventions for every unit:
- Swift 6 strict concurrency. Keep logic out of `BrowserWindowModel.swift`; add small types in the owning module.
- After adding or removing files run `xcodegen generate --spec project.yml`. Never edit `Browsemium.xcodeproj`.
- DB changes: next migration after `profile-v11-user-filter-lists` in `BrowsemiumData/AppDatabase.swift` (check for later ones first).
- New settings fields go on `BrowserSettings` (`BrowsemiumCore/PrivacyModels.swift:214`) and must decode from older saved JSON.
- Private windows and locked spaces are excluded from anything that reads page content, indexes, or exposes tabs.
- Bug fixes follow red, green, reverted-red. Update `PRODUCT.md`, `MEGAPLAN.md`, `ReleaseNotes/Unreleased.md`, `QUALITY_PASS.md` only with completed claims.
- Per unit run: headless validation, focused tests, full package tests, Xcode Debug build and test (commands under Verification).

### Wave A — foundations

**A1. Truth-up and record.** Copy "What the research says", the catalogue and the gap table into `Plans/8-landscape-2026.md`. In `MEGAPLAN.md` correct "macOS 26.6" to macOS 27.0.1/Xcode 27, add the Atlas retirement, Dia sync, containers trend, Safari 27 MCP, WebMCP and Foundation Models notes, and link Plan 8. Done when `git diff` touches only docs.

**A2. Unblock the memory gate.** The unchanged benchmark was refused because other WebKit processes ran. Quit every WebKit-based app (Safari, Mail previews, other browsers), then run:
```sh
python3 Benchmarks/generate-fixtures.py
python3 Benchmarks/serve-fixtures.py --port 8791 &
Benchmarks/benchmark-memory.sh --browsemium /Applications/Browsemium.app --chrome "/Applications/Google Chrome.app" --trials 5 --settle 60
```
Record the verdict in `QUALITY_PASS.md`. Do not change the method. If it fails, publish no comparative claim.

**A3. Existing queue, unchanged order.** User filter lists, extension site controls, smart space routing, import completion, per `Plans/2.4-*.md`, `Plans/2.3-smart-space-routing.md`, `Plans/6-import-completion.md`. No new design here.

### Wave B — native Mac depth

**B1. Inspect and macOS 27 WebKit adoption.**
- `BrowsemiumEngine/WebViewFactory.swift`: set `webView.isInspectable = true` when new setting `developerToolsEnabled` (default off) is on.
- Spike: right-click "Inspect Element" needs the private `developerExtrasEnabled` preference via KVC. Try it on macOS 27; if it fails, use the Safari Develop-menu route and say so in Settings copy. Add menu item (⌥⌘I) in `Shared/AppShell/AppShell.swift` and a palette row only after it works (MEGAPLAN: no placeholder commands).
- Adopt, each behind `#if compiler(>=6.4)` and `#available(macOS 27, *)`, confirmed against SDK headers first (`grep -r willSubmitForm "$(xcrun --show-sdk-path)/System/Library/Frameworks/WebKit.framework"`):
  - `willSubmitForm` in `WebNavigationDelegate.swift`: trigger the existing explicit "Save password?" card. Do not read or store values implicitly, do not auto-submit.
  - `WKHTTPCookieStore.cookies(for:)`: replace full cookie-store scans for per-site clearing in `PrivacyDataManager`.
- Tests in `BrowsemiumEngineTests`, gated the same way. Done when Safari's Develop menu lists a Browsemium page with the setting on, and nothing is inspectable with it off.

**B2. Tracking-parameter stripping.**
- Add pure `TrackingParameterStripper` in `BrowsemiumCore` with a fixed allowlist of known params (`utm_*`, `fbclid`, `gclid`, `dclid`, `msclkid`, `mc_eid`, `igshid`, `yclid`, `twclid`, `ttclid`, `_hsenc`, `_hsmi`). Never generic stripping. Never POST. Never `redirect_uri`/SAML/OAuth requests.
- Apply in `WebNavigationDelegate.swift` `decision(for:)` for main-frame link and typed navigations: cancel and load the cleaned URL (same reload technique the Strict HTTPS upgrade uses; `alternateRequest` on macOS 27).
- Active at Balanced and Strict, off at Off. Site-shield pause bypasses it.
- Fixtures: 30+ URLs, including OAuth lookalikes that must not change. Honest copy: removes known tracking parameters from links you open; sites can still track you other ways.
- WebKit already trims cross-site referrers, so no referrer work.

**B3. Automation surface.** Order matters.
1. `browsemium://` URL scheme with navigation-class commands only: open, search, switch space. Never AI sends, grants or deletions. Parse in a pure `AppCommandInterface` in Core using the existing `BrowserCommand` enum (`Models.swift:408`). Register in `project.yml` Info properties.
2. App Intents in `BrowsemiumApp/Intents/`: Open URL, Search, Switch Space (`AppEntity` for spaces), List Open Tabs and Current Page (exclude private and locked). Router injected through `BrowserEnvironment`.
3. AppleScript: `BrowsemiumApp/Config/Browsemium.sdef` (window, tab with url/title/space; commands `open location`, `search`), plus `NSAppleScriptEnabled` and `OSAScriptingDefinition` in Info. Spike that a sandboxed ad-hoc build accepts incoming Apple events. Exclude private and locked tabs.
4. `browsemium-ctl`: a small SwiftPM executable target with no WebKit import. It wraps `open "browsemium://…"` and `osascript`. It adds no network surface; the MCP endpoint stays task-grant only.
- Tests: scheme parser fuzz (malformed, oversized, private/locked refusal), intent unit tests, an `osascript` round trip documented as manual QA.

**B4. Spotlight and Handoff (opt-in, lower priority).** Settings toggles, default off. `CSSearchableIndex` for bookmarks only; `NSUserActivityTypeBrowsingWeb` for the current tab; never private or locked; turning off deletes indexed items. Spike sandbox behavior first.

### Wave C — local-first AI

**C1. Apple Intelligence provider.**
- Core: add `AIProviderID.appleIntelligence` and update every exhaustive switch (`AIAdapterFactory` in `BrowsemiumUI/App/AIAdapterFactory.swift`, `ProviderModelCatalog.swift`, `ModelCapabilities.json`, Settings UI).
- New `BrowsemiumAI/Providers/AppleIntelligenceAdapter.swift` conforming to `AIProviderAdapter` (`Contracts.swift:12`), wrapped in `#if canImport(FoundationModels)` and `@available(macOS 26, *)` so headless builds still work.
  - `validateCredential()` checks `SystemLanguageModel.default.availability` and maps ineligible/not-enabled/not-ready to typed errors with plain copy.
  - `listModels()` returns one model, "Apple Intelligence (on this Mac)". PCC is not exposed in v1 (owner decision 2).
  - `stream(_:)`: map `streamResponse` snapshots to `AIEvent.textDelta` by emitting the suffix delta (snapshots are cumulative).
- Context: window is 8,192 tokens. Add a per-model input budget to the policy and a map-reduce chunker for long pages. Use `tokenCount(for:)` where available, else a character estimate. Capability JSON: no images in v1.
- UI: provider card reads "No key. Runs on this Mac." Review sheet states the content stays on this Mac.
- Tests: availability mapping, snapshot-to-delta, chunker boundaries, budget enforcement, with a fake model; a live test that skips when unavailable.

**C2. Tab grouping suggestions (on-device, suggestion-only).**
- New `TabGroupingSuggester` (pure core plus a `TabGroupProposing` protocol). Input is titles and hosts of unpinned, non-private, non-locked tabs in the current space, at most 40, never page content.
- With C1 available, use guided generation for `{name, tabIDs}` proposals. Without it, deterministic grouping by registrable domain (3 or more tabs).
- UI: palette "Group tabs by topic" and a sidebar banner that opens a preview sheet with checkboxes. Apply with the existing `assignTabToFolder`. Never runs automatically.
- Also "Close duplicate tabs (N)" using normalized URLs (fragment and tracking params removed).
- Tests: fallback grouping, dedupe, model path through a fake.

**C3. Local index.**
- Stage 1: already exists (FTS5 `history_visits_fts`). What remains is ranking by bm25 plus recency plus visit count instead of recency alone.
- Stage 2 (opt-in, default off, "Index page text on this Mac"): after load, for non-private, non-locked pages, store at most 4 KB of readable text per page, with per-site exclude, "Clear index" and visible size. Optionally embeddings through `NLContextualEmbedding`. Copy must say it is stored unencrypted in the profile database.
- Stage 3: "Resume topics" on New Tab, from clustered embeddings (labels from title n-grams, or the on-device model). One click reopens the topic's tabs.
- Tests per stage; private and locked exclusion tests are blocking.

**C4. Page watch (Notify Me equivalent).**
- Table `page_watches` (url, interval, last hash, last snippet). Minimum interval 15 minutes, 20 watches maximum, exponential backoff, public pages only through ephemeral `URLSession` with no cookies. If a fetch looks like a login wall, warn the user. Runs only while the app is running, and the copy says so.
- Notifications through `UNUserNotificationCenter`, authorization requested on the first watch. Click opens a tab. Optional on-device diff summary through C1. Never created from private windows.
- Tests: differ and scheduler with injected clock; a local fixture server that flips content.

### Wave D — delight

**D1. Site tweaks (Boosts-lite) and "Describe a tweak".**
- Table `site_tweaks` plus `SiteTweakRepository`, modeled on `CosmeticRuleRepository.swift` and the host-to-payload injection used for cosmetic rules (grep `cosmetic` in `BrowsemiumEngine`).
- Phase 1 CSS only, injected at document start per host and profile. Private windows keep tweaks in memory only.
- Phase 2 JS in a dedicated `WKContentWorld` (`browsemium.tweaks`), with a confirm dialog naming the host. Never auto-applied from AI output.
- Validation: 32 KB cap; reject `@import` and `url(` that is not a `data:` URL, so imported or AI-written CSS cannot beacon out.
- UI in the site shield panel: list, editor with live preview, enable toggle, import/export as JSON file. No gallery, no server.
- "Describe a tweak": the user's description plus a compact DOM skeleton (tags, ids, classes, roles, no text) goes through the existing review sheet to the chosen provider, or stays local with C1. Parse a fenced `css` block, preview, Save. No auto-apply.
- Tests: repository round trip, scanner rejections, a real-WebKit computed-style test, private-window non-persistence, profile isolation.

**D2. Containers (per-space data stores): spike, then ship.**
- Spike (time-boxed): per-space `WKWebsiteDataStore(forIdentifier:)` with extensions. `ExtensionHost` keeps one `WKWebExtensionController` per profile store. Recommended v1: containers run without extension injection and say so.
- Model: `BrowserSpace.dataStoreID: UUID?` (nil means the profile store), new migration. `WebViewFactory` selects the store from the space. Clear-browsing-data and `PrivacyDataManager` must enumerate container stores. Deleting a space calls `WKWebsiteDataStore.remove(forIdentifier:)`.
- UI: new-space toggle "Keep cookies and site data separate" (fixed at creation). Copy: history, bookmarks and passwords are still shared in the profile; logins are not.
- Smart-routing rules (Plan 2.3) can target container spaces.
- Tests: two container spaces do not share a cookie (real WebKit plus local server, modeled on the existing per-profile isolation test), deletion removes the store, clear-data covers it, locked and private semantics unchanged.

**D3. Quick answers in the address bar.** Hand-written parser in Core (`QuickAnswer.swift`): arithmetic, percent, parentheses, a few length/mass/temperature units. No `NSExpression` (it traps on bad input). Suggestion row "= 42". Fuzz tests. No currency (needs network).

**D4. Auto-archive stale tabs.** Setting "Archive unpinned tabs after" Never/12h/24h/7d/30d, default Never. Uses `ClosedTabRepository`; Library gets "Recently archived". Skip pinned, audible, downloading and keep-awake tabs (reuse `TabSleepPolicy` signals). Check first what the existing "archive" matches are. Tests with an injected clock.

### Wave E — the safest agent surface (after Plan 7 v1)

**E1. Finish Plan 7 v1.** Open items from `Plans/7-polished-autonomous-workspace.md`: human takeover and pause, the packaged app's launch-to-endpoint path with a live client session (needs the owner's go-ahead to launch the app), native keyboard and VoiceOver QA. Keep per-click confirmation until a safe-action heuristic exists. No product-contract change until every gate passes.

**E2. Injection red-team suite.**
- Fixtures under `Packages/BrowsemiumKit/Tests/BrowsemiumAgentTests/Fixtures/Injection/*.html`: visible instruction, white-on-white, `display:none`, `aria-label`, `alt`, HTML comment, off-screen, cross-origin iframe, `<title>`, JSON-LD, link `href`, fake system message, tool-result impersonation.
- Wrap all page-derived tool output in an explicit untrusted-content envelope with provenance.
- A scripted client that obeys the page must still be unable to: leave granted origins, type into password/card/OTP fields, act on non-task tabs, or click a consequential element without confirmation. One test per control.
- Publish a table of attack class, control and test name. The wording is containment, not immunity.

**E3. WebMCP bridge (experimental, off by default).**
- Spike: read the current W3C Web Machine Learning CG draft and the WebKit standards position before writing code.
- A document-start user script defines `navigator.modelContext` only when absent, forwards tool registrations to a `WKScriptMessageHandler`, and is active only on task tabs whose grant includes a `webmcp` capability.
- Expose through MCP as `page_tool_list` and `page_tool_call`, not as dynamic top-level tools, so the gate semantics and schema stay stable. Arguments are validated against the tool's `inputSchema`. Results are labelled untrusted. Page tool calls need confirmation unless the tool declares read-only.
- Tests: registration, schema rejection, grant scoping, off-by-default.

### Wave F — honest numbers

**F1.** Add a cold-launch measurement to `Benchmarks/` using the existing `LaunchMetrics`, with the same publish-only-if-measured rules. Energy measurement is optional and needs root for `powermetrics`.

## Owner decisions (defaults chosen, not blocking)

| # | Question | Default |
|---|---|---|
| 1 | Cross-device sync | Stay no-sync. CloudKit needs a provisioning profile, which ad-hoc signing cannot carry. A user-chosen encrypted sync folder is possible but needs explicit authorization. Build portable encrypted backup and restore first (already an open item). |
| 2 | Offer Apple's Private Cloud Compute model | Not in v1. If added later, it goes behind the existing review sheet naming "Apple Private Cloud Compute" as the destination. |
| 3 | Passkeys | Needs Apple's restricted browser-passkey entitlement, which ad-hoc builds cannot ship. Filing the request is an owner action; code stays unshipped meanwhile. |
| 4 | Containers and extensions | v1 containers run without extension injection. |
| 5 | WebMCP bridge | Experimental flag, off by default; ship only if the spec position is stable. |
| 6 | macOS floor | Keep 14; gate every macOS 26/27 API with availability checks. |

## Verification

Headless (Command Line Tools):
```sh
BROWSEMIUM_HEADLESS=1 swift build --package-path Packages/BrowsemiumKit
BROWSEMIUM_HEADLESS=1 swift run --package-path Packages/BrowsemiumKit BrowsemiumHeadlessTests
```
Full (Xcode 27):
```sh
swift build --package-path Packages/BrowsemiumKit
swift test --package-path Packages/BrowsemiumKit
xcodegen generate --spec project.yml
xcodebuild -project Browsemium.xcodeproj -scheme Browsemium -configuration Debug build
xcodebuild -project Browsemium.xcodeproj -scheme Browsemium test
```
Also: `Scripts/verify-project.sh` after regenerating; `git diff --check` for whitespace. Check any macOS 27 gate by temporarily compiling the file with `-D` stubbing, or by reading CI's Xcode 26.3 build. Manual QA that automation cannot replace: Shortcuts and AppleScript round trips, Develop-menu inspection, notification permission flow, light/dark and VoiceOver passes.

## Sources

- [StatCounter desktop share](https://gs.statcounter.com/browser-market-share/desktop/worldwide)
- [WebKit: News from WWDC26, Safari 27 beta](https://webkit.org/blog/17967/news-from-wwdc26-webkit-in-safari-27-beta/)
- [WebKit Features for Safari 27.0](https://webkit.org/blog/18325/webkit-features-for-safari-27-0/)
- [9to5Mac: Safari 27 and MCP](https://9to5mac.com/2026/09/17/webkit-blog-breaks-down-whats-new-with-safari-27-for-developers-including-mcp-support/)
- [MacRumors: Safari features in iOS 27](https://www.macrumors.com/guide/ios-27-safari/)
- [Apple: What's new in Foundation Models (WWDC26)](https://developer.apple.com/videos/play/wwdc2026/241/)
- [Chrome at I/O 2026](https://developer.chrome.com/blog/chrome-at-io26)
- [TechCrunch: browser alternatives, Jul 2026](https://techcrunch.com/2026/07/22/as-the-browser-wars-heat-up-here-are-the-hottest-alternatives-to-chrome-and-safari-in-2026/)
- [Privacy Guides: Brave Containers](https://www.privacyguides.org/news/2026/07/03/brave-adds-containers-to-separate-your-browsing/)
- [Orion release notes](https://cdn.kagi.com/updates/orion-release-notes.html)
- [Zen releases](https://github.com/zen-browser/desktop/releases)
- [SiliconANGLE: Firefox Smart Window](https://siliconangle.com/2026/08/18/firefox-updates-smart-window-a-new-in-browser-ai-assistant-that-can-keep-up-with-you/)
- [Windows Blogs: Edge updates, May 2026](https://blogs.windows.com/msedgedev/2026/05/13/new-updates-to-edge-across-desktop-and-mobile/)
- [Dark Reading: AI browser prompt injection](https://www.darkreading.com/application-security/no-perfect-fix-ai-browser-prompt-injection-flaws)
- [Apple Developer Forums: browser passkey entitlement](https://developer.apple.com/forums/thread/837755)
- [W3C WebMCP technical notes](https://w3c-cg.github.io/aikr/webMCP/webmcp-technical-notes.html)
