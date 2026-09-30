# Quality pass — 2026-09-30

Changes here are committed source, not a published 2.1.1 release.

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

## Remaining verification and scope

- Native end-to-end offline navigation, external click/script behavior,
  authentication retries/cancel, WebContent kill/recovery, and light/dark
  appearance are not yet manually verified for these changes.
- Deeper importer, extension extraction/update, AI/privacy, session restore,
  and copy-claim audit is next; this document does not imply those are safe.
- Final headless/project/app-build/app-test/diff gates remain to be run after
  the complete pass. No release was cut; release notes are unchanged.
- Developer ID/notarization and the quiet-machine memory gate remain open.
- No OpenUI scaffold, JavaScript toolchain, sync, telemetry, or Chromium work.
