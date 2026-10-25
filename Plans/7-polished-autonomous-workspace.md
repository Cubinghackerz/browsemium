# Polished workspace and autonomous MCP tasks

Status: approved plan; v1 opt-in preview implemented 2026-10-04 (see below).
Owner confirmed task-scoped autonomy and
asked for full autonomous execution within a grant on 2026-10-03. This replaces
D1 and W5's per-click contract in `7-elara-learnings.md`; W1–W4 and the existing
switching queue retain their order. No built-in agent loop is authorized.

Implementation note (v1). Built: grant model and gate, WebKit actuator,
loopback MCP transport, grant card, task panel with Stop, Settings card, and
revocation on profile switch, space lock, disconnect and quit. Deliberate
deviations from this plan, chosen to fail closed until a safe-action heuristic
exists: (1) every click and type needs a native confirmation instead of
running prompt-free within the grant; (2) task pages open in a dedicated
non-activating panel, not a sidebar space; (3) no SSE stream, GET is 405. The
`network.server` entitlement spike passed in two minimal sandboxed ad-hoc
bundles, so the Unix-socket fallback was not needed.

Update (2026-10-05). Added: Take over / Hand back / Stop controls that work in
every live state (Stop is reachable while paused, so ending a task never needs
the window closed), key equivalents (Option-Command-P for Take over and Hand
back, Option-Command-period for Stop; Command-period is the page Stop in the Navigate menu), a label and a spoken hint on every control, a
VoiceOver announcement when a task is paused, handed back, waiting for an
answer, finished or stopped, and a label on the task page. Gate tests cover a
takeover while a call is in flight, Stop during a takeover, expiry and profile
loss during a takeover. A real `URLSession` client now drives initialize,
tools/list and a declined task against the real loopback listener, and a test
pins the entitlements (no apple-events exception; `network.server` only in the
WebKit app). Every click and type still needs a native confirmation.

Still open, and not claimed: the packaged app's launch-to-endpoint path, a live
MCP client session, and keyboard and VoiceOver QA. Owner checks, in order:
1. Settings → External agents: turn it on, copy the Claude Code command, run it.
   `curl -i -X POST http://127.0.0.1:47831/mcp` should return 401.
2. From the client, request a task for one site. Confirm the card names the
   client as unverified, shows the profile and origins, and the Allow button
   stays disabled for about a second. Decline once; confirm the client sees a
   declined error and no window opens.
3. Request again and allow it. Read a page, then ask for a click: confirm the
   confirmation card appears and nothing happens until you answer.
4. During a pending confirmation, press Take over: the card disappears, the
   client's next call fails, and the pages stay. Press Hand back: the clock kept
   running. Press Stop while paused: the task ends and the pages stay.
5. With VoiceOver on, tab through the panel: each button reads its name and
   hint, and pausing is announced. Try Option-Command-P and Option-Command-period.
6. Switch profile and lock a space during a task: the window closes and the
   client loses access.

## Delivery order

1. AI-dock redesign completed and verified as development source. Native QA
   and release remain open; the unit is committed separately.
2. Preserve W3 → W1 → W2 and the written switching-feature queue. Never land a
   new feature over deliberately failing or unfinished tests.
3. Implement task policy/actuator fixtures, MCP transport, then task presentation
   as separate verified units. Update this status and the matching roadmap after
   each unit; implementation claims must not describe a plan as shipped.

## AI dock

Implementation: connection/empty-state and composer components are verified
development source with six regressions/rendering checks. The render batch is isolated from
timing-sensitive UI-model tests. Native interaction QA and release remain open;
this UI work does not enable MCP. See `QUALITY_PASS.md` for gate evidence.

Keep the native monochrome identity, provider choices and safe Markdown.
Replace the cramped setup row, large dead empty area and scattered composer
tools with a compact header, a readable connection state, useful page actions
and one writing surface. Secure key field minimum height: 40 points. The
composer owns attachments, skills, Review/Stop and an explicit auto-page toggle.
Existing API review-before-send remains; MCP grants are a separate permission
flow. Provider website behavior stays unchanged.

Test 360-, 420- and 560-point widths in light/dark, including short windows,
long labels/drafts, missing credentials, errors, attachments and streaming.
Private/locked pages expose no attachable page context. Preserve keyboard
focus and labelled native controls. No decorative glow or invented progress.
ai.diy is a craft reference, not a dependency or copied interface. Its live site
served a verification challenge; published design notes were inspected instead.

