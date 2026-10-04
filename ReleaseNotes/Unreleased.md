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
