# Plan 9 — UI findings from the whole-window renders (2026-10-04)

Source: `.impeccable/review/app/*.png` (regenerate with
`BROWSEMIUM_WRITE_UI_SNAPSHOTS=1 swift test --package-path Packages/BrowsemiumKit --filter theWindowRendersInEveryRepresentativeState`).
Web content is blank in these renders and favicons are letter fallbacks;
neither is a UI defect.

| # | Finding | Where | Unit |
|---|---|---|---|
| 1 | Ten tabs show five, each cut to "Swift c…", "Pull re…", with horizontal scrolling; the active tab can be off screen | `BrowserTabStrip.swift` | U2/U6 |
| 2 | Two stacked chrome rows (tab strip + toolbar) before any content | `BrowsemiumAppView.swift` | U2 |
| 3 | The assistant dock opens at a third of the window with an empty body, taking space from the page | `AIDockView.swift` | U2 |
| 4 | Status toast truncates mid-word ("…choose Capt…") | `ToastView` | U1 |
| 5 | Palette repeats a page as both a tab row and a command row ("New Tab" twice), uses generic glyphs instead of favicons, has no group labels, and a monospaced host column | `CommandPaletteView.swift` | U5 |
| 6 | Dark mode: canvas, panel and page are near-identical grays, so panel edges nearly vanish; toolbar glyphs are low contrast | `Theme.swift` | U1/U3 |
| 7 | Every overlay is a flat solid rectangle with a hairline | overlays | U3 |
| 8 | Selected sidebar row is a faint tint; the only color in the chrome is the Google "G" | `TabSidebar.swift` | U6 |

## Status — 2026-10-04

Verified by the package suite and the regenerated renders in
`.impeccable/review/app/`; nothing was run in a live window, so glass, hover
reveal and motion still need native QA.

| Unit | State |
|---|---|
| U0 baseline renders and findings | done |
| U1 contrast and type tokens | done: text tones fixed and measured; 306 sizes moved to `BrowserType`; source-scan guard |
| U2 compact chrome | done as opt-in: slimmer rows, bookmarks bar on start page only, hover-reveal sidebar. Saves about 15 pt per row pair and 31 pt more with the bookmarks bar; the plan's "≥ 40 pt" was not reached without removing a row |
| U3 glass overlays | done for menus, palette, suggestions, find bar, banners, toasts; peek stays solid because it holds page content |
| U4 motion | done in code: `BrowserMotion`, symbol transitions, audio indicator, a matched-geometry selection pill and insert/remove transitions in the tab strip, animated folder disclosure. A source-scan test fails on any literal animation in those files. The pill is verified in a render (`ten-tabs-selected`); the animations themselves, and the strip scrolling to the active tab, were not seen live (the offscreen host does not scroll) |
| U5 palette | done in code: group labels, favicons, kind badges; a preview pane for the highlighted open tab (264 pt, the card's own width, shown only when the window has room) whose note follows the tab's real lifecycle — only hibernated or suspended tabs are called asleep; one shared `SuggestionRow` used by the palette and the address suggestions; a quick answer as the first row (Return copies, nothing navigates); visible key hints with ⌘↩ (open in a new tab) and ⇧↩ (open in split) as real shortcut buttons. 11 new tests plus palette renders. The shortcuts firing while the search field has focus, and the pane's live snapshot, were not exercised live |
| U6 sidebar and spaces | done in code: 16 pt favicons through one shared `TabFaviconView`, a clearer selected row (stronger border plus a leading bar), insertion-line and folder drop feedback, pinned tabs in a 3-column grid, and a space-switcher row (colored circles, lock and `person.crop.square` glyphs, shown only with 2+ spaces and never in private windows). 8 layout tests plus renders (`sidebar`, `sidebar-pinned-spaces`); a locked space is covered by unit tests only, not rendered, and drag feedback was not exercised live |
| U7 Settings | done: seven sections, search across cards, narrow-window row |
| U8 new-tab page | done: search-first field (submits through the address bar's own resolver), space header with a separate-data glyph, 96×84 favicon tiles with a letter fallback, and a "Pick up where you left off" row from recently closed and the Archive. Private variant unchanged. 11 tests plus start-page renders (`new-tab`, `new-tab-sites`, `new-tab-recents`, `private`); typing, focus and hover not exercised live |
| U9 accessibility | partial, in code: every icon-only button labelled and every animation gated by Reduce Motion (both source-scanned); the hover-only tab close button has a VoiceOver action; Increase Contrast values for text and borders, tested by value (the live switch is owner QA); labels on settings fields whose placeholders were examples; Reduce Transparency was already respected by overlays. Not done: keyboard reach to tab rows, a focus-order walk, and the hand checks, all listed for the owner in `QUALITY_PASS.md` |
| U10 docs | done: `DESIGN.md` |

## Landing page (`Site/index.html`), 2026-10-05

Applied from the landing-page playbook where the project allowed it. The repo's
`DESIGN.md` governs colour and type, so the playbook's accent colours, shaders
and third-party libraries were not adopted.

- **Hero product visual.** A capture of the real window from the app's test
  fixtures (`Site/images/browsemium-window-{light,dark}.png`, 1600 px), labelled
  on the page as fixture data, not a live session.
- **Font fallback matched to Geist, measured in Chromium.** Geist's line box is
  1.30 em and its width is 102.2% of Arial's. The fallback face sets
  `size-adjust: 102.2%`, `ascent-override: 98.8%`, `descent-override: 28.4%`.
  The vertical overrides are divided by the size adjustment because the browser
  scales them with it. Result: width within 0.09% of Geist, line box identical.
- **Contrast, measured from computed colours.** The lowest body-size text is
  13 px tertiary text at 5.02:1 (light) and 6.07:1 (dark). Nav links, body and
  controls are higher.
- **Layout.** No horizontal overflow at 375, 390, 768 and 1280 px. Phone spec
  rows stack label over value. Commands wrap at URL slashes (invisible `<wbr>`)
  instead of breaking mid-word. Coarse pointers get 44 px targets. Hover effects
  sit inside `(hover: hover)`. Anchored sections clear the 64 px header through
  `scroll-margin-top`; the CSS value is verified, the hash jump itself was not.
- **Motion.** UI durations are 120 to 260 ms. Entrance and load motion is ease-out
  and the hero sequence ends within about 1.5 s. Press feedback on the copy
  buttons and the nav Install link. Nothing animates layout properties. All motion sits behind
  `prefers-reduced-motion: no-preference`, so reduced motion shows the final state.
- **Accessibility.** One `h1`, headings in order, a live region announces copy
  results, and the copy buttons have specific names.
- **Copy and claims.** The AI row and FAQ now mention Apple Intelligence (on
  supported Macs, no key), which `PRODUCT.md` describes. Nothing else changed.
- **Not added, on purpose.** Bento grid, three-step section, pricing and
  testimonials. The page has no real content for them, and a card grid would
  reproduce the anti-slop pattern the playbook warns against.

Not verified: the reduced-motion path (the browser pane cannot emulate the
preference; the CSS was reviewed), layout shift on a real network, the successful
clipboard path (the pane denied clipboard access, so the failure path was tested),
and Lighthouse or other automated audits, which were not run.

