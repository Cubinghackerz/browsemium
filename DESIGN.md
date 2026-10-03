---
name: Browsemium native macOS
description: Restrained monochrome browser chrome with native task clarity.
colors:
  browsemium-canvas-light: "rgb(90.2% 90.2% 90.2%)"
  browsemium-canvas-dark: "rgb(10.6% 10.6% 10.6%)"
  browsemium-surface-light: "rgb(94.9% 94.9% 94.9%)"
  browsemium-surface-dark: "rgb(11% 11% 11%)"
  browsemium-raised-light: "rgb(97.6% 97.6% 97.6%)"
  browsemium-raised-dark: "rgb(13.7% 13.7% 13.7%)"
  browsemium-border-light: "rgb(0 0 0 / 0.10)"
  browsemium-border-dark: "rgb(255 255 255 / 0.09)"
  browsemium-border-strong-light: "rgb(0 0 0 / 0.18)"
  browsemium-border-strong-dark: "rgb(255 255 255 / 0.16)"
  browsemium-primary-light: "rgb(0 0 0 / 0.88)"
  browsemium-primary-dark: "rgb(255 255 255 / 0.90)"
  browsemium-secondary-light: "rgb(0 0 0 / 0.56)"
  browsemium-secondary-dark: "rgb(255 255 255 / 0.56)"
  browsemium-tertiary-light: "rgb(0 0 0 / 0.38)"
  browsemium-tertiary-dark: "rgb(255 255 255 / 0.36)"
  browsemium-accent-light: "rgb(0 0 0 / 0.92)"
  browsemium-accent-dark: "rgb(255 255 255 / 0.95)"
  browsemium-accent-fill-light: "rgb(11% 11% 11%)"
  browsemium-accent-fill-dark: "rgb(92% 92% 92%)"
  browsemium-accent-fill-text-light: "rgb(98% 98% 98%)"
  browsemium-accent-fill-text-dark: "rgb(11% 11% 11%)"
  browsemium-hover-light: "rgb(0 0 0 / 0.055)"
  browsemium-hover-dark: "rgb(255 255 255 / 0.065)"
  browsemium-selection-light: "rgb(0 0 0 / 0.09)"
  browsemium-selection-dark: "rgb(255 255 255 / 0.10)"
  browsemium-field-light: "rgb(0 0 0 / 0.045)"
  browsemium-field-dark: "rgb(255 255 255 / 0.055)"
  browsemium-destructive-light: "rgb(76% 16% 16%)"
  browsemium-destructive-dark: "rgb(94% 42% 42%)"
  browsemium-warning-light: "rgb(60% 40% 2%)"
  browsemium-warning-dark: "rgb(88% 68% 30%)"
  browsemium-success-light: "rgb(13% 45% 25%)"
  browsemium-success-dark: "rgb(44% 76% 55%)"
typography:
  body:
    fontFamily: "system-ui"
    fontSize: "13pt"
    fontWeight: 400
  label:
    fontFamily: "system-ui"
    fontSize: "12pt"
    fontWeight: 500
  section:
    fontFamily: "system-ui"
    fontSize: "11pt"
    fontWeight: 600
  empty-title:
    fontFamily: "system-ui"
    fontSize: "13pt"
    fontWeight: 500
  wordmark:
    fontFamily: "Geist-SemiBold"
    fontSize: "17pt"
    letterSpacing: "-0.34pt"
rounded:
  control: "8pt"
  panel: "10pt"
  overlay: "10pt"
spacing:
  element-separation: "8pt"
  window-edge-inset: "12pt"
  tab-strip-top-inset: "6pt"
  titlebar-leading-inset: "78pt"
  sidebar-traffic-light-inset: "34pt"
components:
  primary-button-light:
    backgroundColor: "{colors.browsemium-accent-fill-light}"
    textColor: "{colors.browsemium-accent-fill-text-light}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "0 12pt"
    height: "26pt"
  primary-button-dark:
    backgroundColor: "{colors.browsemium-accent-fill-dark}"
    textColor: "{colors.browsemium-accent-fill-text-dark}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "0 12pt"
    height: "26pt"
  icon-button:
    rounded: "{rounded.control}"
    width: "26pt"
    height: "26pt"
  text-button-light:
    textColor: "{colors.browsemium-secondary-light}"
  text-button-dark:
    textColor: "{colors.browsemium-secondary-dark}"
  segmented-control:
    rounded: "{rounded.panel}"
    padding: "2pt"
  panel-light:
    backgroundColor: "{colors.browsemium-surface-light}"
    rounded: "{rounded.panel}"
  panel-dark:
    backgroundColor: "{colors.browsemium-surface-dark}"
    rounded: "{rounded.panel}"
  field-light:
    backgroundColor: "{colors.browsemium-field-light}"
    rounded: "{rounded.control}"
  field-dark:
    backgroundColor: "{colors.browsemium-field-dark}"
    rounded: "{rounded.control}"
---

# Design System: Browsemium native macOS

