import BrowsemiumCore
import BrowsemiumData
import SwiftUI

/// The shared look for the toolbar's custom menus: a floating card with
/// hover-highlighted icon rows, replacing the system text-only `Menu`. Every
/// row is a real button; the checkmark marks the active choice.
@MainActor
struct MenuPanelContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            content
        }
        .padding(6)
        .frame(width: 236)
        .background(
            RoundedRectangle(cornerRadius: BrowserMetrics.overlayRadius, style: .continuous)
                .fill(Color.browsemiumRaised)
        )
        .overlay {
            RoundedRectangle(cornerRadius: BrowserMetrics.overlayRadius, style: .continuous)
                .stroke(Color.browsemiumBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
    }
}

/// One selectable row: a small icon tile, a label, and a checkmark when it is
/// the active choice.
@MainActor
struct MenuPanelRow<Icon: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon()
                    .frame(width: 18, height: 18)
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(Color.browsemiumPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.browsemiumSecondary)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.browsemiumHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A quieter footer row for management actions ("New Profile…").
@MainActor
struct MenuPanelActionRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.browsemiumSecondary)
                    .frame(width: 18, height: 18)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.browsemiumSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.browsemiumHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
    }
}

@MainActor
struct MenuPanelDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.browsemiumBorder)
            .frame(height: 1)
            .padding(.vertical, 4)
    }
}

/// A small rounded tile with a monogram — the minimal stand-in for a brand
/// logo that needs no bundled assets and stays legible in both appearances.
@MainActor
struct MonogramTile: View {
    let text: String
    let tint: Color
    var size: CGFloat = 18
    var fontSize: CGFloat = 8.5

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(tint)
            )
            .accessibilityHidden(true)
    }
}

/// A search engine's brand mark: bundled artwork for the built-in engines,
/// the monogram tile for anything custom. The Google, DuckDuckGo, and Brave
/// marks come from Simple Icons (CC0); Bing's is its official favicon, used
/// nominatively to identify the engine. The marks stay their owners'.
@MainActor
struct SearchEngineMark: View {
    let engineName: String
    var size: CGFloat = 18

    var body: some View {
        if let assetName = Self.assetName(for: engineName) {
            Image(assetName, bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            MonogramTile(
                text: engineName == "Custom" ? "…" : String(engineName.prefix(1)),
                tint: SearchEngineMenuPanel.tintForPreview(engineName),
                size: size,
                fontSize: size * 0.47
            )
        }
    }

    static func assetName(for engineName: String) -> String? {
        switch engineName {
        case "Google": "SearchEngineGoogle"
        case "DuckDuckGo": "SearchEngineDuckDuckGo"
        case "Bing": "SearchEngineBing"
        case "Brave": "SearchEngineBrave"
        default: nil
        }
    }
}

/// The search-engine switcher as a real panel: brand marks for each engine,
/// plus the way to add more.
@MainActor
struct SearchEngineMenuPanel: View {
    @Bindable var model: BrowserWindowModel
    let dismiss: () -> Void

    var body: some View {
        MenuPanelContainer {
            ForEach(SearchEnginePreset.all) { preset in
                MenuPanelRow(
                    title: preset.name,
                    isSelected: model.activeSearchEngineName == preset.name
                ) {
                    model.selectSearchEngine(preset)
                    dismiss()
                } icon: {
                    SearchEngineMark(engineName: preset.name)
                }
            }
            MenuPanelDivider()
            MenuPanelActionRow(title: "Other search engines…", systemImage: "magnifyingglass") {
                dismiss()
                model.openPanel(.settings)
            }
        }
    }

    private static func tint(for name: String) -> Color {
        switch name {
        case "Google": Color(red: 0.26, green: 0.52, blue: 0.96)
        case "DuckDuckGo": Color(red: 0.87, green: 0.35, blue: 0.20)
        case "Bing": Color(red: 0.00, green: 0.51, blue: 0.45)
        case "Brave": Color(red: 0.98, green: 0.33, blue: 0.17)
        default: Color.browsemiumTertiary
        }
    }

    /// Exposed so the toolbar's trigger button can show the same tile as the
    /// panel rows.
    static func tintForPreview(_ name: String) -> Color { tint(for: name) }
}

/// The password menu as a real panel: one row per saved login for the current
/// site, each a full-width button, plus the management action. A system `Menu`
/// here would fall back to a plain text list, which does not match the rest of
/// the chrome.
@MainActor
struct CredentialMenuPanel: View {
    @Bindable var model: BrowserWindowModel
    let dismiss: () -> Void

    var body: some View {
        MenuPanelContainer {
            let credentials = model.credentialsForActiveSite()
            if credentials.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "key.slash")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.browsemiumTertiary)
                        .frame(width: 18, height: 18)
                    Text("No saved passwords for this site")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.browsemiumSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
            } else {
                ForEach(credentials) { credential in
                    MenuPanelRow(
                        title: credential.username,
                        isSelected: false
                    ) {
                        dismiss()
                        model.fillCredential(credential)
                    } icon: {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.browsemiumSecondary)
                    }
                }
            }
            MenuPanelDivider()
            MenuPanelActionRow(title: "Manage Passwords…", systemImage: "gearshape") {
                dismiss()
                model.openPanel(.settings)
            }
        }
    }
}

/// The overflow menu as a real panel: every former text-only row with an SF
/// Symbol, in the same card style as the profile and search-engine menus.
@MainActor
struct OverflowMenuPanel: View {
    @Bindable var model: BrowserWindowModel
    let dismiss: () -> Void

