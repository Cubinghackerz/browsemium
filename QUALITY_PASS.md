# Quality pass — 2026-09-30

Changes here are committed source, not a published 2.1.1 release.

## AI dock workspace — 2026-10-03

- Split connection/empty-state and composer presentation into small files;
  the large window model and AI provider/send implementations are unchanged.
  A 40-point secure key field, page-aware starting actions, grouped attachment
  and skill menus, Review/Stop and clearer transcript spacing replace the
  cramped setup row and scattered composer controls.
- Reproduced the undersized key field and review availability during context
  preparation. Their regression tests passed after the fixes, failed again
  with the two fixes reverted, and the implementation was restored. Private,
  locked, uncommitted and unsupported page eligibility is separately tested.
- Fixture correction, not a production-policy change: locking the only
  unlocked space is deliberately refused. The test creates a second space,
  asserts it actually locked, and checks the original tab cannot be shared.
  Render fixtures lay out the hosting view before polling for its startup
  credential check; no deadline was shortened or assertion removed.
- Twelve synthetic light/dark renders cover 360-, 420- and 560-point widths,
  a short error/attachment state, private pages, connected conversation and
  streaming. These are rendering smoke tests, not pixel-diff baselines or
  interactive keyboard/VoiceOver QA. No real key or browser profile is used.
  Native SwiftUI is outside the web detector's coverage; no new suppression
  was added. Independent review found an unavailable-page prompt mismatch and
  a clipped short-window welcome. Context-aware copy and a compact fallback
  fixed them; a subsequent height regression was caught with a 280-point
  fitting-budget test (300 points before correction, red → green → reverted-red).
  The reviewer scored those two fixes and the introduced regression resolved;
  that verdict covers its fix list, not live interactions.
- Final-suite triage reproduced `anOpenPeekIsNeverReplacedByHovering` timing
  out while twelve native renders shared its main-actor test process. The
  fixture batch now runs in a separate `BrowsemiumAIDockRenderingTests` target
  registered in both SwiftPM and `project.yml`. All six new tests still run;
  no existing assertion, 20-second wait or 700 ms product debounce changed.
  The full package suite passed afterward; the unchanged hover test completed
  in about eight seconds. Headless build/runner, the full package suite,
  regenerated Xcode Debug build/test, project verification and whitespace
  checks passed after the test-target change. Xcode recorded 439 distinct
  passing tests (484 parameterized runs), with zero failures/skips. Native
  keyboard/VoiceOver and whole-app QA remain separately open.
- `DESIGN.md` and its schema-2 sidecar document the existing native palette and
  controls, not a new identity or runtime web UI. Local render artifacts are
  ignored. The user's untracked `HANDOFF.md` remains unchanged.
- The approved task-scoped autonomous MCP direction is saved separately in
  `Plans/7-polished-autonomous-workspace.md`. No endpoint, actuator or agent
  control is enabled here. Existing API review-before-send remains intact.
- Installed and launched the tested development app at
  `/Applications/Browsemium.app` (still 2.1.0/210, ad-hoc). Its signature verifies;
  file hashes and symlink targets match the Debug product. The previous app is
  recoverable at `/Applications/.browsemium-install.0lKPiS/Previous Browsemium.app`.

## Ad-hoc cycle groundwork — 2026-10-01

- Corrected the unsupported debug-build Inspector claim; Inspector remains
  unimplemented until its setting, engine path, and tests exist.
- Moved palette catalog, tab/recent-tab, intent, library, and ranking builders
  into small value-only providers. Storage reads and dispatch stay in the model;
  unlock filtering occurs before tab row construction. No secret reads were added.
- Existing palette tests: 11 passed unchanged, with no edits to the existing
  UI-model test files. Headless build/runner, full Swift package tests, generated
  app build/test, project verification, and whitespace checks passed.

## Palette page actions — 2026-10-01

- Added print, find in page, Reader mode, and hide element catalog rows with
  the existing menu shortcuts. Each dispatches to its existing page action;
  Inspect remains absent until the Inspector implementation ships.
- Six new tests (including four discovery cases) verify exact command mappings,
  shortcuts, empty-query discovery, active-tab print targeting, find-bar opening,
  explicit picker activation without saving, and Reader failure handling.
- Debugging evidence: the tests failed on missing rows, passed after the fix,
  failed again with the catalog additions reverted, then passed after restoration.
  No existing regression assertions were weakened or skipped.
