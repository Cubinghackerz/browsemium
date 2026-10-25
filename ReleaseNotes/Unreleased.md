# Unreleased development work

These changes are committed development source, not a published release.
Signing remains ad-hoc. No notarization, Sparkle, passkey, or memory comparison
claim follows from this work.

## Groundwork

- Command-palette row construction is separated into small providers. Existing
  commands, order, fuzzy ranking, and locked-tab filtering are preserved.
- Added print, find in page, Reader mode, and hide element to the command
  palette. They use the existing page actions and matching menu shortcuts.
- The roadmap no longer claims a debug-build Web Inspector. Inspector access
  remains unimplemented; no Inspect command is advertised yet.

## Password import recovery

- Browser-key queries disallow authentication dialogs. Direct password/cookie
  import requires an already-accessible source key; protected keys are not
  bypassed, unlocked, or modified.
- A password CSV action in the browser preview keeps the chosen destination
  profile. Recovery errors are shown in the preview. CSV import reads no
  source-browser key, saves passwords to Keychain, and reminds you to delete
  the unencrypted export afterward.
- Fixed password whitespace being trimmed during vault writes. Passwords now
  keep their exact value; API-key entry retains its existing trimming behavior.

## User filter list runtime

- Added profile-local restoration and a staged parse → compile → commit →
  activate path. Failed, cancelled, mismatched, or stale compilation does not
  replace the working set. Private-mode authorization is checked again before
  saving, and profile changes invalidate pending receipts.
- Tabs apply all enabled lists alongside the starter list on their next
  navigation, subject to global blocking and site pauses. Counts describe
  rules only, not blocked requests. No third-party list is bundled.
- Settings now accepts an explicitly chosen UTF-8 file or HTTPS address,
  with a 4 MiB input ceiling. It shows supported/skipped rule counts and
  compile state, with re-import, enable/disable, and confirmed removal.
- HTTPS imports do not use browser cookies, saved credentials, or a cache.
  Redirects and final addresses are checked; addresses are not stored or
  refreshed automatically. This remains a limited hostname subset, not full
  ABP/AdGuard compatibility. Native interaction QA is still pending.
- Fixed draft import cancellation ownership and stale toggle/removal edits.
  Cancelling one import cannot cancel the wrong task or unlock a newer one.

## Site shield list sizes

- The shield reports distinct named hosts in the installed starter list and
  additional hosts from enabled user lists, deduplicated across lists. The
  current starter list has 71 named hosts across 87 rules; path/script rules
  do not name a host, and exceptions can name hosts too. These are list sizes,
  never blocked-request counts.
- Off and paused states show no host number. Compiling, failed, and unavailable
  counts are stated plainly; changing installed lists updates the open shield.
- The pause explanation now includes user lists as well as the starter list.
  Light/dark fixture rendering is not a native interaction QA pass.

## AI dock workspace

- Replaced the cramped API-key row with a readable secure field and connection
  card. Connection options and model refresh are grouped together once connected.
- Added page-aware starting actions and one multiline composer containing
  attachment and skill menus, with explicit Review/Stop controls. Review is
  unavailable while context is being prepared. API messages still require review.
- Private, locked and unsupported pages do not expose page-context actions.
  Conversation labels and spacing are clearer in both appearances. Fixture
  renders cover narrow, wide, short, error, attached and streaming states;
  native interaction/VoiceOver QA remains open.
- The AI dock itself does not gain page actions or an autonomous loop; the
  separate opt-in external agent preview is described below.

## External agent preview (opt-in, off by default)

- Settings → Agent turns on a loopback-only (127.0.0.1) MCP endpoint, with a
  bearer token stored in Keychain that you can copy and reset. Nothing listens
  until you enable it. It works with MCP clients that support Streamable HTTP
  and custom headers; the card shows a ready-to-paste Claude Code command.
- A client must request a task; you approve a card naming the origins and limits.
  Work happens in separate task tabs with a Stop button. Every click and every
  typed value needs your confirmation; password, payment and one-time-code
  fields are refused, and navigation outside the granted origin is refused.
- Stop, switching profile, locking a space and quitting end the task and close
  its pages. Task pages share your profile's browsing data and open in a panel,
  not a sidebar space. The client's self-reported name is not verified.
- Added the sandbox `network.server` entitlement to the WebKit app (loopback
  only, used only when you enable the endpoint). Covered by tests that do not
  launch the app; a live client session and keyboard/VoiceOver QA are open.
  This preview is not notarized.

- The task window's Take over, Hand back and Stop controls now have keyboard
  shortcuts (Option-Command-P and Command-period), spoken hints, and VoiceOver
  announcements. You can Stop a task while it is paused. Verified by automated
  tests and offscreen renders only; a live client session and VoiceOver QA are
  still open.

## AI reply recovery

- Empty replies become a visible, retryable error instead of a permanent
  spinner. Only the current reply displays a loading indicator; completed
  replies end immediately, and stalled requests stop after two minutes.
