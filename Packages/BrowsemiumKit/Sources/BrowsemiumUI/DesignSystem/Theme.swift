import AppKit
import BrowsemiumCore
import CoreText
import SwiftUI
import BrowsemiumEngineKit

/// Semantic tokens for the Browsemium chrome.
///
/// The palette is deliberately monochrome and derived from the text color, the
/// way Zen Browser derives its chrome: every surface, hover state, and border is
/// a low-alpha tint of the foreground rather than a separate hue. Colour appears
/// only where it carries meaning (destructive, warning, success) and in the
/// system focus ring, so the browser never competes with the page.
///
/// Every token is a dynamic `NSColor`, so light and dark follow the system
/// appearance automatically instead of being chosen at launch.
/// The chrome's motion. Every animation in the chrome comes from here so
/// Reduce Motion is honoured in one place: with it on, nothing animates.
public enum BrowserMotion {
    /// Panels and layout changes.
    public static func standard(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.22)
    }

    /// Things that appear over the page: palette, peek, banners.
    public static func overlay(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)
    }

    /// Hover and press feedback.
    public static func quick(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }
}

/// The chrome's type scale. Three text steps replace the seven near-identical
/// sizes (10 to 13.5 pt) that had accumulated, and nothing in the chrome sets
/// text below 11 pt. Icon glyph sizes are not text and stay local.
public enum BrowserType {
    public enum Step {
        /// Metadata, hints, badges.
        case caption
        /// Row titles, secondary labels, notes.
        case small
        /// Primary body text and controls.
        case body
        /// Section and panel titles.
        case title

        public var size: CGFloat {
            switch self {
            case .caption: 11
            case .small: 12
            case .body: 13
            case .title: 15
            }
        }
    }

    public static func font(_ step: Step, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: step.size, weight: weight, design: design)
    }

    /// Maps a legacy point size onto its step, or nil for sizes that are not
    /// chrome text (icon glyphs below 10, display sizes above 16).
    public static func step(forLegacySize size: Double) -> Step? {
        switch size {
        case 10..<11.25: .caption
        case 11.25..<12.25: .small
        case 12.25..<14: .body
        case 14...16: .title
        default: nil
        }
    }
}

public enum BrowserPalette {
    public static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// One token's values: the standard pair and the pair macOS uses when
    /// Increase Contrast is on.
    public struct Tone: Sendable {
        public let light: NSColor
        public let dark: NSColor
        public let highLight: NSColor
        public let highDark: NSColor

        public init(light: NSColor, dark: NSColor, highLight: NSColor, highDark: NSColor) {
            self.light = light
            self.dark = dark
            self.highLight = highLight
            self.highDark = highDark
        }

        /// The value for an appearance name, as AppKit reports it.
        public func value(for name: NSAppearance.Name?) -> NSColor {
            if name == .accessibilityHighContrastAqua { return highLight }
            if name == .accessibilityHighContrastDarkAqua { return highDark }
            return name == .darkAqua ? dark : light
        }
    }

    public static func adaptive(_ tone: Tone) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            tone.value(for: appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]))
        })
    }

    static func alpha(_ color: NSColor, _ alpha: CGFloat) -> NSColor {
        color.withAlphaComponent(alpha)
    }
}

/// Alpha tones behind the chrome's foreground and border tokens. Each has a
/// standard pair and an Increase Contrast pair; `ContrastTests` measures both.
public extension BrowserPalette {
    public static var borderTone: Tone {
        Tone(
            light: alpha(NSColor(white: 0, alpha: 1), 0.10),
            dark: alpha(NSColor(white: 1, alpha: 1), 0.09),
            highLight: alpha(NSColor(white: 0, alpha: 1), 0.34),
            highDark: alpha(NSColor(white: 1, alpha: 1), 0.40)
        )
    }

    public static var borderStrongTone: Tone {
        Tone(
            light: alpha(NSColor(white: 0, alpha: 1), 0.18),
            dark: alpha(NSColor(white: 1, alpha: 1), 0.16),
            highLight: alpha(NSColor(white: 0, alpha: 1), 0.60),
            highDark: alpha(NSColor(white: 1, alpha: 1), 0.62)
        )
    }

    public static var primaryTone: Tone {
        Tone(
            light: alpha(NSColor(white: 0, alpha: 1), 0.88),
            dark: alpha(NSColor(white: 1, alpha: 1), 0.90),
            highLight: alpha(NSColor(white: 0, alpha: 1), 0.96),
            highDark: alpha(NSColor(white: 1, alpha: 1), 0.98)
        )
    }