## Task authority and lifecycle

An external MCP client supplies the agent brain. The browser executes granted
tools; it does not run an autonomous model loop of its own. The endpoint is off
by default. One active task in v1, up to four task-owned tabs; serialize actions.

A native grant names the client, task, profile, exact permitted origins and
capabilities. Grant lifetime: 15 minutes or 100 tool calls, whichever comes
first. No permanent approval. Ordinary permitted actions run without a prompt
per click. New origins need grant expansion, including navigation redirects.
Payments, destructive operations and ambiguous consequential submissions retain
explicit confirmation boundaries. Do not treat a task description or an
agent-supplied action label as proof that an operation is safe.

Grant enforcement establishes origin, tool and tab ownership, not the semantic
harmlessness of arbitrary web behavior. Logged-in automation can change account
state; explain that risk before granting. A DOM heuristic cannot guarantee no
purchase, deletion or disclosure. Only known permitted operations may bypass
additional consequential-action review; unknown outcomes pause rather than
being inferred safe from labels. Fixture tests must demonstrate these limits.

Each task gets its own visible space within the selected profile. It shares
that profile's WebKit store for login continuity; this is workspace separation,
not per-space cookie isolation. Never export cookie or credential values.
Agents cannot operate ordinary tabs, private windows or locked spaces, switch
the person's tabs, or take keyboard focus. Profile changes, locking, client
disconnect, app termination and Stop invalidate grants. Human takeover pauses
the task. Normal browsing outside the task space does not interrupt it.

## Interfaces and security

Add pure `AgentTask`, `TaskGrant`, lifecycle state and task ownership types to
Core. Use the planned `PageActuating` EngineKit protocol and a small WebKit
actuator. `AgentActionGate` is the sole path to execution. Model/tool/page output
is untrusted. Check arguments and grant ownership again at execution; re-resolve
element references and reject stale fingerprints. A dedicated WKContentWorld
isolates browser-owned scripts, not the shared DOM or hostile page behavior.

Tools: create/request a task, list task tabs, navigate, snapshot, read text,
click, type, report task status and stop. Screenshots require a separately
visible grant. Exclude arbitrary JavaScript/shell, cookies/storage/credentials,
uploads, password/card/OTP filling and screenshots of other windows. Read and
screenshot grants disclose that the client may forward content to its model.
Do not promise screenshots are automatically free of sensitive information.

Local MCP uses JSON-RPC over loopback HTTP, token authentication, Host checks,
rejection of browser Origin headers, no CORS headers, bounded bodies (256 KiB)
and bounded queues/rates. Tokens live in Keychain; Settings uses `hasSecret`
only. Verify current client configuration and protocol documentation before
implementation. A separate process must round-trip against a sandboxed ad-hoc
build. Add only the required network-server entitlement after that spike. If
loopback binding fails, use a private mode-0600 Unix socket and stdio bridge;
do not weaken unrelated entitlements or expose a network interface.

Audit records are in-memory per run: action, host, result and time, never typed
values, tokens or page contents. No new service or third-party dependency is
required. Keep new logic outside the large window model.

## Presentation and verification

Activity bar: Reading, Acting, Waiting for you, Paused, Finished; Stop and Take
over stay available. Timeline entries describe actual actions/results/errors.
A restrained host-view border identifies task pages; Reduce Motion uses a
static border. Permission cards derive trustworthy labels from the current
page, focus Decline initially, ignore initial accidental keystrokes and never
approve from Return alone. Do not advertise task UI before it is wired.

Tests: expired/out-of-scope grants, redirects, private/locked refusal, stale
elements, sensitive fields, takeover/Stop and queued-work cancellation,
authentication/Origin/Host failures, malformed/oversized requests, and proof
that no actuator call runs without a valid grant. Test unknown consequential
actions fail closed. Use fixtures, never real passwords or browser profiles.

Bug fixes follow red → green → reverted-red. Each unit runs headless validation,
focused/full Swift tests, Xcode Debug build/test, generated-project verification
and whitespace checks. Design inspection is bounded; fixture renders do not
replace native keyboard/VoiceOver or real task QA. Update PRODUCT, MEGAPLAN,
Unreleased and QUALITY_PASS with only completed implementation claims.

Ad-hoc signing and WebKit remain. No accounts, cloud sync, telemetry, CEF work,
unmeasured comparative claim, notarization/passkey promise, or built-in agent
chat. Memory, whole-app QA and signing gates remain separate.