## Overview

**Creative North Star: "Restrained monochrome, native task clarity"**

Browsemium's native chrome recedes around the page. Compact controls, quiet
foreground tints and continuous rounded panels make actions legible without
turning the browser into a decorative dashboard. This captures the incumbent
SwiftUI/AppKit system; it does not introduce a replacement identity.

The scope is the native macOS application. The source of truth is
`Packages/BrowsemiumKit/Sources/BrowsemiumUI/DesignSystem/Theme.swift`, including
`BrowserPalette`, `BrowserMetrics` and the shared control views. The site is a
separate surface with its own styling. Geist is confirmed for branding and the
site; native controls use the macOS system font. The AI dock's composition and
approved future work remain in `Plans/7-polished-autonomous-workspace.md`.
`PRODUCT.md` governs capability and privacy claims, not layout tokens.

**Key Characteristics:**

- Monochrome emphasis with automatic light/dark appearance.
- Compact native controls with named actions and explicit state.
- Quiet panels, hairline borders and restrained overlay elevation.
- Real browser context and honest capability labels.

## Colors

The palette derives surfaces and interaction states from neutral foreground
tints. The frontmatter preserves the exact source channel values and alpha as
CSS-compatible notation; paired `-light` and `-dark` entries represent one
dynamic Swift color, not two manually selectable application palettes. Match
the corresponding `Color.browsemium…` token in code and let `NSColor` resolve
the current appearance. Alpha colors composite over their actual background.

### Primary

- **Monochrome emphasis:** `browsemiumAccent` emphasizes links and active text.
  `browsemiumAccentFill` and `browsemiumAccentFillText` invert primary actions.
  The name accent denotes emphasis rather than a brand hue.

### Neutral

- **Window backdrop:** `browsemiumCanvas` sits behind the floating panels.
- **Quiet panel:** `browsemiumSurface` serves sidebars and the assistant dock.
- **Raised neutral:** `browsemiumRaised` serves content and surfaces within panels.
- **Foreground hierarchy:** `browsemiumPrimary`, `browsemiumSecondary` and
  `browsemiumTertiary` distinguish primary content, supporting text and quiet
  metadata. Tertiary is not a blanket choice for long-form body copy.
- **Separators:** `browsemiumBorder` is a subtle hairline;
  `browsemiumBorderStrong` provides stronger field and overlay edges.
- **Interaction tints:** `browsemiumHover`, `browsemiumSelection` and
  `browsemiumField` provide hover, selection and recessed field backgrounds.

Destructive, warning and success tokens carry semantic meaning. The dynamic
`browsemiumFocus` uses AppKit's `keyboardFocusIndicatorColor`, chosen by macOS
and the person using it; there is no fixed brand-color substitute. Provider
marks, favicons, page content and captured thumbnails can retain their own
colors. They do not change the chrome palette.

**The Semantic Color Rule.** Keep chrome monochrome except where color names a
meaningful status, preserves source identity, or communicates system focus.

## Typography

Native controls use SwiftUI `.system(size:weight:)`; monospaced content uses
`.system(size:design: .monospaced)`. `system-ui` in the frontmatter is a portable
description of that platform role, not an imported web font or a literal native
font-family declaration. All `pt` values here are native SwiftUI/AppKit points.
Do not convert them into CSS physical points when implementing native screens.

The shared primary action uses the label role; shared section headers use the
section role. Shared empty states use the empty-title role with 12-point
supporting text. Native UI intentionally varies by component rather than
following a newly imposed display scale: toolbar/address text is around 12–13
points, and supporting labels are around 10–11.5 points.

`BrowsemiumWordmark` registers bundled `Geist-Variable.ttf`, uses
`Geist-SemiBold`, and falls back to system semibold if registration is
unavailable. Its tracking is `-size × 0.02`; the frontmatter records its default
size. This brand treatment does not replace native control type.

**The Platform Type Rule.** Keep macOS system type for native controls and
reserve bundled Geist for the established wordmark/brand scope.

## Layout

The window uses floating panels separated from its backdrop. The shared spacing
entries preserve `BrowserMetrics` names; they are layout roles rather than a
new universal spacing scale. The toolbar is 42 points high, the horizontal tab
strip 40, and shared rows 29. Tabs default to 190 points wide with a 120-point
minimum. The vertical sidebar is 216 points wide. The shared minimum window is
860 × 560 points; traffic-light and titlebar insets reserve actual native window
controls rather than decorative whitespace.

The assistant dock defaults to 420 points, with a 360-point minimum, a maximum
of half the available window, and at least 380 points reserved for the browser
panel. Its saved width is separately clamped on restoration. These are native
window/panel constraints, not website breakpoints.

Content should wrap or scroll within native panel constraints. The AI dock's
full, compact and scrollable empty-state fallback is a local height adaptation;
its secure field and composer do not establish global control sizes. Refer to
the saved plan and current source for that composition.

## Elevation & Depth