- Headless build/runner, the full Swift package suite, generated app build/test,
  project verification, and final source/whitespace review passed. The generated
  project adds only registration of the new regression test file. Native
  light/dark palette QA is not claimed by these automated checks.

## Password import recovery — 2026-10-01

- Root cause: explicit import used an interactive source-key query, producing
  the source browser's Safe Storage authorization dialog. A new read boundary
  uses `LAContext.interactionNotAllowed` and the legacy Keychain fail-UI policy;
  accountless fallback remains noninteractive and only follows item-not-found.
  Unsupported test/custom backends fail closed rather than retry interactively.
- All nine Chromium sources use that boundary. Denied, missing, and unavailable
  keys become a recovery message without importing anything. Source keys and
  their ACLs are never changed. Settings presence checks still use attributes.
- The browser preview offers CSV recovery, preserving the selected destination.
  The destination is captured before opening a file picker; cancel/empty input
  creates no profile. CSV import reads no source key, writes only to the selected
  profile's credential vault, and warns that the exported CSV is unencrypted.
- Also reproduced password corruption caused by trimming whitespace at the
  vault write. Password-specific writes preserve bytes; API-key writes keep their
  previous normalization. Generated Chrome/Firefox/Apple CSV fixtures verify
  destination isolation, idempotent re-import, no secret reads, and fidelity.
- Regression evidence: interactive reads and whitespace loss failed before
  fixes; all focused checks passed; reverting the no-UI policies, destination
  selection, and password write caused their checks to fail again. Fixes restored.
- Light/dark fixture renders of the recovery and CSV sheets were inspected;
  counts/destination/recovery controls were legible and no password was shown.
  These are rendering smoke tests, not pixel-diff baselines or live Keychain QA.
  The design detector reported no findings and no suppressions were added.
- Headless build/runner, the full Swift package suite, generated app build/test,
  project verification, and final source/whitespace review passed. Xcode reported
  395 distinct passing tests (436 parameterized runs), with no failures or skips.
  An unexpected compiler-driver console diagnostic was checked against the saved
  result: the build succeeded with zero errors and only deprecation warnings.
  No real browser profile, password, or source-Keychain item was read. Native
  file-picker/sheet sequencing and source permission states remain manual QA;
  a CSV route cannot transfer cookies.
- The legacy fail-UI constant produces a known deprecation warning. It is kept
  deliberately alongside the modern context for source keys in the file-based
  login Keychain; no warnings or tests are globally suppressed.

## Claim-gate preflight — 2026-10-02

- Installed the verified password-import development build in Applications;
  its file hashes and symlink targets match the tested Debug product, and its
  ad-hoc code signature verifies. The previous app remains a rollback copy.
- Ignored local `.playwright-mcp/` artifacts. Reviewed the narrow Geist ignore:
  it records the owner's explicit brand choice, not a blanket design exemption.
  The superseded, untracked `HANDOFF.md` is left unchanged.
- Ran the unchanged memory harness with five trials and a 60-second settle.
  Preflight refused with exit 3: three WebKit processes were already running.
  Chrome was also open. No trials or memory figures were produced; the 20%
  gate remains open. Other apps were not quit and the method was not changed.
- User-run native QA remains pending in both appearances: New Tab, sidebar,
  palette, Settings, import sheets, private window, and locked space. Fixture
  rendering and automated tests are not evidence of this whole-app walkthrough.

## User filter list runtime — 2026-10-02

- Extended the existing rule manager to install the enabled set atomically;
  compile receipts bind to the manager and profile generation. JSON validation,
  conversion, and repository preparation run off the main actor. WebKit uses
  its asynchronous compiler. No new dependency or bundled filter list was added.
- The profile-local coordinator restores persisted lists on launch/switch,
  requires successful restoration before edits, and checks cancellation,
  profile generation, and private-mode authorization before the revision-checked
  database commit. Failure retains the working runtime set. Global blocking
  and per-site pause/protection gates apply to the complete set.
- Thirteen new fixture tests cover real WebKit compilation/rejection and
  application calls, sanitized failures, last-good retention, mismatched
  identifiers, cancellation, profile/private isolation, mid-compile private
  mode, and revisions changed while compiling. No remote source was fetched.
