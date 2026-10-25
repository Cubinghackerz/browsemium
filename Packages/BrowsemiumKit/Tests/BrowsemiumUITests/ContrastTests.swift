import AppKit
import BrowsemiumUI
import SwiftUI
import Testing

/// WCAG 2.x contrast for the chrome palette, measured on the real dynamic
/// colors in both appearances. Text must reach 4.5:1 on every background it
/// can sit on, including under hover, selection and field tints.
@MainActor
private enum Sample {
    struct RGBA { var r: Double, g: Double, b: Double, a: Double }

    static func resolve(_ color: Color, dark: Bool) -> RGBA {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var result = RGBA(r: 0, g: 0, b: 0, a: 1)
        appearance.performAsCurrentDrawingAppearance {
            let converted = NSColor(color).usingColorSpace(.sRGB) ?? .black
            result = RGBA(r: converted.redComponent, g: converted.greenComponent, b: converted.blueComponent, a: converted.alphaComponent)
        }
        return result
    }

    /// `top` composited over an opaque `bottom`.
    static func over(_ top: RGBA, _ bottom: RGBA) -> RGBA {
        RGBA(
            r: top.r * top.a + bottom.r * (1 - top.a),
            g: top.g * top.a + bottom.g * (1 - top.a),
            b: top.b * top.a + bottom.b * (1 - top.a),
            a: 1
        )
    }

    static func luminance(_ c: RGBA) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    static func ratio(_ a: RGBA, _ b: RGBA) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}

@MainActor
private struct Background {
    let name: String
    let color: Color
    let tint: Color?
}

@MainActor
private let backgrounds: [Background] = [
    Background(name: "canvas", color: .browsemiumCanvas, tint: nil),
    Background(name: "surface", color: .browsemiumSurface, tint: nil),
    Background(name: "raised", color: .browsemiumRaised, tint: nil),
    Background(name: "surface+hover", color: .browsemiumSurface, tint: .browsemiumHover),
    Background(name: "surface+selection", color: .browsemiumSurface, tint: .browsemiumSelection),
    Background(name: "surface+field", color: .browsemiumSurface, tint: .browsemiumField),
    Background(name: "raised+selection", color: .browsemiumRaised, tint: .browsemiumSelection),
    Background(name: "canvas+selection", color: .browsemiumCanvas, tint: .browsemiumSelection)
]

@MainActor
private func measure(_ foreground: Color, on background: Background, dark: Bool) -> Double {
    var base = Sample.resolve(background.color, dark: dark)
    base.a = 1
    if let tint = background.tint { base = Sample.over(Sample.resolve(tint, dark: dark), base) }
    return Sample.ratio(Sample.over(Sample.resolve(foreground, dark: dark), base), base)
}

@Test @MainActor
func textTonesMeetAAOnEveryBackgroundInBothAppearances() {
    let tones: [(String, Color)] = [
        ("primary", .browsemiumPrimary), ("secondary", .browsemiumSecondary),
        ("tertiary", .browsemiumTertiary), ("accent", .browsemiumAccent)
    ]
    for dark in [false, true] {
        for (toneName, tone) in tones {
            for background in backgrounds {
                let value = measure(tone, on: background, dark: dark)
                #expect(value >= 4.5, Comment(rawValue: "\(toneName) on \(background.name) (\(dark ? "dark" : "light")) = \(String(format: "%.2f", value))"))
            }
        }
    }
}

@Test @MainActor
func statusColorsAreReadableOnPanels() {
    let tones: [(String, Color)] = [
        ("destructive", .browsemiumDestructive), ("warning", .browsemiumWarning), ("success", .browsemiumSuccess)
    ]
    for dark in [false, true] {
        for (toneName, tone) in tones {
            for background in backgrounds.prefix(3) {
                let value = measure(tone, on: background, dark: dark)
                #expect(value >= 4.5, Comment(rawValue: "\(toneName) on \(background.name) (\(dark ? "dark" : "light")) = \(String(format: "%.2f", value))"))
            }
        }
    }
}

@Test @MainActor
func theHierarchyStillReadsAsThreeSteps() {
    for dark in [false, true] {
        let surface = backgrounds[1]
        let primary = measure(.browsemiumPrimary, on: surface, dark: dark)
        let secondary = measure(.browsemiumSecondary, on: surface, dark: dark)
        let tertiary = measure(.browsemiumTertiary, on: surface, dark: dark)
        #expect(primary > secondary + 1, "primary is clearly above secondary")
        #expect(secondary > tertiary + 0.5, "secondary is clearly above tertiary")
    }
}