    var body: some View {
        MenuPanelContainer {
            row("New Tab", systemImage: "plus") { model.newTab() }
            row("Reopen Closed Tab", systemImage: "arrow.counterclockwise") { model.reopenClosedTab() }
            row("Recently Closed Tabs", systemImage: "clock.arrow.circlepath") { model.openPanel(.recentlyClosed) }
            MenuPanelDivider()
            row("Translate Page", systemImage: "character.book.closed") { model.translatePage() }
            row("Save as PDF…", systemImage: "doc.richtext") { model.savePageAsPDF() }
            row("Save Screenshot…", systemImage: "camera.viewfinder") { model.savePageScreenshot() }
            row("Picture in Picture", systemImage: "rectangle.on.rectangle") { model.togglePictureInPicture() }
            MenuPanelDivider()
            row("History", systemImage: "clock") { model.openPanel(.history) }
            row("Bookmarks", systemImage: "book") { model.openPanel(.bookmarks) }
            row(
                model.isBookmarksBarVisible ? "Hide Bookmarks Bar" : "Show Bookmarks Bar",
                systemImage: "bookmark"
            ) {
                model.toggleBookmarksBar()
            }
            row("Downloads", systemImage: "arrow.down.circle") { model.openPanel(.downloads) }
            MenuPanelDivider()
            row("Profiles…", systemImage: "person.2") { model.openPanel(.settings) }
            row("Settings…", systemImage: "gearshape") { model.openPanel(.settings) }
        }
    }

    /// Every row dismisses the panel first, so the action's own UI — a panel,
    /// a save sheet, a toast — never opens underneath this one.
    private func row(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        MenuPanelActionRow(title: title, systemImage: systemImage) {
            dismiss()
            action()
        }
    }
}

@MainActor
struct SiteShieldPanel: View {
    @Bindable var model: BrowserWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.activePageHost ?? "No site")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.browsemiumPrimary)
                .lineLimit(1)

            Text(model.siteShieldStatus)
                .font(.system(size: 11))
                .foregroundStyle(Color.browsemiumSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let pick = model.pendingElementPick {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hide this element?")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.browsemiumPrimary)
                    Text(pick.matchCount > 1
                        ? "\(pick.label), matching \(pick.matchCount) elements"
                        : pick.label)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.browsemiumSecondary)
                        .lineLimit(2)
                    Text(pick.selector)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.browsemiumTertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        BrowsemiumPrimaryButton("Hide") { model.confirmElementHiding() }
                        BrowsemiumTextButton("Cancel") { model.cancelElementHiding() }
                    }
                }
            }

            Toggle("Pause blocking on this site", isOn: pauseBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))
                .disabled(!canPause)

            Text(pauseNote)
                .font(.system(size: 11))
                .foregroundStyle(Color.browsemiumTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Always open in Reader", isOn: readerBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))
                .disabled(model.activePageHost == nil || model.session.isPrivate)

            HStack(spacing: 8) {
                Text("Zoom")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.browsemiumPrimary)
                Spacer(minLength: 0)
                BrowsemiumIconButton(systemName: "minus", label: "Zoom out") { model.zoomOut() }
                Text("\(model.activeZoomPercent)%")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.browsemiumSecondary)
                    .frame(width: 40)
                BrowsemiumIconButton(systemName: "plus", label: "Zoom in") { model.zoomIn() }
                BrowsemiumTextButton("Reset") { model.resetZoom() }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Hidden elements")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.browsemiumPrimary)
                    Spacer(minLength: 0)
                    Text("⌘⇧H to hide one")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.browsemiumTertiary)
                }
                if hiddenRules.isEmpty {
                    Text(model.session.isPrivate
                        ? "Elements hidden in this private window are forgotten when it closes."
                        : "Nothing hidden on this site yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.browsemiumTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(hiddenRules) { rule in
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(rule.label)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Color.browsemiumSecondary)
                                    .lineLimit(1)
                                Text(rule.selector)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Color.browsemiumTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            Toggle("", isOn: enabledBinding(rule))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .help(rule.isEnabled ? "Turn this rule off" : "Turn this rule back on")
                            BrowsemiumIconButton(systemName: "arrow.uturn.backward", label: "Show this element again") {
                                model.removeCosmeticRule(rule)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: BrowserMetrics.overlayRadius, style: .continuous)
                .fill(Color.browsemiumRaised)
        )
        .overlay {
            RoundedRectangle(cornerRadius: BrowserMetrics.overlayRadius, style: .continuous)
                .stroke(Color.browsemiumBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
    }

    private var canPause: Bool {
        model.activePageHost != nil
            && !model.session.isPrivate
            && model.currentSettings().protectionLevel.blocksContentRules
    }

    private var pauseNote: String {
        if model.session.isPrivate {
            return "A private window does not remember site exceptions."
        }
        if !model.currentSettings().protectionLevel.blocksContentRules {
            return "Blocking is already off."
        }
        return "Pausing removes the bundled rules for this site only. The page reloads."
    }

    private var pauseBinding: Binding<Bool> {
        Binding(
            get: { model.isBlockingPaused(for: model.activePageURL) },
            set: { model.setBlockingPaused($0) }
        )
    }

    private var readerBinding: Binding<Bool> {
        Binding(
            get: { model.prefersReader(for: model.activePageURL) },
            set: { model.setReaderPreference(always: $0) }
        )
    }

    private var hiddenRules: [CosmeticRule] {
        guard let host = model.activePageHost else { return [] }
        return model.cosmeticRules(for: host)
    }

    private func enabledBinding(_ rule: CosmeticRule) -> Binding<Bool> {
        Binding(
            get: { rule.isEnabled },
            set: { model.setCosmeticRuleEnabled(rule, enabled: $0) }
        )
    }
}