- The tests initially failed on missing runtime/coordinator APIs. They passed
  with implementation; removing the generation, receipt, global-toggle,
  restoration, and private-write guards caused seven tests to fail again.
  Guards were restored without weakening assertions. Headless build/runner,
  the full Swift package suite, Xcode Debug build/test, project verification,
  and whitespace/source review passed. Saved Xcode results show 408 distinct
  passing tests (450 parameterized runs), zero failures/skips, and zero build
  errors. No assertion was weakened or test skipped.
- This runtime-only unit preceded the ingestion/Settings unit below. No native
  loading/error/light/dark interaction QA is claimed by its automated tests.

## User filter list ingestion and Settings — 2026-10-02

- Added bounded regular-file reads and HTTPS downloads with cookie, credential,
  and cache stores disabled. Initial, redirected, and final URLs are checked;
  non-trust authentication challenges are cancelled, while system certificate
  validation is unchanged. Input errors omit source contents and addresses.
- Added native Settings import/re-import, enable/disable, and confirmed removal.
  Sources are transient, not subscriptions. Counts describe supported/skipped
  rules, not blocked requests. Existing Theme tokens and Settings components
  are reused; no new dependency, bundled list, or large-model logic was added.
- Review reproduced two draft operation races: duplicate actions replaced the
  task handle, and an old completion cleared a newer busy state. Ownership and
  duplicate guards fixed both. Final-response HTTPS validation and stale
  displayed toggle/removal transactions have regression coverage. Removing
  these guards made four tests fail again; restored without weakening tests.
- Generated fixtures cover file bounds/encoding/symlinks, HTTPS validation,
  redirect policy, stream/header byte ceilings, sanitized failures, cancellation,
  private write refusal, import/toggle/removal, and light/dark rendering. No real
  browser profile, password, or remote source was read. Eight fixture renders
  were inspected in two rounds; these are smoke checks, not pixel-diff or native
  interaction QA. The fresh finish review led to higher-contrast error text,
  list-specific accessible action labels, and incumbent monochrome controls.
- A misplaced revision guard while restoring reverted-red code caused a build
  failure. It was moved into the transaction's revision check; the unchanged
  focused regression then passed. No failure was ignored or assertion changed.
- Headless build/runner, the full Swift package suite, Xcode Debug build/test,
  generated-project verification, and whitespace review passed. Saved Xcode
  results show 421 distinct passing tests (466 parameterized runs), zero
  failures/skips, and zero build errors. The two new rendering checks pass in
  the Swift package suite (the snapshot suite is not an Xcode scheme target).
  Two existing legacy no-interaction Keychain assertion deprecation warnings
  remain; no security guard was removed to silence them. User-run native
  picker/keyboard/VoiceOver and whole-app light/dark QA remain pending; no
  release or memory claim follows.
- Installed and relaunched the tested ad-hoc Debug product in Applications.
  File hashes and symlink targets match the tested product; code-signature
  verification passed. The previous app is recoverable at
  `/Applications/.browsemium-install.pQ1Cik/Previous Browsemium.app`.
  Version/build remain 2.1.0/210; this is not a published release.

## Site shield list sizes — 2026-10-03

- Audit corrected the plan's 87-host assumption: the starter list has 87 rules
  naming 71 distinct target hosts. Path/script rules name no host. User-list
  receipts retain parsed host sets; installed sizes deduplicate across enabled
  lists and exclude overlap with starter hosts. Exceptions can name hosts too.
  Unknown formats report unavailable, never an invented count.
- Fixed inactive/failed state copy, paused-state numbers, and the stale pause
  explanation that mentioned bundled rules only. The manager is observable so
  installed-list changes invalidate the shield. No request metric, network
  call, credential read, dependency, or bundled third-party list was added.
- Twelve fixture tests cover parsing, actual WebKit compilation, deduplication,
  profile changes, disabling, failed-compile retention, observation invalidation,
  private/off/paused/unknown states, sanitized copy, model wiring, and light/dark
  rendering. The original pause copy failed its regression. After implementation
  passed, reverting host totals, observation, pause handling, inactive copy, and
  pause explanation made six tests fail again. Fixes restored unchanged tests.
- Initial focused compilation caught an incorrect enum case and a Swift Testing
  macro/key-path spelling issue in the new tests. Corrected both without weakening
  assertions. Headless build/runner, focused tests, full Swift package suite,
  Xcode Debug build/test, project verification, and whitespace review passed.
  Saved Xcode results show 433 distinct passing tests (478 parameterized runs),
  zero failures/skips, and no runtime warnings. Xcode itself emitted diagnostic
  launch-session warnings; these did not fail a gate or require a code change.