@Test @MainActor
func primaryButtonLabelsAreReadable() {
    for dark in [false, true] {
        let fill = Sample.resolve(.browsemiumAccentFill, dark: dark)
        let text = Sample.resolve(.browsemiumAccentFillText, dark: dark)
        #expect(Sample.ratio(Sample.over(text, Sample.over(fill, Sample.resolve(.browsemiumSurface, dark: dark))), Sample.over(fill, Sample.resolve(.browsemiumSurface, dark: dark))) >= 7)
    }
}

// MARK: - Increase Contrast

/// AppKit cannot build the Increase Contrast appearances by name, so these
/// tests read the tone values directly. The live switch is one `bestMatch`
/// call in `BrowserPalette.adaptive(_:)`; owner QA confirms it in the app.
@MainActor
private func rgba(_ color: NSColor) -> Sample.RGBA {
    let converted = color.usingColorSpace(.sRGB) ?? .black
    return Sample.RGBA(r: converted.redComponent, g: converted.greenComponent, b: converted.blueComponent, a: converted.alphaComponent)
}

/// Measures a tone's value for `name` on a background of the same colour scheme.
@MainActor
private func measureTone(_ tone: BrowserPalette.Tone, on background: Background, variant name: NSAppearance.Name) -> Double {
    let dark = name == .darkAqua || name == .accessibilityHighContrastDarkAqua
    var base = Sample.resolve(background.color, dark: dark)
    base.a = 1
    if let tint = background.tint { base = Sample.over(Sample.resolve(tint, dark: dark), base) }
    return Sample.ratio(Sample.over(rgba(tone.value(for: name)), base), base)
}

private let textTones: [(String, BrowserPalette.Tone)] = [
    ("primary", BrowserPalette.primaryTone), ("secondary", BrowserPalette.secondaryTone), ("tertiary", BrowserPalette.tertiaryTone)
]

@Test @MainActor
func increaseContrastTextMeetsAAOnEveryBackground() {
    for name in [NSAppearance.Name.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
        for (toneName, tone) in textTones {
            for background in backgrounds {
                let value = measureTone(tone, on: background, variant: name)
                #expect(value >= 4.5, Comment(rawValue: "\(toneName) on \(background.name) (\(name.rawValue)) = \(String(format: "%.2f", value))"))
            }
        }
    }
}

@Test @MainActor
func increaseContrastIsNeverWeakerThanTheStandardTones() {
    let pairs: [(NSAppearance.Name, NSAppearance.Name)] = [(.aqua, .accessibilityHighContrastAqua), (.darkAqua, .accessibilityHighContrastDarkAqua)]
    for (standard, high) in pairs {
        for (toneName, tone) in textTones {
            for background in backgrounds {
                let before = measureTone(tone, on: background, variant: standard)
                let after = measureTone(tone, on: background, variant: high)
                #expect(after >= before, Comment(rawValue: "\(toneName) on \(background.name) lost contrast under Increase Contrast"))
            }
        }
    }
}

@Test @MainActor
func increaseContrastGivesTheStrongBorderAThreeToOneEdge() {
    // WCAG 1.4.11: a control's edge needs 3:1 against its background.
    for name in [NSAppearance.Name.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
        let dark = name == .accessibilityHighContrastDarkAqua
        for background in backgrounds.prefix(3) {
            var base = Sample.resolve(background.color, dark: dark)
            base.a = 1
            let edge = Sample.over(rgba(BrowserPalette.borderStrongTone.value(for: name)), base)
            let value = Sample.ratio(edge, base)
            #expect(value >= 3, Comment(rawValue: "strong border on \(background.name) (\(name.rawValue)) = \(String(format: "%.2f", value))"))
        }
    }
}

@Test @MainActor
func toneValuesFollowTheAppearanceName() {
    let tone = BrowserPalette.secondaryTone
    #expect(tone.value(for: .aqua).isEqual(tone.light))
    #expect(tone.value(for: .darkAqua).isEqual(tone.dark))
    #expect(tone.value(for: .accessibilityHighContrastAqua).isEqual(tone.highLight))
    #expect(tone.value(for: .accessibilityHighContrastDarkAqua).isEqual(tone.highDark))
    #expect(tone.value(for: nil).isEqual(tone.light), "No match falls back to the standard light value")
}