- Gemini handles finish frames without content, reports rejected answers,
  separates thought parts from answer text, and lists only models that
  advertise content generation. A terminal frame can carry its final text.
- Old empty assistant records are filtered when loading a conversation and
  building a request, without deleting stored records. Busy/stale review
  actions cannot submit another request, and cleared conversations discard
  their retry payloads. Stop preserves earlier replies and removes the pending
  empty reply. These behaviors use fixture tests; live credential QA is open.

## Remaining gates and queue

The 2026-10-02 memory attempt stopped at the quiet-machine preflight, before
any trials. There are no comparative results to publish. Whole-app native
light/dark QA and logged-in site compatibility checks remain user-run gates.

Per-site extension controls, smart space routing, and the remaining import
units precede the next switchability
and agent-ready features. Native light/dark QA and release gates remain open.

## Plan 8: landscape upgrade

Development source, verified by automated tests only. No native QA, signing,
performance or comparative claim follows.

- Site routing with a reversible notice. Private windows, previews, background
  tabs, pinned tabs and split view are never moved; a locked destination asks first.
- Separate groups (containers): their own cookies, logins and site data. Moving a
  tab between stores rebuilds it in the new one; deleting the group wipes and
  removes its store. No extensions run in a separate group.
- Fixed: renaming a locked space removed its lock.
- Developer tools (off by default): Web Inspector (⌥⌘I) and Safari's Develop menu.
  The inspector uses undocumented WebKit internals and may stop working after an update.
- Tracking-parameter removal at Balanced and Strict; never on sign-in URLs.
- Apple Intelligence as a local provider (macOS 26+, no key, nothing leaves the Mac).
- Tab-group suggestions and "Close Duplicate Tabs".
- Page watch and Settings card; `UNUserNotificationCenter` permission requested on first use.
- Per-site CSS tweaks with validation against network loads, plus "Write CSS" from a description using Apple Intelligence on this Mac (page structure only, never text; previewed before saving).
- Address-bar quick answers (arithmetic, percentages, length/mass/volume/temperature).
- Auto-archive stale tabs into a Library Archive (off by default).
- `browsemium://open|search|space`, five Shortcuts actions, and `browsemium-ctl`.
- Save-password offer after a plain sign-in, via an isolated-world script.
- `read_text` from the MCP endpoint now arrives inside an untrusted-content
  envelope; fourteen injection vectors are covered by tests (`Plans/8-injection-controls.md`).
- Database migrations v12–v16 (routes, tweaks, space data store, archive, watches).
- Address-bar history suggestions are ranked by relevance, visit count and recency, one row per page.

## Per-site extension controls

- Settings → Extensions lists each extension's site choices as Allow / Ask /
  Deny pickers, and the site shield offers the same choice for the site on
  screen. Choices are per profile; private windows neither offer nor remember
  them, and locked or separate-data tabs stay hidden from extensions regardless.
- Deny blocks content scripts from the next page load; anything already running
  needs a reload, and both surfaces say so. Denial wins over broader grants,
  activeTab gestures, and permission prompts — including prompts answered after
  the tab navigated away. Removing an extension clears its site choices.
- Verified by automated tests and offscreen renders only; keyboard/VoiceOver QA
  is open (tracked with the accessibility pass).

## Import completion: sessions and Firefox passwords

- Firefox and Safari open tabs preview with a checkbox and reopen in the
  destination profile — pinned tabs reopen pinned, already-open pages are
  skipped so re-importing is idempotent, and private windows open nothing.
  Firefox reads `recovery.jsonlz4`/`sessionstore.jsonlz4` (size-capped LZ4 via
  the system framework); Safari reads the `URLString`/`Title` subset of
  `LastSession.plist`. Malformed or oversized sessions fail before any write.
  Chromium sessions remain explicitly unsupported.
- Firefox passwords import without a Primary Password: `logins.json`
  hostnames preview without decrypting, and a confirmed import unwraps
  `key4.db` with CommonCrypto only (3DES-CBC and PBES2/AES-256-CBC). A set
  Primary Password, legacy `key3.db` profiles, and unknown algorithms are
  reported honestly as unsupported — never guessed at — and one bad login
  never aborts the rest. Saved logins go straight to Keychain; reports carry
  ordinals only, never hosts, usernames, or secrets.
- Verified by automated tests on generated fixtures only (no real user
  profile was read); real-Firefox byte compatibility, native report QA, and
  keyboard/VoiceOver QA remain open.

## Local page index and Resume topics

- Settings → Privacy → Page text index (off by default) stores up to 4 KB of
  readable text per page in an on-Mac full-text index, unencrypted in the
  profile database — the card says so. Private windows, locked spaces,
  separate-data spaces, and credentialed pages are never indexed; sites can
  be excluded from the shield (which purges their pages) or re-included from
  Settings, which also shows the size and clears the index. The index follows
  history retention and clear-browsing-data instead of outliving them.
