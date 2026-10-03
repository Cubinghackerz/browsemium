# Polished workspace and autonomous MCP tasks

Status: approved plan, not shipped. Owner confirmed task-scoped autonomy and
asked for full autonomous execution within a grant on 2026-10-03. This replaces
D1 and W5's per-click contract in `7-elara-learnings.md`; W1–W4 and the existing
switching queue retain their order. No built-in agent loop is authorized.

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
