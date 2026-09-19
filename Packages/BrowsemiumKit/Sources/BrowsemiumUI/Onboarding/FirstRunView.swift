import BrowsemiumCore
import SwiftUI

/// First-run setup. Four short steps — welcome, search, appearance, privacy —
/// then the assistant opt-in. Every choice writes straight into the same
/// `BrowserSettings` the Settings panel edits later, so nothing here is a
/// one-way door.
@MainActor
struct FirstRunView: View {
    @Bindable var model: BrowserWindowModel
    let onFinish: () -> Void

    @State private var step = 0
    @State private var searchTemplate = SearchEnginePreset.google.template
    @State private var appearance: AppearancePreference = .system
    @State private var protection: ProtectionLevel = .standard
    @State private var retentionDays: Int = 90
    @State private var clearOnQuit = false
    @State private var assistantEnabled = true

    private let stepCount = 5

    private let retentionOptions: [(label: String, days: Int)] = [
        ("7 days", 7),
        ("30 days", 30),
        ("90 days", 90),
        ("1 year", 365)
    ]

    var body: some View {
        VStack(spacing: 0) {
            progress

            Group {
                switch step {
                case 0: welcomeStep
                case 1: searchStep
                case 2: appearanceStep
                case 3: privacyStep
                default: assistantStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)
            .animation(.easeOut(duration: 0.18), value: step)

            Rectangle()
                .fill(Color.browsemiumBorder)
                .frame(height: 1)

            footer
        }
        .frame(width: 560, height: 460)
        .background(Color.browsemiumSurface)
        .foregroundStyle(Color.browsemiumPrimary)
    }

    private var progress: some View {
        HStack(spacing: 5) {
            ForEach(0..<stepCount, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Color.browsemiumPrimary : Color.browsemiumBorder)
                    .frame(width: index == step ? 18 : 6, height: 6)
                    .animation(.easeOut(duration: 0.18), value: step)
            }
            Spacer()
            if step > 0 {
                Button("Skip setup") { finish() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.browsemiumTertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step + 1) of \(stepCount)")
    }

    private var welcomeStep: some View {
        VStack(spacing: 14) {
            Spacer()
            BrowsemiumLogo(size: 76)
                .shadow(color: .black.opacity(0.14), radius: 16, y: 6)

            Text("Welcome to Browsemium")
                .font(.system(size: 22, weight: .semibold))

            Text("A fast, quiet browser for people who live in tabs and AI models.\nLocal-first. No account. No telemetry.")
                .font(.system(size: 13))
                .foregroundStyle(Color.browsemiumSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
    }

    private var searchStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            stepHeader(
                title: "Search engine",
                detail: "Used when you type something that isn't an address."
            )

            VStack(spacing: 6) {
                ForEach(SearchEnginePreset.all) { preset in
                    OptionRow(
                        title: preset.name,
                        detail: preset.host,
                        isSelected: searchTemplate == preset.template
                    ) {
                        searchTemplate = preset.template
                    }
                }
            }
            Spacer()
        }
    }

    private var appearanceStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            stepHeader(
                title: "Appearance",
                detail: "Browsemium adapts its chrome to match. You can change this later in Settings."
            )

            HStack(spacing: 8) {
                ForEach(AppearancePreference.allCases, id: \.self) { option in
                    AppearanceCard(option: option, isSelected: appearance == option) {
                        appearance = option
                    }
                }
            }
            Spacer()
        }
    }

    private var privacyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            stepHeader(
                title: "Privacy",
                detail: "Browsemium keeps everything on this Mac. These control what it keeps and for how long."
            )

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Content protection")
                        .font(.system(size: 12.5))
                    Spacer()
                    BrowsemiumTabPicker(
                        values: ProtectionLevel.allCases,
                        selection: $protection,
                        label: { $0.rawValue.capitalized }
                    )
                    .accessibilityLabel("Content protection level")
                }

                HStack {
                    Text("Keep history for")
                        .font(.system(size: 12.5))
                    Spacer()
                    Picker("Keep history for", selection: $retentionDays) {
                        ForEach(retentionOptions, id: \.days) { option in
                            Text(option.label).tag(option.days)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("History retention")
                }

                Toggle("Clear history when Browsemium quits", isOn: $clearOnQuit)
                    .font(.system(size: 12.5))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Color.browsemiumAccentFill)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .fill(Color.browsemiumField)
            )
            Spacer()
        }
    }

    private var assistantStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            stepHeader(
                title: "Assistant",
                detail: "ChatGPT, Claude, Gemini, and Grok — in a dock, with your own subscriptions or your own API keys."
            )

            Toggle("Show the assistant", isOn: $assistantEnabled)
                .font(.system(size: 12.5))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Color.browsemiumAccentFill)

            VStack(alignment: .leading, spacing: 6) {
                assurance("Nothing reaches an AI provider until you attach context, review it, and confirm.")
                assurance("API keys live in your macOS keychain — never in the database, never in logs.")
                assurance("The assistant answers. It never clicks, types, or navigates for you.")
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .fill(Color.browsemiumField)
            )
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                BrowsemiumTextButton("Back") { step -= 1 }
            }
            Spacer()
            BrowsemiumPrimaryButton(step == stepCount - 1 ? "Start browsing" : "Continue") {
                if step == stepCount - 1 {
                    finish()
                } else {
                    step += 1
                }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func stepHeader(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            Text(detail)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.browsemiumSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func assurance(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 11))
                .foregroundStyle(Color.browsemiumSuccess)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.browsemiumSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func finish() {
        model.updateSettings { settings in
            settings.searchEngineTemplate = searchTemplate
            settings.appearance = appearance
            settings.protectionLevel = protection
            settings.historyRetentionDays = retentionDays
            settings.clearOnQuit = clearOnQuit
            settings.isAIDockEnabled = assistantEnabled
        }
        onFinish()
    }
}

@MainActor
private struct OptionRow: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.browsemiumPrimary)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.browsemiumTertiary)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.browsemiumPrimary : Color.browsemiumTertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .fill(isSelected ? Color.browsemiumSelection : (isHovering ? Color.browsemiumHover : Color.browsemiumField))
            )
            .overlay {
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .stroke(isSelected ? Color.browsemiumBorderStrong : Color.browsemiumBorder, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

@MainActor
private struct AppearanceCard: View {
    let option: AppearancePreference
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(previewBase)
                        .frame(height: 56)
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(previewChrome)
                            .frame(width: 70, height: 8)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(previewChrome.opacity(0.5))
                            .frame(width: 50, height: 8)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isSelected ? Color.browsemiumBorderStrong : Color.browsemiumBorder, lineWidth: 1)
                }

                Text(option.title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.browsemiumPrimary : Color.browsemiumSecondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .fill(isSelected ? Color.browsemiumSelection : (isHovering ? Color.browsemiumHover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var previewBase: Color {
        switch option {
        case .light: Color(white: 0.95)
        case .dark: Color(white: 0.16)
        case .system: Color.browsemiumField
        }
    }

    private var previewChrome: Color {
        switch option {
        case .light: Color(white: 0.75)
        case .dark: Color(white: 0.34)
        case .system: Color.browsemiumTertiary
        }
    }
}

private extension SearchEnginePreset {
    var host: String {
        URL(string: template)?.host ?? template
    }
}
