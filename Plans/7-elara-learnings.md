# Plan 7 — What to copy from Elara, and what else makes this the best browser

Status: **plan, not shipped.** D1/W5 are superseded by the owner-approved
`7-polished-autonomous-workspace.md` (2026-10-03): autonomous external MCP tasks
within a bounded grant, not approval for every click. The UI redesign is verified
development source, not a published release; built-in agent chat remains deferred.
Written 2026-10-03. Executor: read this whole
file, then `MEGAPLAN.md`, `PRODUCT.md`, `AGENTS.md`, `QUALITY_PASS.md` before
touching code. Nothing here authorizes accounts, sync, telemetry, CEF work, or
a cloud service.

## 1. Evidence and its limits

Source: Daniel White's teaser for **Elara**, "a quiet [browser] for the Mac that
always asks before its agent clicks" (X post, 2026-10-02, 45 s, ends on "Elara —
Coming soon."). It is an unreleased product shown in a mock-up. Every row below
is read from video frames; nothing was tested hands-on, and nothing about
engine, memory, or security is known. Do not describe Elara's behavior in any
Browsemium surface; copy only patterns, in our own words and design.

| Time | What the frame shows |
|---|---|
| 0:03–0:05 | Green gradient tiles; "Elara is a quiet browser for the Mac" |
| 0:07–0:09 | Browser mock-up: bookmarks bar with folders (Design, Reading, Travel, Recipes) and pinned sites, two tabs; "made to bring the calm back" |
| 0:11–0:13 | A small floating launcher: type "cosmos" → one result row with **Open**; "It's a keystroke away from any app" |
| 0:15 | "It keeps 92 tracker domains out" (a count) |
| 0:17–0:19 | Chrome re-tinted live from a swatch grid: 13 hue columns × 5 tone rows plus a grey column; "Dress it in any colour you like" |
| 0:21–0:25 | Provider chips Anthropic / OpenAI / Vercel; "Bring your own provider, whichever you trust" |
| 0:27 | Floating composer bar: "A week in Lisbon" + send |
| 0:29–0:35 | Step timeline "Planning your week": Searching flights to Lisbon / Comparing stays for seven nights / Working; "and it does the legwork" |
| 0:35 | Page with a glowing multi-colour border, side **Assistant** panel (provider chip, history, page chip `stays.example`, "Ask anything"), small labelled cursors "Reading the stays", "Opened", "Read" |
| 0:37 | Native-style dialog: **"Click this control? Reserve, Alfama, 12 to 19 May — On stays.example"** with **Decline** / **Allow Once**; a cursor labelled "Wants to click"; "But it always asks before it clicks" |
| 0:39 | Result row turns green "✓ Reserved"; cursor labels "Reserved", "Read" |

## 2. Copy / adapt / skip

| Elara pattern | Browsemium today | Verdict |
|---|---|---|
| Per-click consent card with derived label + host, Allow Once / Decline | None. `PRODUCT.md` promises "No autonomous AI. The assistant does not operate browsing pages." No tool-calling exists in any `BrowsemiumAI` adapter. | **Adapt, behind decision D1** (§3). Biggest differentiator available. |
| Glow border + labelled agent cursors + step timeline while the agent works | None | **Adapt** with W5c. Draw it in the host view, never inside the page. |
| Summon bar from any app by keystroke | No global hotkey anywhere in the repo | **Copy** → W1 |
| Re-tint the whole chrome from a swatch grid | `BrowserSpace.color` exists and tints only a thin tab-group accent (`BrowserTabStrip.swift:203`, `TabSidebar.swift:298`); palette is monochrome by brand (`DesignSystem/Theme.swift`) | **Adapt**, opt-in, default unchanged → W2 |
| Bring your own provider incl. Vercel | BYOK: OpenAI, Anthropic, Gemini, xAI, Ollama, v0. No generic endpoint. | **Copy**, more generally → W3 |
| "Keeps 92 tracker domains out" | Starter list has 87 rules naming 71 distinct hosts (`StarterContentRules.json`, verified during W4). `PRODUCT.md`: never show a number we cannot verify; WebKit exposes no blocked counts. | **Adapt**: show list size as list size, never "kept out" → W4 |
| Bookmarks bar folders, pinned sites, quiet chrome | Already shipped | Skip |
| Visual language (soft green gradients, rounded tiles) | Brand is monochrome, Geist, split-triangle mark (`PRODUCT.md`, `Scripts/generate-brand-assets.py`) | **Skip** — do not borrow identity |