    public static var secondaryTone: Tone {
        Tone(
            light: alpha(NSColor(white: 0, alpha: 1), 0.70),
            dark: alpha(NSColor(white: 1, alpha: 1), 0.70),
            highLight: alpha(NSColor(white: 0, alpha: 1), 0.86),
            highDark: alpha(NSColor(white: 1, alpha: 1), 0.86)
        )
    }

    public static var tertiaryTone: Tone {
        Tone(
            light: alpha(NSColor(white: 0, alpha: 1), 0.58),
            dark: alpha(NSColor(white: 1, alpha: 1), 0.58),
            highLight: alpha(NSColor(white: 0, alpha: 1), 0.76),
            highDark: alpha(NSColor(white: 1, alpha: 1), 0.76)
        )
    }
}

public extension Color {
    /// The window backdrop behind the floating panels.
    static let browsemiumCanvas = BrowserPalette.adaptive(
        light: NSColor(white: 0.902, alpha: 1),
        dark: NSColor(white: 0.075, alpha: 1)
    )

    /// The sidebar, assistant dock, and other side panels.
    static let browsemiumSurface = BrowserPalette.adaptive(
        light: NSColor(white: 0.949, alpha: 1),
        dark: NSColor(white: 0.125, alpha: 1)
    )

    /// The content panel and anything sitting on top of a surface.
    static let browsemiumRaised = BrowserPalette.adaptive(
        light: NSColor(white: 0.976, alpha: 1),
        dark: NSColor(white: 0.155, alpha: 1)
    )

    /// Hairline separation. Deliberately close to the background.
    static let browsemiumBorder = BrowserPalette.adaptive(BrowserPalette.borderTone)

    static let browsemiumBorderStrong = BrowserPalette.adaptive(BrowserPalette.borderStrongTone)

    static let browsemiumPrimary = BrowserPalette.adaptive(BrowserPalette.primaryTone)

    /// Supporting text. Strong enough for WCAG AA (4.5:1) on every surface,
    /// including under hover and selection tints; `ContrastTests` measures it.
    static let browsemiumSecondary = BrowserPalette.adaptive(BrowserPalette.secondaryTone)

    /// The quietest text and glyph tone. It still meets 4.5:1: "quiet" here
    /// means smaller and lighter in weight, never too faint to read. The old
    /// values (0.38 / 0.36) measured about 2.6:1 and 3.3:1.
    static let browsemiumTertiary = BrowserPalette.adaptive(BrowserPalette.tertiaryTone)

    /// Interactive foreground: links, primary buttons, active tab titles.
    /// Monochrome on purpose — the accent is emphasis, not a hue.
    static let browsemiumAccent = BrowserPalette.adaptive(
        light: BrowserPalette.alpha(NSColor(white: 0, alpha: 1), 0.92),
        dark: BrowserPalette.alpha(NSColor(white: 1, alpha: 1), 0.95)
    )

    /// The fill of a primary button (inverts the surface).
    static let browsemiumAccentFill = BrowserPalette.adaptive(
        light: NSColor(white: 0.11, alpha: 1),
        dark: NSColor(white: 0.92, alpha: 1)
    )

    static let browsemiumAccentFillText = BrowserPalette.adaptive(
        light: NSColor(white: 0.98, alpha: 1),
        dark: NSColor(white: 0.11, alpha: 1)
    )

    /// Row hover, matching Zen's low-alpha foreground tint.
    static let browsemiumHover = BrowserPalette.adaptive(
        light: BrowserPalette.alpha(NSColor(white: 0, alpha: 1), 0.055),
        dark: BrowserPalette.alpha(NSColor(white: 1, alpha: 1), 0.065)
    )

    /// Selected or active row.
    static let browsemiumSelection = BrowserPalette.adaptive(
        light: BrowserPalette.alpha(NSColor(white: 0, alpha: 1), 0.09),
        dark: BrowserPalette.alpha(NSColor(white: 1, alpha: 1), 0.10)
    )

    /// Field background inside a panel.
    static let browsemiumField = BrowserPalette.adaptive(
        light: BrowserPalette.alpha(NSColor(white: 0, alpha: 1), 0.045),
        dark: BrowserPalette.alpha(NSColor(white: 1, alpha: 1), 0.055)
    )