- Eight light/dark active/paused fixture renders were inspected in two rounds.
  The first caught the stale pause explanation, corrected before the second.
  Existing native layout, Theme tokens, controls, and brand were preserved.
  This native SwiftUI change has no HTML/CSS detector target; no design ignore
  was added. No native keyboard, VoiceOver, or whole-app interaction QA is claimed.
- Installed and launched the tested ad-hoc Debug product in Applications.
  File hashes and symlink targets match; code-signature verification passed.
  The previous app is recoverable at
  `/Applications/.browsemium-install.T3hkh3/Previous Browsemium.app`.
  Version/build remain 2.1.0/210, not a published release. User checklist:
  open the shield in light/dark; confirm the starter size and enabled user-list
  delta; pause/unpause; toggle a list in Settings and reopen the shield. Keyboard,
  VoiceOver, private/off states, and whole-app QA remain user-run checks.

## Initial baseline checks

- No stale SwiftPM test processes were found.
- Headless runner: passed.
- Full Swift package tests: passed.
- XcodeGen and project verification: passed.
- Debug app build: passed.
- Initial worktree: only the user's untracked `HANDOFF.md`.

## Confirmed defects

| Unit | Root cause and fix | Regression evidence |
| --- | --- | --- |
| A1 | `.failed` classified a committed document as crashed. Restore `.active`; keep process termination as `.crashed`. | Runtime event regression failed, passed with fix, failed with fix reverted. |
| A2 | Non-HTTP navigation unconditionally requested an external launch. Apply gesture/frame/scheme policy before download handling; report blocked launches. | Table-driven policy tests failed against the extracted legacy unconditional-open policy, passed with fix, failed after reverting the dangerous-scheme rule. Window-model blocked-status test passed. |
| A3 | No HTTP challenge handler existed. Basic/Digest/NTLM prompt; other methods retain platform handling. Credentials have `.none` persistence. | Prompt-policy regressions failed against default-only handling, passed with fix, failed with prompt decision reverted. Certificate/default companion cases passed. |
| A4 | Process termination only showed an error. Retry the active non-preview tab once per 60 seconds; forget closed-tab attempts. | Fake-engine reload regression failed, passed with fix, failed with reload disabled. Background, preview, expiry, and cleanup companion cases passed. |
| A5 | Five write sites discarded errors. Report failures without stopping tab close, permission answers, or completed downloads. | All five fixture-trigger regressions failed, passed with fix, failed with status reporting reverted. |

The full Swift package suite passed after A. Error classification companions
cover DNS, offline, and certificate failures. Persistence logs contain only a
trusted operation label plus error domain/code, not descriptions or SQL bindings.

## Test reliability and hygiene

- Converted 13 fixed condition-wait sleep sites: seven locked-space, three
  extension-permission, and three element-picker/rule-update sites.
- Kept the five hover-debounce timing sleep sites and existing condition-poll
  sleeps. Polling ceilings remain 15–20 seconds where already established.
- The abandoned-unlock test now suspends and explicitly resolves its fake
  authenticator; it does not infer completion from elapsed time.
- Each in-memory environment owns an isolated defaults suite, cleaned up on
  disposal. Model writes, app-view preferences, AI notice state, SwiftUI
  `AppStorage`, and import bookmarks use the injected store. Live apps still
  default to the standard domain. Isolation regression failed before the fix,
  passed afterward, and failed again with the standard store restored.
- Full Swift package suite after B: passed.
- Removed the unreferenced root `terminated-landing.png`; recoverable in git
  history. Prepended the requested supersession line to the user's untracked
  `HANDOFF.md`, without committing that file.

## Deeper audit: importer

- Reviewed profile discovery/resolution, preview/apply, login and cookie
  reads, search-engine parsing, SQLite copy/WAL handling, and import SQL.
- Confirmed escaping profile/artifact symlinks with generated fixtures.
  Discovery now rejects out-of-root profiles; preview and apply reject linked
  artifacts (including WAL/SHM) before writes. Metadata reads reject linked
  files. Safari cookie lookup no longer infers grants to other live stores
  from the selected profile. Three abuse regressions passed with the fix and
  failed again with the containment/artifact guard reverted.
- Fixed a compatibility failure introduced during hardening: existing
  `/private` aliases and missing optional files normalize differently in
  Foundation. Resolve the existing root once and inspect relative components.
  The existing parent-folder regression and new minimal case now pass.