## 3. Decisions

**D1 (owner decision, gate for W5 and W6).** Today's written contract is
"no autonomous AI" and an ACP agent chat and Build Mode were removed by owner
decision (`MEGAPLAN.md` Phase 4.5; `HANDOFF.md` §8: do not resurrect without
being asked). The MEGAPLAN "Later" item for CLI/MCP is scoped to *reads and
explicit user commands*. W5 goes one step further: an external agent may *ask*
to click/type, and every such action is blocked until the user approves that
single action in the browser UI. That is not autonomy, but it changes the
sentence in `PRODUCT.md`. **Recommended answer: yes, W5 only (external agents
through MCP, per-action consent, no "always allow"); W6 (in-app agent) stays
deferred.** If the owner says no, execute W1–W4 and the §6 queue and stop;
W5 is independent of them.

Decisions already made for W1–W4 (do not re-ask):

- Everything is opt-in and off by default: global hotkey, tint, generic provider.
- No new accounts, no network calls on launch, no telemetry.
- Private windows and locked spaces never appear in global surfaces and never
  receive agent access.

## 4. Execution order

`W4` (tiny, warms up the test loop) → `W3` → `W1` → `W2` → *[D1 answered]* →
`W5a` → `W5b` → `W5c` → `W5d` (docs). Each unit ends green and is committed
separately: short imperative subject, no PR needed. Before every commit run the
unit's verification block and `git diff --check`.

Conventions that apply to every unit (from `AGENTS.md` / `HANDOFF.md` §6):
Swift Testing (`@Test`, `#expect`, `#require`, `@MainActor`); Swift 6 strict
concurrency; never edit generated Xcode project files — change `project.yml`
and run `xcodegen generate --spec project.yml`; opening Settings must never hit
the keychain (use `KeychainStore.hasSecret`); `#if compiler(>=6.3)` gates for
APIs newer than the CI SDK; voice is plain, specific, sentence case, no
exclamation marks; fix a bug-specific test red → green → reverted-red.

Standing verification for every unit:

```sh
BROWSEMIUM_HEADLESS=1 swift build --package-path Packages/BrowsemiumKit
swift test --package-path Packages/BrowsemiumKit --filter <UnitTestSuiteName>
swift test --package-path Packages/BrowsemiumKit        # before the final commit of a unit
xcodegen generate --spec project.yml && \
xcodebuild -project Browsemium.xcodeproj -scheme Browsemium -configuration Debug build
```

Kill stale `swift-test` / `swiftpm-testing-helper` processes before diagnosing a
hang; do not pipe a watched test run through `tail`.

---

## W4 — Honest list size in the site shield (S)

Goal: the shield says how many hosts the active rule lists name, as a list size.

1. Read `ContentRuleListManager.swift`, `BlockingState` in
   `BrowsemiumEngineKit/BrowserEngine.swift` (it already has `ruleCount`), and
   the shield panel in `Browser/BrowserToolbar.swift` / `Browser/ToolbarMenuPanels.swift`
   (search "Pause blocking on this site").
2. Add `hostCount` to the compile result only if it is not already derivable;
   count distinct hosts in the bundled list plus the enabled user lists
   (`UserFilterListController`). Do not count blocked requests anywhere.
3. Copy: "Rule list: 71 hosts" (derived, not hard-coded) and, when user lists are active, "plus 1,204 from
   your lists". Never "kept out", "blocked", or "protected from". When blocking
   is Off or paused, show "Rules off on this site".
4. Tests (`BrowsemiumEngineTests` or `BrowsemiumUITests`): count matches the
   fixture; off/paused states render no number; a string test asserting the
   shield copy contains none of `blocked`, `kept out`, `stopped`.
5. Record in `MEGAPLAN.md` §4.7: shield now shows list size, still no
   blocked-request count.

## W3 — Generic OpenAI-compatible provider, with Vercel AI Gateway preset (M)

Goal: one adapter covers Vercel AI Gateway, OpenRouter, LM Studio, vLLM, and any
OpenAI-compatible endpoint. BYOK, key in Keychain, review sheet unchanged.