    static let browsemiumDestructive = BrowserPalette.adaptive(
        light: NSColor(red: 0.76, green: 0.16, blue: 0.16, alpha: 1),
        dark: NSColor(red: 0.94, green: 0.42, blue: 0.42, alpha: 1)
    )

    static let browsemiumWarning = BrowserPalette.adaptive(
        light: NSColor(red: 0.50, green: 0.32, blue: 0.0, alpha: 1),
        dark: NSColor(red: 0.88, green: 0.68, blue: 0.30, alpha: 1)
    )

    static let browsemiumSuccess = BrowserPalette.adaptive(
        light: NSColor(red: 0.13, green: 0.45, blue: 0.25, alpha: 1),
        dark: NSColor(red: 0.44, green: 0.76, blue: 0.55, alpha: 1)
    )

    /// Focus rings follow the macOS accent colour, which the user controls in
    /// System Settings. Everything else in the chrome stays monochrome.
    static var browsemiumFocus: Color {
        Color(nsColor: .keyboardFocusIndicatorColor)
    }
}

public enum BrowserMetrics {
    /// Zen uses 42pt on macOS; a compact single toolbar keeps chrome quiet.
    public static let toolbarHeight: CGFloat = 42
    public static let tabStripHeight: CGFloat = 40
    /// Compact rows. Together they save 14 pt of height per row pair (and the
    /// divider between them), before the bookmarks bar is hidden on pages.
    public static let compactToolbarHeight: CGFloat = 36
    public static let compactTabStripHeight: CGFloat = 32

    public static func toolbarHeight(for style: ChromeStyle) -> CGFloat {
        style == .compact ? compactToolbarHeight : toolbarHeight
    }

    public static func tabStripHeight(for style: ChromeStyle) -> CGFloat {
        style == .compact ? compactTabStripHeight : tabStripHeight
    }

    /// Vertical chrome above the page for a layout, counting the one-point
    /// dividers and (when shown) the bookmarks bar. Used by layout tests.
    public static func verticalChrome(
        style: ChromeStyle,
        layout: TabLayout,
        bookmarksBarVisible: Bool,
        bookmarksBarHeight: CGFloat = 30
    ) -> CGFloat {
        var total = toolbarHeight(for: style) + 1
        if layout == .top, style == .standard { total += tabStripHeight(for: style) + 1 }
        if layout == .top, style == .compact { total += tabStripHeight(for: style) }
        if bookmarksBarVisible { total += bookmarksBarHeight + 1 }
        return total
    }
    public static let aiDockWidth: CGFloat = 420
    /// Provider sites are desktop layouts; below this they start to break.
    public static let aiDockMinimumWidth: CGFloat = 360
    /// The assistant dock never takes more than half the window.
    public static let aiDockMaximumWidthFraction: CGFloat = 0.5
    /// The page always keeps at least this much room.
    public static let minimumBrowserPanelWidth: CGFloat = 380

    public static let aiDockWidthDefaultsKey = "browsemium.aiDockWidth"

    /// The dock width from the last session, clamped to a sane range.
    public static var restoredDockWidth: CGFloat {
        restoredDockWidth(in: .standard)
    }

    public static func restoredDockWidth(in defaults: UserDefaults) -> CGFloat {
        let stored = defaults.double(forKey: aiDockWidthDefaultsKey)
        guard stored > 0 else { return aiDockWidth }
        return min(max(stored, aiDockMinimumWidth), 1200)
    }
    public static let rowHeight: CGFloat = 29
    public static let tabWidth: CGFloat = 190
    public static let tabMinimumWidth: CGFloat = 120

    /// The vertical tab sidebar's fixed width — wide enough for real titles,
    /// narrow enough that the page stays dominant.
    public static let sidebarWidth: CGFloat = 216
    /// Reserved drag space at the sidebar's top where the traffic lights sit.
    public static let sidebarTrafficLightInset: CGFloat = 34

    /// Continuous-ish rounding: panels read as one object, not a card grid.
    public static let panelRadius: CGFloat = 10
    public static let controlRadius: CGFloat = 8
    public static let overlayRadius: CGFloat = 10

    /// The gap between floating panels — Zen's element separation.
    public static let elementSeparation: CGFloat = 8

    /// Space between the window edges and the floating panels. Equal on the
    /// top and bottom so the chrome never looks pinned to the title bar.
    public static let windowEdgeInset: CGFloat = 12

    /// How far the tab strip's contents sit below the traffic-light zone.
    public static let tabStripTopInset: CGFloat = 6

    /// Room for the traffic lights in the tab strip's leading edge.
    public static let titlebarLeadingInset: CGFloat = 78

