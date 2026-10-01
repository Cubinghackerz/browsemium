# Quality pass — 2026-09-30

Changes here are committed source, not a published 2.1.1 release.

## Ad-hoc cycle groundwork — 2026-10-01

- Corrected the unsupported debug-build Inspector claim; Inspector remains
  unimplemented until its setting, engine path, and tests exist.
- Moved palette catalog, tab/recent-tab, intent, library, and ranking builders
  into small value-only providers. Storage reads and dispatch stay in the model;
  unlock filtering occurs before tab row construction. No secret reads were added.
- Existing palette tests: 11 passed unchanged, with no edits to the existing
  UI-model test files. Headless build/runner, full Swift package tests, generated
  app build/test, project verification, and whitespace checks passed.

## Baseline

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
