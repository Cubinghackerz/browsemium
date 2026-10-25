# Prompt-injection controls for the agent endpoint

Scope: the opt-in MCP endpoint (`Plans/7-polished-autonomous-workspace.md`).
These controls limit what a hostile page can make a connected client do. They
do not stop a model from being persuaded, and nothing here claims they do.
Every row is exercised by `AgentInjectionContainmentTests` with fourteen page
vectors (visible text, white-on-white, hidden block, aria-label, alt text,
comment, off-screen, cross-origin iframe, title, JSON-LD, link href, fake system
message, tool-result impersonation, marker spelled in another case). An obedient
client does exactly what each page asks.

| What the page tries | Control | Test |
|---|---|---|
| Speak outside the page-content boundary | `read_text` output is wrapped in `<untrusted_page_content>`; any marker spelling inside the text is replaced | `pageTextArrivesInsideAnEnvelopeItCannotEscape`, `theEnvelopeDefangsEveryMarkerSpelling` |
| Send the client to another site | Navigation and redirects are checked against the granted origins; look-alike hosts and `user@host` forms are refused | `anObedientClientCannotLeaveTheGrantedOrigin` |
| Make the client type secrets | Password, card and one-time-code fields are refused, not offered for approval | `anObedientClientCannotTypeIntoSensitiveFields` |
| Reach other tabs | Every tool checks the tab belongs to the task | `anObedientClientCannotActOnTabsOutsideTheTask` |
| Get a consequential click without the person | Every click and type waits for a native confirmation; a decline performs nothing | `aClickTheClientWasTalkedIntoStillNeedsThePersonToApprove` |
| Widen the grant | A second request while a task runs is refused; screenshot and interaction need their own grant | `aClientCannotWidenItsOwnGrantFromPageContent` |

## WebMCP bridge (experimental, off by default)

Researched 2026-10-04 before any code was written.

**The draft.** WebMCP is a Draft Community Group Report from the W3C Web
Machine Learning CG (the version read is dated 2 October 2026). It is not on the
standards track. A page registers tools with `registerTool(tool, options)`;
`tool` has `name` (1–128 of letters, digits, `_`, `-`, `.`), `description`,
optional `inputSchema`, an `execute(input, client)` callback and `annotations`
(`readOnlyHint`, `untrustedContentHint`, `consequentialHint`). The draft's own
security section lists prompt injection, misrepresentation of intent,
over-parameterised privacy leakage, same-origin boundaries and private browsing
as open items. The entry point is unstable: Chrome's origin trial uses
`navigator.modelContext`, while the current draft text and some embedders use
`document.modelContext`. The earlier `provideContext()` and `clearContext()` were
removed in a March 2026 revision.

**WebKit's position.** `WebKit/standards-positions` issue 670 carries
`position: oppose` (filed 28 May 2026, closed 11 June 2026) with concerns about
API design, duplication, i18n, portability, privacy, security, use cases, venue
and meaningful user consent. WebKit's stated view is that a parallel
agent-facing tool layer is the wrong fix and that gaps belong in HTML and ARIA.
Mozilla is neutral. Chrome 149 and Edge 150 run origin trials; Firefox and Safari
do not implement it. The earlier "opposed" claim in `Plans/8-landscape-2026.md`
came from a DEV Community post and is now confirmed against the repository.

**What this means for Browsemium.** Browsemium is a WebKit browser, so shipping
WebMCP in the person's own tabs would put it ahead of WebKit's own position.
The bridge therefore exists only on tabs a granted task opened, never on the
person's tabs (a source-scan test fails if any other file references the shim).
It is off until the person turns on Settings → External agents → Page tools, and
is labelled experimental there. Browsemium is not endorsing the proposal; it is
containing what a page might offer an agent the person already approved.

**What shipped.**
- A document-start script, installed only on task tabs created while the setting
  was on and only in a secure context. It defines `navigator.modelContext` only
  when the property is absent; if anything already defines it, the script does
  nothing, so the bridge never reads tools a native implementation holds. It
  implements `registerTool` and `unregisterTool` only. `getTools`, `executeTool`,
  events and `requestUserInteraction` (which rejects) are not provided, and
  `document.modelContext` is not defined.
- A new `webmcp` grant capability, requested with `allow_page_tools`. It is
  refused before any card is shown when the setting is off, and checked again on
  every call (before the budget is spent and again after the person approves).
- MCP tools `browsemium_page_tool_list` and `browsemium_page_tool_call`, not
  dynamic top-level tools, so the tool list stays fixed.
- Every call asks the person, with the page named as the source, the page's
  description labelled as the page's claim, and the exact arguments (capped at
  1,500 bytes so nothing is hidden behind an ellipsis). The page's
  `readOnlyHint` is passed to the client as a claim and never skips the card;
  this is stricter than the unit plan, which allowed skipping for read-only
  tools, because the hint is advisory and WebKit's critique is about that.
- Arguments must be a JSON object and are checked against the tool's schema
  before the person is asked, with a deliberately small validator
  (`PageToolSchema`: `type`, `enum`, `required`, `properties`,
  `additionalProperties: false`, `items`). Other keywords are ignored, so it can
  accept what a full validator would refuse; the page's own code is the real
  validator.
- The list and every result arrive inside the untrusted envelope. Tools outside
  the limits (invalid or duplicate name, description over 2,000 characters,
  schema over 8 KB, more than 50 tools) are dropped, not truncated. Page
  exception text never reaches the client.

| What the page tries | Control | Test |
|---|---|---|
| Put instructions in a tool description or name | List inside the envelope; invalid names dropped; description shown to the person as the page's claim | `aToolDescriptionCannotEscapeTheEnvelope`, `aToolNameMadeOfInstructionsIsNeverListedOrCalled` |
| Put instructions in a tool result | Result inside the envelope, markers defanged | `aToolResultCannotEscapeTheEnvelope` |
| Call a tool the person never saw or declined | Every call confirms; a declined call runs nothing | `anObedientClientCannotRunAToolThePersonDeclined`, `aReadOnlyHintDoesNotSkipTheConfirmation` |
| Swap the tool after the card is open | The shim compares name, description, schema and a registration counter in the same turn that runs it | `aToolRewrittenWhileTheCardIsOpenIsRefusedAsStale`, `aRewrittenToolIsStaleEvenWithTheSameName` |
| Widen the grant from a result | A result changes no grant | `aPageCannotWidenTheGrantThroughATool` |
| Leave the granted origin during a call | Origin is checked before, after approval and after the call; a result from a page that left is dropped | `aResultFromAPageThatLeftTheGrantIsDropped` |
| Use the feature when Settings has it off | Refused before budget, before the card and after approval | `aSwitchedOffSettingRefusesWithoutSpendingBudget`, `turningTheSettingOffWhileTheCardIsOpenEndsTheCall` |
| Appear in the person's own tabs | Shim installed only by the task actuator | `onlyTheTaskActuatorInstallsTheShim` |
| Replace a native implementation | Script does nothing if the property exists | `anExistingImplementationIsNeverReplacedOrTapped` |

Not covered for WebMCP: the shim runs in the page's world because the page must
call it, so a page can forge or replace anything it reports; the controls above
are what contain that, not the shim. The arguments cannot be inspected for
secrets the way a password field can, so the exact-arguments card is the only
guard. A tool that never returns keeps running in the page after the 15-second
deadline, because script execution cannot be cancelled.

Not covered, by design: a model that is fooled into leaking what it already
read to the page's own origin, or into approving a prompt itself. The grant's
origin list and the person's approval are the boundary.