Verified 2026-10-03: Vercel AI Gateway Chat Completions base URL is
`https://ai-gateway.vercel.sh/v1`, `Authorization: Bearer <key>`, models named
`provider/model` (docs: vercel.com/docs/ai-gateway/openai-compat). Re-check the
page before coding; OpenRouter's is `https://openrouter.ai/api/v1`.

1. Read `BrowsemiumAI/Providers/OpenAIAdapter.swift` (init at line 14,
   `makeRequest` at 73), `Providers/V0Adapter.swift` and `XAIAdapter.swift`
   (both are OpenAI-shaped; reuse their pattern, do not copy-paste a fourth
   copy — extract a shared base if two already duplicate), `BrowsemiumUI/App/AIAdapterFactory.swift`,
   `AIProviderID` in `BrowsemiumCore/Models.swift:57`, the provider settings UI
   in `Settings/SettingsView.swift`, and `ProviderModelCatalog.swift`.
2. Add `AIProviderID.openAICompatible`. Because `AIProviderID` is `CaseIterable`
   and switched on in many places, grep every `switch` / `allCases` and fix each
   at compile time rather than adding `default:`.
3. Settings: a non-secret `openAICompatibleBaseURL` (+ display name) in
   `BrowserSettings` (`BrowsemiumCore/PrivacyModels.swift`, follow the
   `decodeIfPresent ?? defaults` pattern near line 341). Presets menu: Vercel AI
   Gateway, OpenRouter, LM Studio (`http://localhost:1234/v1`), Custom. API key
   in Keychain under a new account name; the Settings screen only calls
   `hasSecret`.
4. Validation: base URL must be `https`, or `http` only for a loopback host
   (`localhost`, `127.0.0.1`, `[::1]`); reject credentials in the URL and
   non-http(s) schemes; trim trailing slash; the destination **host is shown in
   the review sheet** next to the provider name so the user sees where text is
   going. `isLocal` is true only for loopback hosts.
5. `listModels` hits `GET {base}/models`; tolerate gateways that return extra
   fields; cap response size.
6. Tests (`BrowsemiumAITests`): request building against a stubbed
   `URLProtocol` (path, bearer header, body); URL validation table (https ok;
   http localhost ok; http remote rejected; userinfo rejected; `file:` rejected);
   `isLocal` only for loopback; review sheet shows host; Settings does not touch
   keychain secrets (use the existing no-secret-read test style).
7. Docs: `PRODUCT.md` "Features that exist today" and README provider list.
   Say "any OpenAI-compatible endpoint you configure"; do not claim specific
   gateway features beyond what is verified.

## W1 — Summon bar (global hotkey launcher) (M)

Goal: a keystroke from any app opens a small floating field; type, Return opens
the match in Browsemium. Off by default.

Design decisions (made):

- Hotkey via Carbon `RegisterEventHotKey` + `InstallEventHandler`
  (`import Carbon.HIToolbox`). It works inside the App Sandbox and needs **no
  Accessibility permission**. Do **not** use `NSEvent.addGlobalMonitor` (needs
  Accessibility) or an event tap.
- A fixed preset menu, not a custom key recorder: ⌥Space, ⌃Space, ⌘⇧Space,
  ⌃⌥B. Default **Off**. Warn in the picker that ⌥Space and ⌘Space are commonly
  taken by launchers.
- Panel: `NSPanel`, `.nonactivatingPanel` + `.borderless`, `level = .floating`,
  subclass overriding `canBecomeKey` → `true`, hosts a SwiftUI view, centered on
  the screen with the mouse, dismiss on Esc / resign key. Return opens the item
  in the most recently active **non-private** Browsemium window (new window if
  none), then `NSApp.activate`.
- Results: reuse, do not fork, the palette sources and `FuzzyMatcher`: open tabs
  (`TabPaletteCommandProvider`), history and bookmarks
  (`LibraryPaletteCommandProvider`), pinned tabs first; typed text that looks
  like a URL or a search becomes an "Open URL" / "Search" row through
  `NavigationResolver`. No new index, no new storage.
- Privacy: never list tabs/history from private windows; never list tabs of
  locked spaces (same filter ⌘K already applies); read the profile of the last
  active window only.

Steps:

1. Read `Shared/AppShell/AppShell.swift` (`BrowsemiumAppDelegate`,
   `BrowserWindowRegistry` at ~122 — the registry gives "most recent
   non-private window"), `CommandPalette/*`, `FuzzyMatcher.swift`, and how
   `BrowserSettings` is stored.
2. Core: `SummonHotkeyPreset` enum (`off`, four presets) + `BrowserSettings`
   field `summonHotkey` (default `.off`, tolerant decode).
3. New `BrowsemiumUI/Summon/` : `GlobalHotkeyRegistrar` (protocol + Carbon
   implementation; the protocol lets tests inject a fake), `SummonPanelController`,
   `SummonSearchModel` (query → rows; pure, testable), `SummonView`.
4. Wire register/unregister to the setting change in the app delegate; unregister
   on quit; if registration fails (`eventHotKeyExistsErr`), surface an inline
   Settings message: "That shortcut is already used by another app."
5. Settings → General: "Summon bar" row with the preset picker and one line:
   "Opens a search field from any app. Does not need Accessibility access."
6. ⌘K palette gets a "Summon bar: …" setting shortcut? **No** — skip.
7. Tests: `SummonSearchModel` ranking/filters (private and locked-space tabs
   excluded; pinned first; URL and search rows); setting round-trips including
   unknown stored value → `.off`; registrar fake receives register on set,
   unregister on `.off`, and a failure message on a simulated conflict.
8. Native QA checklist (user): panel appears over fullscreen apps? (`collectionBehavior`
   `.fullScreenAuxiliary`, `.canJoinAllSpaces` — set and verify); typing works
   without activating the app; Esc returns focus to the previous app.

Out of scope here: "sites as Dock apps". Elara's row says "Open" for what may be
an installed site-app; a Dock-app helper needs per-site bundles and signing. Log
it under MEGAPLAN "Later" only.

## W2 — Opt-in chrome tint per space (M)

Goal: pick a colour for a space from a grid and the browser chrome takes a soft
tint of it. Default (no colour) is exactly today's monochrome look.

Design decisions (made):

- Reuse `BrowserSpace.color` (hex, optional, already persisted per space — no
  schema change, no migration). Today it only draws an accent line; this unit
  makes it the space's tint. Spaces with no colour are unchanged.
- Palette tokens in `Theme.swift` are static adaptive `NSColor`s, so the tint
  is a **low-alpha tinted fill layered under chrome** (tab strip, sidebar,
  toolbar, new-tab canvas), not a change to text tokens. Text colours stay
  alpha-black/white.
- Swatch grid: 13 hues × 5 tones + a grey column, as a pure function
  `ChromeTint.swatches()` in `BrowsemiumCore` returning hex values; one tone row
  is chosen per colour scheme when rendering (light mode uses pale rows, dark
  mode uses deep rows) via `ChromeTint.fill(for hex:, scheme:)`.
- Contrast is enforced in tests, not by eye: for every swatch, in light and
  dark, `browsemiumPrimary` over the tinted `browsemiumCanvas` ≥ 7:1 and
  `browsemiumSecondary` ≥ 4.5:1 (compute WCAG relative luminance in the test).
  A swatch that fails is clamped by lowering chroma; the test asserts the
  clamped result passes.

Steps:

1. Read `Theme.swift`, `BrowserTabStrip.swift:195-215`, `TabSidebar.swift:290-305`,
   `BrowsemiumAppView.swift`, the space context menus (search "Rename" /
   `BrowserSpace(` in `BrowserWindowModel.swift:1109`) and find whether any UI
   sets `color` today. If none, add `BrowserWindowModel.setSpaceColor(_:for:)`
   persisting through the same repository path as rename.
2. Core: `ChromeTint` (swatches, clamp, `fill`) with no UI imports.
3. UI: `SpaceTintPicker` (the grid, keyboard navigable, each swatch has an
   accessibility label such as "Sage, soft"), reachable from the space menu and
   Settings → Appearance; a "None" swatch first.
4. Apply: `TintedChromeBackground` view modifier used by the chrome surfaces
   listed above; animate with the existing `sidebarTransition`-style spring and
   respect Reduce Motion (cross-fade only).
5. Private window: always untinted, so privacy state stays unmistakable (the
   "Private" badge is the signal). Locked spaces keep their tint on the lock screen.
6. Tests: contrast test above (all swatches × both schemes); `fill(nil)` returns
   no tint; setting a colour persists and survives reload; private window model
   ignores colour; snapshot tests in `BrowsemiumUISnapshotTests` for 3 swatches
   × light/dark — check how existing snapshot tests record baselines first.
7. Brand check against `PRODUCT.md`: copy "Space colour" (British/US spelling —
   use the repo's existing spelling; grep "color" vs "colour" before writing).

## W5 — Agent surface with per-action consent (L, gated by D1)

Goal: Claude Code, Codex, or any MCP client can drive a page **only** through a
local, token-authenticated MCP endpoint the user turned on, and every state-
changing action waits for the user's explicit approval of that single action in
the browser. The agent brain stays outside Browsemium, so no tool-calling
support in `BrowsemiumAI` is needed. This is the Elara consent pattern applied
to the user's own agents.

### Architecture

New pure types in `BrowsemiumCore/Agent/` (no WebKit):
`AgentTool` (enum of the tools below), `AgentAction` (verb, tabID, `ElementRef`,
text), `PageSnapshot` (elements: ref, role, name, frameOrigin, isEditable,
fingerprint), `ApprovalRequest` (verb, element role + name, host, optional
typed-text preview, expiry), `ApprovalDecision` (`allowOnce` / `decline` /
`expired`), `AgentGrant` (tab, origin, expiry, scope `read`).

`BrowsemiumEngineKit`: protocol `PageActuating` (`snapshot(tabID:)`,
`resolve(ref:)`, `click`, `type`) so the gate is testable with a fake.
`BrowsemiumEngine`: `WebPageActuator` implements it with `evaluateJavaScript`
in a dedicated `WKContentWorld` (`WKContentWorld.world(name: "browsemium.agent")`)
so page scripts cannot read, replace, or spoof the snapshot code.

New SwiftPM target `BrowsemiumAgent` (depends on Core + EngineKit only):
`AgentActionGate` (the only path from a tool call to the actuator),
`MCPServer` (JSON-RPC 2.0 over streamable HTTP on loopback), `AgentSessionLog`.

`BrowsemiumUI`: `AgentApprovalCard`, `AgentStatusBanner`, `AgentHalo`,
`AgentCursorLabels`, Settings → Agents.

### Tool surface (v1, nothing else)

| Tool | Kind | Rule |
|---|---|---|
| `list_tabs` | read | Excludes private windows and locked spaces |
| `snapshot` | read | Needs an active **read grant** for that tab+origin. Numbered interactive elements. Values of password, `autocomplete=cc-*`, one-time-code fields are never returned |
| `read_text` | read | Readable text via existing `ContentCaptureService`; same grant |
| `screenshot` | read | Same grant |
| `navigate` | write | Cross-origin target needs an approval card ("Open example.com?"); same-origin allowed under a read grant |
| `click` | write | **Approval card every time** |
| `type` | write | **Approval card every time** showing field name and the text (truncated at 120 chars); refuses password / cc / one-time-code fields outright |

Explicitly absent: arbitrary JavaScript, cookies/storage, downloads, file
upload, key presses, tab close, form auto-submit, screenshots of other windows.
No "Always allow" in v1 — only **Allow once** and **Decline**.

### Consent rules (these are the security core — each gets a test)

1. The card text is built by Browsemium from the live DOM (role, accessible
   name, form summary) and the frame's real origin. Agent-supplied descriptions
   are never shown as if they were ours.
2. **Re-resolve at execution**: after approval, re-find the element and compare
   its fingerprint (role, name, frame origin, DOM path hash, centre within
   tolerance). Mismatch → auto-decline with "The page changed after you
   approved." This blocks swap-after-approve.
3. Default focus is **Decline**. Keystrokes in the first 600 ms after the card
   appears are ignored, and Return alone never approves: approve needs a
   click or ⌘Return. This prevents an agent popping a card while the user is
   mid-typing.
4. One pending approval per window; further requests queue (max 3, else
   rejected). A card auto-declines at 60 s. A tab navigation or switch declines
   pending cards for that tab.
5. Grants: read grant per tab+origin, expires on cross-origin navigation or
   after 15 minutes, max 30 tool calls then re-grant. A toolbar banner ("Agent
   connected · reading <host> · Stop") revokes everything instantly.
6. Private windows and locked spaces: agent surface refused with a clear error;
   no grant can be created there.
7. The server is **off by default**, listens on `127.0.0.1` only, requires a
   bearer token (stored in Keychain; Settings uses `hasSecret` only), validates
   the `Origin` header and rejects any request carrying a browser `Origin`
   (blocks pages in the browser itself attacking it via DNS rebinding or
   `fetch`), sends no CORS headers, and rejects bodies over 256 KB.
8. The audit log (verb, host, element label, decision, time) is in-memory per
   app run, no typed values stored, viewable in Settings → Agents.

### W5a — Core types, gate, actuator, fake-driven tests

1. Spike first (½ day, write findings into this file under "Spike results"):
   (a) `WKContentWorld` snapshot of a fixture page including an open shadow
   root and a same-origin iframe; (b) `element.click()` vs a synthesized trusted
   `NSEvent` click on three fixture pages (plain button, framework-style
   handler on `pointerdown`, a link). Ship `element.click()` plus scroll-into-view
   in v1 and record any page where it fails; v1 snapshots the top frame only and
   reports other frames as opaque "frame (host)".
2. Implement the types, `PageActuating`, `AgentActionGate`, `WebPageActuator`.
3. Tests (`BrowsemiumAgentTests` + `BrowsemiumEngineTests` with a real
   `WKWebView` fixture): each consent rule above; a `click` never reaches the
   fake actuator without `allowOnce` (prove red by disabling the gate check,
   then revert); fingerprint-swap fixture; password field refused; expired card
   does nothing; private-window refusal.

### W5b — MCP endpoint

1. Spike (½ day): add `com.apple.security.network.server` to
   `BrowsemiumApp/Config/Browsemium.entitlements` (today only `network.client`
   is present) and confirm a sandboxed Debug build can bind `127.0.0.1` on a
   random port and a separate process can connect. If the sandbox blocks it,
   fall back to a Unix socket inside the container
   (`~/Library/Containers/com.browsemium.browser/Data/tmp/`, mode 0600) plus a
   tiny stdio helper; record which was chosen. Do not weaken any other
   entitlement. Update the "Things that are true by design" notes in `AGENTS.md`
   to list the new entitlement and why.
2. Implement with `Network.framework` (`NWListener`, loopback only, no third
   party dependency). Methods: `initialize`, `notifications/initialized`,
   `ping`, `tools/list`, `tools/call`. Return JSON-RPC errors, never crash on
   malformed input.
3. Settings → Agents: toggle (off), "Copy connection details" button that puts
   the URL and a freshly generated token in the clipboard with a one-line config
   for Claude Code and for Codex. **Verify each client's current MCP-over-HTTP
   configuration syntax from its own docs when implementing; do not copy a
   command from memory.** Token rotation button. Port shown only while enabled.
4. Tests: initialize/list/call conformance with a local client; wrong token,
   missing token, browser `Origin`, oversized body, non-loopback bind attempt
   all rejected; server stops listening when toggled off or when the app locks
   the last space.

### W5c — Presentation

1. `AgentApprovalCard` follows `PermissionPromptCard` / `ExtensionPermissionCard`
   styling and Menu panel components (`MenuPanelContainer`, etc.). Layout: title
   "Allow this click?", body role + name, "On <host>", buttons Decline (default)
   and Allow once. Typing variant shows the field name and text.
2. `AgentHalo`: a thin animated gradient border around the page container
   (host view layer, **not injected into the page**) while a grant is active or
   an action is in flight. Monochrome by default; Reduce Motion → static 1 px
   border.
3. `AgentCursorLabels`: small labelled chips drawn in the host view at the
   element's last-known screen position for "Read", "Opened", "Wants to click",
   "Done". Disable them via a Settings toggle ("Show agent activity on the
   page").
4. Step list in the banner popover, filled from the audit log ("Read stays page",
   "Asked to click Reserve", "You allowed it").
5. Snapshot tests light/dark; accessibility: card announces via
   `accessibilityLabel`, focus lands on Decline.

### W5d — Docs and claims

- `PRODUCT.md`: replace the "No autonomous AI" bullet with: "No autonomous AI.
  Nothing in Browsemium acts on a page by itself. If you turn on the agent
  server, a connected agent can read a tab you grant and ask to click or type;
  each action waits for your approval and nothing is remembered." Do not claim
  safety guarantees beyond the tested rules.
- `MEGAPLAN.md`: add "Phase 7 — Agent surface (consented)" under Phase 3's open
  items; mark CLI as still open (`browsemium-ctl` is not part of W5).
- `README.md`, Settings copy, and the site must say the endpoint is local,
  off by default, and what the agent can and cannot do.
- `ThirdPartyNotices/README.md`: no new dependencies expected; confirm.

## W6 — In-app assistant that uses the same gate (deferred)

Only after W5 is verified and the owner asks. Needs provider tool-calling in
`AnthropicAdapter` and `OpenAIAdapter` (none today), an agent loop in
`BrowsemiumAI`, and reuse of `AgentActionGate` unchanged. Elara's step timeline
and cursor labels already exist after W5c. Do not start without a written
request; Build Mode and ACP chat were removed deliberately.

---

## 6. What else makes it the best — ranked, beyond Elara

Existing written plans stay in the order `MEGAPLAN.md` gives (user filter lists
QA → extension site controls → smart space routing → import completion). These
are the additional moves, ranked by impact on "switch and stay":

1. **Passkeys spike (research only).** The largest daily-driver blocker not yet
   scoped. Test `ASAuthorizationWebBrowserPlatformPublicKeyCredentialProvider`
   with the web-browser entitlement on an ad-hoc build against webauthn.io and
   two real sites; write results into `MEGAPLAN.md`. No public claim until
   proven (`MEGAPLAN.md` §What current browsers actually ship).
2. **Open-tab and pinned-tab import** from Chrome/Arc/Safari/Firefox session
   files (`Plans/6-import-completion.md` already orders this). Switchers judge a
   browser by whether yesterday's tabs are there.
3. **Release-time memory gate** on a quiet machine
   (`Benchmarks/benchmark-memory.sh`, unchanged method). Prerequisite for any
   comparative marketing; Elara-style teasers make the claim temptation real.
4. **Developer ID signing and notarization.** Removes the install friction that
   every competitor in `MEGAPLAN.md` Cohort A avoids; needs the owner's Apple
   Developer account — cannot be done by an agent.
5. **Whole-app light/dark visual pass** (`MEGAPLAN.md` Phase 6 quality gate),
   including W2 once it lands.
6. **`browsemium-ctl` CLI** after W5, reusing `AgentActionGate` so a shell user
   gets the same consent rules.
7. **Skills import/export as Markdown** (`MEGAPLAN.md` Phase 3 open item) — cheap,
   and gives a shareable artifact like Dia's skills gallery without a service.

## 7. Non-goals

No account, sync, telemetry, cloud agent, or hosted gateway. No "always allow"
for agent actions. No blocked-request counts. No Elara branding, copy, or
colour palette. No Chromium-edition work. No claim that WebKit matches Helium's
request interception.

## 8. Done means

- `swift test --package-path Packages/BrowsemiumKit` and the Debug
  `xcodebuild` build pass; `Scripts/verify-project.sh` and `git diff --check`
  pass.
- Each unit's native QA checklist is handed to the owner as *unverified by
  automation*; do not write "verified" for anything only unit-tested.
- Docs name exactly what shipped, and `MEGAPLAN.md` marks each unit's status.

## Implementation record — 2026-10-03

W4 is implemented in development source, not a published release. The starter
fixture establishes 87 rules naming 71 distinct hosts. Enabled user-list sizes
are deduplicated across lists and exclude starter overlap; exceptions can name
hosts, while unknown formats show unavailable. Off/paused states show no count.
Actual compile state and installed-set observation replace misleading on-state
copy; the pause explanation now includes user lists.

Twelve new fixture tests pass. Restoring incorrect totals, stale observation,
pause handling, inactive copy, and the old pause explanation made six tests fail
again; fixes were restored without weakening tests. Headless build/runner,
full Swift package tests, Xcode Debug build/test (433 distinct tests, 478 runs,
zero failures/skips), project verification, and whitespace review pass. Two
rounds of light/dark fixture inspection are smoke checks only. Native keyboard,
VoiceOver, private/off states, and the whole-app walkthrough remain user QA.
The tested ad-hoc Debug build is installed in Applications (2.1.0/210).

W3, W1, and W2 are not started in this unit. D1 remains unanswered, so W5 has
no authorization; W6 remains deferred. No agent-actuation contract was changed.