    public static let minimumWindowWidth: CGFloat = 860
    public static let minimumWindowHeight: CGFloat = 560
}

/// Trackpad haptic feedback for meaningful interactions. Deliberately rare —
/// a browser that buzzes on every click is exhausting.
public enum BrowserHaptics {
    public static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .generic) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
    }
}

/// An NSView that lets the window be dragged by otherwise empty chrome, the
/// way a real title bar does.
public struct WindowDragView: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSView {
        DragView()
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}

    public final class DragView: NSView {
        override public var mouseDownCanMoveWindow: Bool { true }
        override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

/// The Browsemium mark from the bundled asset catalog.
public struct BrowsemiumLogo: View {
    private let size: CGFloat

    public init(size: CGFloat = 18) {
        self.size = size
    }

    public var body: some View {
        Image("Logo", bundle: .module)
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundStyle(Color.browsemiumPrimary)
            .accessibilityLabel("Browsemium")
    }
}

/// Register the bundled wordmark face once per process.
private enum BrowsemiumBrandFont {
    static let name: String? = {
        guard let url = Bundle.module.url(forResource: "Geist-Variable", withExtension: "ttf") else {
            return nil
        }
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return "Geist-SemiBold"
    }()
}

/// Sentence-case wordmark with a bundled font: no network or system install.
public struct BrowsemiumWordmark: View {
    private let size: CGFloat

    public init(size: CGFloat = 17) { self.size = size }

    public var body: some View {
        Text("Browsemium")
            .font(BrowsemiumBrandFont.name.map { .custom($0, size: size) }
                ?? .system(size: size, weight: .semibold))
            .tracking(-size * 0.02)
            .foregroundStyle(Color.browsemiumPrimary)
    }
}

/// A decorative, template-tinted mark for an otherwise empty canvas.
public struct BrowsemiumWatermark: View {
    private let size: CGFloat

    public init(size: CGFloat = 220) {
        self.size = size
    }

    public var body: some View {
        Image("Logo", bundle: .module)
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundStyle(Color.browsemiumPrimary)
            .opacity(0.055)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

/// A compact, monochrome icon button that matches the toolbar rhythm.
public struct BrowsemiumIconButton: View {
    private let systemName: String
    private let label: String
    private let isDisabled: Bool
    private let isActive: Bool
    private let action: () -> Void

    @State private var isHovering = false

    public init(
        systemName: String,
        label: String,
        isDisabled: Bool = false,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.label = label
        self.isDisabled = isDisabled
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(BrowserType.font(.body, weight: .regular))
                // Glyph swaps (reload/stop, bookmark/unbookmark) morph.
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .background(
            RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                .fill(isHovering && !isDisabled ? Color.browsemiumHover : Color.clear)
        )
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private var foreground: Color {
        if isDisabled { return .browsemiumTertiary }
        return isActive ? .browsemiumPrimary : .browsemiumSecondary
    }
}

/// A primary action: inverts the surface instead of introducing a hue.
public struct BrowsemiumPrimaryButton: View {
    private let title: String
    private let isDisabled: Bool
    private let action: () -> Void

    public init(_ title: String, isDisabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isDisabled = isDisabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(BrowserType.font(.small, weight: .medium))
                .foregroundStyle(isDisabled ? Color.browsemiumTertiary : Color.browsemiumAccentFillText)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                        .fill(isDisabled ? Color.browsemiumField : Color.browsemiumAccentFill)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(title)
    }
}

/// A monochrome segmented control. The system segmented control tints its
/// selection with the accent colour, which fights the quiet chrome.
public struct BrowsemiumTabPicker<Value: Hashable>: View {
    private let values: [Value]
    private let label: (Value) -> String
    @Binding private var selection: Value

    public init(values: [Value], selection: Binding<Value>, label: @escaping (Value) -> String) {
        self.values = values
        _selection = selection
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(values, id: \.self) { value in
                TabButton(
                    title: label(value),
                    isSelected: value == selection
                ) {
                    selection = value
                }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius + 2, style: .continuous)
                .fill(Color.browsemiumField)
        )
        .accessibilityElement(children: .contain)
    }
}

@MainActor
private struct TabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(BrowserType.font(.small, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Color.browsemiumPrimary : Color.browsemiumSecondary)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                        .fill(isSelected ? Color.browsemiumSelection : (isHovering ? Color.browsemiumHover : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A quiet text action.
public struct BrowsemiumTextButton: View {
    private let title: String
    private let role: Role
    private let action: () -> Void

    public enum Role {
        case normal
        case destructive
    }

    public init(_ title: String, role: Role = .normal, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(BrowserType.font(.small))
                .foregroundStyle(role == .destructive ? Color.browsemiumDestructive : Color.browsemiumSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

public struct BrowsemiumSectionHeader: View {
    private let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .font(BrowserType.font(.caption, weight: .semibold))
            .foregroundStyle(Color.browsemiumTertiary)
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

public struct BrowsemiumEmptyState: View {
    private let systemName: String
    private let title: String
    private let message: String

    public init(systemName: String, title: String, message: String) {
        self.systemName = systemName
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color.browsemiumTertiary)
                .padding(.bottom, 4)
            Text(title)
                .font(BrowserType.font(.body, weight: .medium))
                .foregroundStyle(Color.browsemiumPrimary)
            Text(message)
                .font(BrowserType.font(.small))
                .foregroundStyle(Color.browsemiumSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}

/// The floating panel treatment shared by the sidebar, content, and dock.
public struct BrowsemiumPanel: ViewModifier {
    let background: Color
    let radius: CGFloat

    public func body(content: Content) -> some View {
        content
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.browsemiumBorder, lineWidth: 1)
            }
    }
}

/// The surface of anything that floats above the page: menus, the command
/// palette, suggestions, banners and toasts. On macOS 26 and later it is
/// Liquid Glass, which keeps the page visible behind it; with Reduce
/// Transparency on, or before macOS 26, it is the solid raised surface with
/// a hairline and a shadow. The palette stays monochrome either way, and
/// glass is never used for page content or the main canvas.
private struct FlatOverlaysKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// Forces overlays to their solid surface. Offscreen renders (snapshots)
    /// have no compositor to draw glass through, so they set this; live
    /// windows leave it off.
    var browsemiumFlatOverlays: Bool {
        get { self[FlatOverlaysKey.self] }
        set { self[FlatOverlaysKey.self] = newValue }
    }
}

public struct BrowsemiumOverlaySurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.browsemiumFlatOverlays) private var flatOverlays
    let radius: CGFloat
    let strongBorder: Bool
    let shadowOpacity: Double
    let shadowRadius: CGFloat
    let shadowY: CGFloat

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *), !reduceTransparency, !flatOverlays {
            content
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(shadowOpacity * 0.6), radius: shadowRadius, y: shadowY)
        } else {
            content
                .background(shape.fill(Color.browsemiumRaised))
                .clipShape(shape)
                .overlay { shape.stroke(strongBorder ? Color.browsemiumBorderStrong : Color.browsemiumBorder, lineWidth: 1) }
                .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowY)
        }
    }
}

public extension View {
    func browsemiumOverlaySurface(
        radius: CGFloat = BrowserMetrics.overlayRadius,
        strongBorder: Bool = false,
        shadowOpacity: Double = 0.18,
        shadowRadius: CGFloat = 14,
        shadowY: CGFloat = 5
    ) -> some View {
        modifier(BrowsemiumOverlaySurface(
            radius: radius, strongBorder: strongBorder,
            shadowOpacity: shadowOpacity, shadowRadius: shadowRadius, shadowY: shadowY
        ))
    }

    func browsemiumPanel(
        background: Color = .browsemiumSurface,
        radius: CGFloat = BrowserMetrics.panelRadius
    ) -> some View {
        modifier(BrowsemiumPanel(background: background, radius: radius))
    }

    /// Keyboard focus ring that follows the system accent colour.
    func browsemiumField() -> some View {
        self
            .textFieldStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .fill(Color.browsemiumField)
            )
            .overlay {
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .stroke(Color.browsemiumBorder, lineWidth: 1)
            }
    }
}

extension Color {
    /// Parses "#RRGGBB" or "#RGB" into a colour. Returns nil for anything else.
    init?(browsemiumHex hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 3,
              let number = UInt64(value, radix: 16) else {
            return nil
        }
        let red, green, blue: Double
        if value.count == 3 {
            red = Double((number >> 8) & 0xF) / 15
            green = Double((number >> 4) & 0xF) / 15
            blue = Double(number & 0xF) / 15
        } else {
            red = Double((number >> 16) & 0xFF) / 255
            green = Double((number >> 8) & 0xFF) / 255
            blue = Double(number & 0xFF) / 255
        }
        self.init(red: red, green: green, blue: blue)
    }
}