- Keychain-denial copy falsely claimed a partial import succeeded; it now
  correctly says nothing was imported. Message regression failed against the
  old wording and passed with the correction.
- SQL in the reviewed importer is static; no source-controlled SQL
  interpolation found. Preview does not invoke the Safe Storage provider;
  apply requests it only for explicitly selected password/cookie import.
  No value logging was found in this file. Existing live-WAL fixture passed.
- Limits: sequential DB/WAL copying is not an atomic concurrent-writer
  snapshot; changed sources can require a retry. Path checks do not constitute
  descriptor-based protection against a malicious concurrent filesystem swap.
  No real source profile or credential was opened for this audit.

## Deeper audit: extensions

- Reviewed extension load/unload, action/permission callbacks and adapters;
  manifest/CRX parsing; store path construction, installation, replacement,
  removal, and symlink scanning. Private views are configured without an
  extension controller.
- Confirmed and fixed hidden symlink acceptance, replaced unpacked-payload
  links, and identifier-directory links. Hidden files are now included in
  validation, installed unpacked payloads are revalidated, and linked source,
  archive, and identifier paths are refused.
- Confirmed that double failure (commit and rollback) deleted the old copy.
  A small transaction helper now preserves the backup and reports a recovery
  error. Successful rollback and normal reinstall companion tests passed.
- Four bug-specific regressions passed with fixes and failed again with the
  guards/backup retention reverted. No real extension was opened or changed.
- Limits: ZIP/CRX payloads are passed to WebKit, not extracted by Browsemium;
  there is no application archive-entry preflight yet. CRX signatures are not
  verified by this code. Platform unload errors remain unverified, and the
  current host discards them. Concurrent local filesystem replacement is not
  covered by these path-based checks.
- Confirmed that the model bridge exposed private tab metadata and permitted
  navigation/closure of locked-space tabs. A small access policy now guards
  reads and mutations; private models do not replace the shared host bridge.
  Host window/adaptor callbacks also reject private sessions. Both regressions
  passed with the fix and failed again with the access policy reverted.
  Normal bridge operations, permission continuations, and ephemeral WebView
  controller exclusion passed. An introduced continuation return-type build
  error was diagnosed and fixed; no test was skipped.
- Final review found cached action buttons and extension Options still
  reachable in private windows. Private entry/refresh now clears actions;
  action invocation, menus, Options, presenter registration, and strip
  notifications reject private sessions. Fixture regression passed and failed
  again with the action/Options guards removed; normal toolbar/bridge
  companions passed.

## Deeper audit: AI context

- Confirmed private/locked single-page capture and private multi-tab capture.
  A small policy now checks membership, privacy, and lock state before and
  after async capture. Web preparation omits inaccessible metadata and text;
  selection-menu capture uses the same policy. Dock context is invalidated
  when privacy/space/unlock state changes.
- Confirmed private windows could restore persistent AI conversations. They
  no longer list, restore, delete, or persist those conversations. The dock is
  bound weakly to its window; unbound capture fails closed. Three regressions
  passed and failed again when the guards were reverted. Normal unlocked
  capture and existing quick-action companions passed.
- Metadata initialization is failable; an introduced nested-optional compile
  error was localized and fixed with `flatMap`, without relaxing a test.
- Credential presence uses `hasSecret`; secret reads remain explicit connect,
  model-loading, or send operations. Reviewed markdown drops non-HTTP(S)
  destinations; its native URL handler now also validates the scheme.
- Provider panels always requested persistent storage, including private
  windows, and relied on the factory's global profile identifier. Panels now
  use ephemeral storage in private windows and an explicit profile identifier
  otherwise. Scope changes release old panels and pending/trusted URLs. A
  mismatched global extension controller is not attached. Both storage
  regressions passed and failed again with legacy configuration restored.
- Confirmed that readable/selection attachment source URLs reintroduced
  credentials, queries, and fragments that metadata had removed. Request
  construction now sanitizes source attributes for both attachment types.
  Regression passed and failed again when raw URLs were restored. Existing
  escaping/capping assertions remain intact: their fixtures use a title with
  an ampersand and a long path, rather than relying on sharing query values.

## Session/privacy and claim check

