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

## Remaining gates and queue

The 2026-10-02 memory attempt stopped at the quiet-machine preflight, before
any trials. There are no comparative results to publish. Whole-app native
light/dark QA and logged-in site compatibility checks remain user-run gates.

Per-site extension controls, smart space routing, and the remaining import
units precede the next switchability
and agent-ready features. Native light/dark QA and release gates remain open.