- Matching pages appear as "Page text" rows in address suggestions and the
  command palette, below history, and never in private windows.
- New-tab "Resume topics" groups recently indexed pages with on-device
  embeddings (term-overlap fallback, derived n-gram labels, at most three);
  one click reopens a topic's pages.
- Verified by automated tests and offscreen renders only; keyboard/VoiceOver
  QA is open (tracked with the accessibility pass).

## Developer tooling

- `Benchmarks/benchmark-launch.sh` measures launch-to-first-frame from the app's
  own milestones. Nothing has been measured yet; no launch-speed claim is made.

## Spotlight and Handoff (both off by default)

Development source, verified by automated tests only. Neither the real Spotlight
index nor Handoff to another device has been tried.

- Settings → General → Spotlight & Handoff. "Show bookmarks in Spotlight" adds
  each bookmark's title and address, nothing else. Bookmarks saved from a
  private window, a locked space or a separate-data space are never added,
  even if the setting is on. Turning it off removes everything Browsemium added.
- "Offer the open page to my other devices" offers the address of the page in
  the active tab (https only) through Handoff. Private windows, locked spaces
  and separate-data spaces never offer anything.
- No AppleScript yet: a safety check of Apple events on a sandboxed app was
  inconclusive, so nothing is shipped until it is finished.

## Experimental: WebMCP page tools

Development source, off by default, verified by automated tests (real WebKit
and an obedient-client injection suite) and an offscreen render only. No live
MCP client or WebMCP site has been tried.

- Settings → External agents → Page tools (WebMCP, experimental). WebMCP is
  an unfinished W3C Community Group draft and WebKit has formally opposed it,
  so the switch is off and the feature never touches your own tabs.
- When on, a task you approved with the new page-tools grant may list and call
  the tools a site registers in the task's own window. Every call asks you,
  names the page as the source of the tool, and shows the exact arguments. A
  site's "read-only" label never skips the question.
- Results and tool descriptions are passed to the agent as untrusted page text.

## Accessibility pass (Plan 9, U9)

Verified by automated tests and source scans. Not checked with VoiceOver,
keyboard-only use or Increase Contrast by hand; see `QUALITY_PASS.md`.

- Every animation in the chrome honours Reduce Motion, including the toolbar
  loading line, the first-run steps, the assistant's page bar and the task
  panel's border pulse. A source scan keeps it that way.
- With Increase Contrast on, text tones, the border and the strong border use
  stronger values, measured against their backgrounds.
- The close button that appears when you hover a tab is also available to
  VoiceOver as a "Close tab" action.
- Settings fields whose placeholder was an example (API key, website, username,
  custom search engine address) now have names.

## Website

- Landing page: a capture of the app window in the hero, labelled as test-fixture
  data; the fallback font is matched to Geist so loading does not shift the page;
  phone targets are 44 px; no horizontal scroll from 375 to 1280 px; motion is
  shorter and is removed entirely with Reduce Motion.
- The AI section and FAQ now mention Apple Intelligence on supported Macs.

## Plan 9: interface

Development source, verified by automated tests and offscreen renders only.

- Text and quiet tones now meet 4.5:1 contrast in light and dark, measured by tests; the dark canvas is darker so panels stand out.
- One type scale replaces seven near-identical text sizes; nothing in the chrome sets text below 11 pt.
- Menus, the command palette, suggestions, the find bar, banners and toasts use Liquid Glass on macOS 26 and later, and a solid surface otherwise or with Reduce Transparency on.
- Compact toolbar size (Settings → General) and a hover-reveal sidebar rail.
- The status toast no longer cuts messages mid-sentence and stays longer for longer messages.
- Command palette: group labels, site icons, kind badges.
- Settings has a section list and a search field.
- Motion goes through one helper that turns every animation off with Reduce Motion.
- New-tab page: a search field that submits through the address bar's own resolver, the current space with a separate-data glyph, larger site tiles with favicons, and a "Pick up where you left off" row from recently closed and archived pages. Pages from locked spaces, or from other spaces' separate data, are never offered. Private windows keep the existing page.
- Sidebar and tab strip: 16 pt site icons, a clearer selected row, pinned tabs in a three-column grid, an insertion line and folder highlight while dragging, a space-switcher row at the sidebar foot (shown only with two or more spaces, never in private windows), a sliding selection pill and insert/remove transitions in the tab strip, and the strip is asked to scroll the active tab into view (not yet seen live). All motion respects Reduce Motion.
- Command palette: a preview pane for the highlighted open tab when the window is wide enough (a tab that is merely loaded is never called asleep), the same result rows as the address bar suggestions, a calculation or unit conversion as the first row (Return copies it), and visible key hints: Return opens, Command-Return opens in a new tab, Shift-Return opens in split view.