| Claim | Reviewed implementation and limits |
| --- | --- |
| Local browser records; no product telemetry/account/sync | ProfileStore and repository writes are local. Reviewed network call sites cover websites, search, favicons, extension downloads, and selected AI providers; no product telemetry path was found in the scoped grep. This is not a dependency-wide network audit. |
| Separate profiles; private browsing | Profile databases and identified WebKit stores are separate. Private runtime selection is ephemeral; history, session, and closed-tab writes have private guards. Existing incognito tests cover these paths. AI panels now use explicit profile/private storage too. |
| Locked-space restore and palette | `sessionLandingUnlocked` selects an unlocked landing space; tab/recent palette rows filter locked spaces. Stored session/history metadata remains local and unencrypted; locks are not an at-rest security boundary. |
| AI context and credentials | Metadata strips URL credentials/query/fragment; capture and request builders bound text; request-boundary source URLs now use the same sanitizer. Key presence checks use attributes-only `hasSecret`. Page text/files can contain secrets and are not generally redacted. |
| AI review | Native API mode has a review sheet. Provider-website mode enriches the user's composer send, without a separate native review sheet. Corrected Site/PRODUCT/PRIVACY wording and the overbroad Settings network assurance. |
| Profile deletion | WebKit store and Keychain deletions are requested; ProfileStore discards individual file-removal errors. Narrowed PRIVACY wording to disclose possible remnants and backups, not claim secure erasure. |
| Memory and installation | Memory UI uses ProcessMemory with its scope stated; no comparative claim added. Installer checks and ad-hoc/not-notarized wording are preserved. Manifest/checksum and CI gates were already verified and were not re-audited. |

- Geist is intentional in the user's brand brief; suppressed only
  `overused-font=Geist` through hook-admin, with the evidence recorded. No
  rule/file-wide suppression. The one mechanical Site scan reported no
  findings, but ran in degraded regex mode: computed contrast/layout were
  not verified by that tool.
- Review was direct, one relevant function group at a time. No private user
  profile, imported secret, provider credential, or live extension was read.
- Full Swift package suite after Workstream E: passed, including importer
  containment/WAL fixtures, extension rollback/privacy, AI source/link checks,
  locked-space launch/palette tests, and incognito record guards.

## Final automated verification

- Headless runner after the core/policy fixes: passed.
- XcodeGen and `Scripts/verify-project.sh`: passed. Generated project changes
  register the new sources/tests; no generated project was edited manually.
- Debug app build: passed. The final Xcode test rebuilt the latest app after
  the extra private-window action fix and passed: **351 tests, zero failures,
  zero skipped tests** (373 executions including dynamic parameter cases).
  Counts were checked in the result bundle, not inferred from exit status.
- Full Swift package suite after A, B, and the deeper E changes: passed. The
  final extra UI guard was checked focused red/green/reverted-red and covered
  by the final Xcode UI test target. No failing test was skipped or weakened.
- `git diff --check`: passed. Generated dependency-resolution churn is absent.
- Latest DerivedData app launched successfully with a fresh profile under
  the app container's `Data/tmp/browsemium-quality-Nn3KvH`. Its running process
  holds that fixture database; it did not fall back to the user's database or
  an in-memory store. Browser left open. No real profile was inspected.

## Remaining verification and scope

- Native end-to-end offline navigation, external click/script behavior,
  authentication retries/cancel, WebContent kill/recovery, and light/dark
  appearance are not yet manually verified for these changes. Screen Recording
  and Accessibility preflight both returned unavailable; permissions were not
  changed and no whole-screen capture was attempted.
- The reviewed areas and concrete fixes are listed above; this is not a
  whole-codebase security certification. Archive signatures/entry preflight,
  atomic concurrent import snapshots, and filesystem-swap defense remain open.
- The local-site browser tool failed before execution because its environment
  metadata lacked `sandboxPolicy`; a minimal retry failed the same way. No
  browser screenshots or desktop/mobile color-scheme checks are claimed.
- Settings' no-Keychain-prompt guarantee was checked in presence-query code,
  not manually exercised through the native Settings UI in this environment.
- Next feature units are scoped in `Plans/` and linked from `MEGAPLAN.md`;
  smart routing, user lists, per-site extension controls, and the remaining
  import work have not been implemented by this quality pass.
- No release was cut; release notes and the installer manifest are unchanged.
- Developer ID/notarization and the quiet-machine memory gate remain open.
- No OpenUI scaffold, JavaScript toolchain, sync, telemetry, or Chromium work.