Shared `BrowsemiumPanel` uses a neutral background, continuous clipping and a
one-point hairline border. It adds no shadow. Depth comes primarily from canvas,
surface and raised neutral layers. Floating overlays can add structural shadows:
the existing find bar uses black at 0.14 opacity, radius 10, vertical offset 3;
address suggestions use black at 0.22 opacity, radius 14, vertical offset 5;
Peek uses black at 0.22 opacity, radius 24, vertical offset 8. These are existing
local treatments, not a new shared elevation scale. The sidecar records the
native shadow parameters rather than pretending SwiftUI blur radius equals CSS
box-shadow blur.

**The Quiet Panel Rule.** Use the incumbent border and tonal layers for ordinary
panels; reserve elevation for overlays that already require separation.

## Shapes

Shared controls use continuous rounded corners with the control radius, and
panels/overlays use their named shared radii. The tab picker derives its outer
radius from `controlRadius + 2`, coincidentally equal to the current panel
radius; that arithmetic remains its implementation source. Attachment chips
use capsules. Local AI connection and composer surfaces use 12- and 16-point
corners respectively; those values are component-specific, not new global
radius tokens. Use the bundled logo and SF Symbols through existing native
views, maintaining aspect ratio and accessible labels.

## Components

### Buttons

`BrowsemiumPrimaryButton` uses the inverted action fill, the label role,
horizontal padding of 12 points and a 26-point height. Disabled state uses the
field background and tertiary foreground. Its plain button style does not
implement a bespoke hover animation.

`BrowsemiumIconButton` uses a 13-point system symbol in a 26-point square,
secondary foreground at rest, primary when active, and tertiary when disabled.
Enabled hover uses the hover tint. The active state adds the selected
accessibility trait, and each icon has a named action. `BrowsemiumTextButton`
uses 12-point system text, secondary foreground or destructive foreground for
its explicit destructive role.

### Navigation

`BrowsemiumTabPicker` is a monochrome segmented control with 2-point outer
padding and inter-item spacing. Segments use 10-point horizontal padding and a
22-point height. Selection uses the selection tint, primary foreground and
medium weight; unselected segments use secondary regular text and the hover
tint on hover. Selection has an accessibility trait. Tab/sidebar composition
belongs to the native browser surfaces, not a website navigation prescription.

### Cards / Containers

`browsemiumPanel()` supplies the shared surface, clipping and border treatment.
It imposes no internal padding or shadow. Content and controls choose their
own padding. `BrowsemiumEmptyState` combines a quiet system symbol, title and
supporting text; its message is centered within 300 points, and its accessibility
children combine into one element.

### Inputs / Fields

`browsemiumField()` uses plain text-field styling, the field tint, control-radius
corners and a one-point border. Despite its source comment, this helper does not
itself implement focus-state tracking; focus styling is supplied by individual
controls where present. The address field explicitly switches to system focus
color when focused. The AI secure key field also explicitly tracks focus and
uses that color, a raised background, stronger resting border, 12-point
horizontal padding and a 40-point height. This size belongs to key entry.

### Attachment chips

The dock's `AttachmentChip` uses a field-tinted capsule, 8-point horizontal and
4-point vertical padding, 10.5-point secondary text, and selection tint on hover.
An optional real thumbnail preserves its content; the remove action is labelled
with the attachment name. The chip represents an existing attachment, not
ambient activity.

### Assistant controls

The dock's `AIDockActionStyle` reuses native palette values: primary fill when
enabled, field fill when disabled, and hover tint for secondary hover/press.
Disabled opacity is 0.5. Its composer contains labelled attachment and assist
menus, actual page context, and explicit Review/Stop. API review-before-send
remains the contract; provider-website behavior retains its separate flow.
Private, locked and unsupported pages do not become attachable context. A
generic prompt replaces page-specific wording when context is unavailable.
Readable transcript typography and safe Markdown remain local content styles.
No autonomous MCP task UI or page actuator is implemented by this treatment.

Visual fixture evidence is in `.impeccable/review/ai-dock/`: setup minimum/default,
conversation, short error, private and streaming, each in light/dark. These
captures support appearance inspection, not a claim of completed native keyboard,
VoiceOver or whole-app interaction QA. The sidecar's HTML examples illustrate
native patterns for the design panel; they are not runtime components, exact SF
Symbols, or proof of native focus behavior.

## Do's and Don'ts

### Do:

- Do use the existing dynamic native palette and resolve both appearances.
- Do preserve system type, native control semantics and labelled actions.
- Do use foreground hierarchy to make tasks and supporting information readable.
- Do represent actual context, capabilities and operation state in the interface.
- Do adapt content to the available native panel space while keeping actions reachable.

### Don't:

- Don't replace the incumbent monochrome identity with a new decorative palette.
- Don't apply site typography or site breakpoints to native controls.
- Don't add ornamental glow, invented activity or unverifiable counts.
- Don't promote the AI dock's local composition into a rule for every surface.
- Don't describe approved future automation or fixture inspection as shipped capability or completed native QA.
