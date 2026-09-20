import BrowsemiumCore
import SwiftUI

@MainActor
struct BrowserToolbar: View {
    @Bindable var model: BrowserWindowModel

    @FocusState private var addressFocused: Bool
    @State private var isFieldHovering = false
    @State private var isNamingProfile = false
    @State private var newProfileName = ""

    var body: some View {
        HStack(spacing: 4) {
            BrowsemiumIconButton(systemName: "chevron.left", label: "Go back", isDisabled: !model.canGoBack) {
                model.goBack()
            }

            BrowsemiumIconButton(systemName: "chevron.right", label: "Go forward", isDisabled: !model.canGoForward) {
                model.goForward()
            }

            BrowsemiumIconButton(
                systemName: model.isLoading ? "xmark" : "arrow.clockwise",
                label: model.isLoading ? "Stop loading" : "Reload",
                isDisabled: !model.canReload
            ) {
                if model.isLoading {
                    model.stopLoading()
                } else {
                    model.reload()
                }
            }

            Spacer(minLength: 4)

            addressField
                .frame(maxWidth: 600)

            Spacer(minLength: 4)

            downloadIndicator

            credentialMenu

            BrowsemiumIconButton(systemName: "command", label: "Commands") {
                model.toggleCommandPalette()
            }

            BrowsemiumIconButton(
                systemName: "sparkles",
                label: "Toggle assistant",
                isActive: model.isAIDockVisible
            ) {
                BrowserHaptics.perform()
                model.toggleAIDock()
            }

            profileMenu

            overflowMenu
        }
        .padding(.horizontal, 8)
        .frame(height: BrowserMetrics.toolbarHeight)
        .frame(maxWidth: .infinity)
        .alert("New Profile", isPresented: $isNamingProfile) {
            TextField("Name", text: $newProfileName)
            Button("Create") {
                let name = newProfileName
                newProfileName = ""
                model.createProfile(named: name.isEmpty ? "Profile \(model.profiles.count + 1)" : name)
            }
            Button("Cancel", role: .cancel) { newProfileName = "" }
        } message: {
            Text("Each profile keeps its own tabs, bookmarks, history, and logins.")
        }
    }

    /// Profile switcher: shows the active profile's initials and switches the
    /// whole window — cookies, logins, bookmarks, and tabs — between profiles.
    private var profileMenu: some View {
        Menu {
            ForEach(model.profiles) { profile in
                Button {
                    model.switchProfile(to: profile)
                } label: {
                    if profile.id == model.activeProfile.id {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
            Divider()
            Button("New Profile…") {
                newProfileName = ""
                isNamingProfile = true
            }
            Button("Manage Profiles…") { model.openPanel(.settings) }
        } label: {
            HStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(Color.browsemiumSelection)
                    Text(model.activeProfile.initials)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Color.browsemiumSecondary)
                }
                .frame(width: 18, height: 18)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Color.browsemiumTertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Profile: \(model.activeProfile.name)")
        .accessibilityLabel("Profile, \(model.activeProfile.name)")
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            searchEngineMenu

            Rectangle()
                .fill(Color.browsemiumBorder)
                .frame(width: 1, height: 14)

            Button {
                BrowserHaptics.perform()
                model.toggleBookmark()
            } label: {
                Image(systemName: model.isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 11))
                    .foregroundStyle(model.isBookmarked ? Color.browsemiumPrimary : Color.browsemiumTertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isBookmarked ? "Remove bookmark" : "Bookmark this page")

            TextField("Search or enter address", text: $model.addressText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($addressFocused)
                .onSubmit { model.acceptHighlightedSuggestion() }
                .onChange(of: model.addressText) { model.updateAddressSuggestions() }
                .onChange(of: addressFocused) { _, focused in
                    if !focused { model.dismissAddressSuggestions() }
                }
                .onKeyPress(.downArrow) {
                    model.moveSuggestionSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    model.moveSuggestionSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    model.dismissAddressSuggestions()
                    return .handled
                }
                .accessibilityLabel("Address and search")
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isFieldHovering || addressFocused ? Color.browsemiumSelection : Color.browsemiumField)
        )
        .overlay(alignment: .bottom) {
            if model.isLoading {
                GeometryReader { geometry in
                    Capsule(style: .continuous)
                        .fill(Color.browsemiumPrimary.opacity(0.45))
                        .frame(
                            width: max(geometry.size.width * min(max(model.loadingProgress, 0.03), 1), 8),
                            height: 1.5
                        )
                        .frame(maxWidth: .infinity, alignment: .bottomLeading)
                        .animation(.easeOut(duration: 0.25), value: model.loadingProgress)
                }
                .frame(height: 1.5)
                .padding(.horizontal, 13)
                .padding(.bottom, 3)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(addressFocused ? Color.browsemiumFocus : Color.browsemiumBorder, lineWidth: addressFocused ? 1.5 : 1)
        }
        .onHover { isFieldHovering = $0 }
        .animation(.easeOut(duration: 0.2), value: model.isLoading)
        .onChange(of: model.focusAddressToken) {
            addressFocused = true
        }
        .onChange(of: addressFocused) { _, focused in
            // The browser panel draws the dropdown; it needs to know whether
            // the field is active so it can hide when focus moves away.
            model.isAddressFocused = focused
        }
    }

    /// Top-right download status: a progress ring while something is arriving,
    /// and a menu of recent downloads.
    @ViewBuilder
    private var downloadIndicator: some View {
        if !model.downloads.isEmpty {
            Menu {
                ForEach(model.downloads.prefix(8)) { download in
                    if download.failureMessage != nil {
                        Text("\(download.filename) — failed")
                    } else if download.isFinished {
                        Text("\(download.filename) — done")
                    } else {
                        Text("\(download.filename) — \(download.percentText)")
                    }
                }
                Divider()
                Button("Show All Downloads") { model.openPanel(.downloads) }
            } label: {
                ZStack {
                    Image(systemName: model.hasActiveDownloads ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(
                            model.hasActiveDownloads ? Color.browsemiumPrimary : Color.browsemiumSecondary
                        )

                    if let fraction = model.downloadProgressFraction {
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(Color.browsemiumPrimary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 20, height: 20)
                            .animation(.easeOut(duration: 0.2), value: fraction)
                    }
                }
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(
                model.hasActiveDownloads
                    ? "Downloading \(model.activeDownloads.count) file"
                    : "Downloads"
            )
        }
    }

    /// Quick search-engine switch, right in the address bar. The chosen engine
    /// becomes the default; typing "!d query" uses one engine for a single
    /// search without changing it.
    private var searchEngineMenu: some View {
        Menu {
            ForEach(SearchEnginePreset.all) { preset in
                Button {
                    model.selectSearchEngine(preset)
                } label: {
                    if model.activeSearchEngineName == preset.name {
                        Label(preset.name, systemImage: "checkmark")
                    } else {
                        Text(preset.name)
                    }
                }
            }
            Divider()
            Button("Other search engines…") { model.openPanel(.settings) }
        } label: {
            HStack(spacing: 4) {
                if let icon = Self.engineIconName(for: model.activeSearchEngineName) {
                    Image(icon, bundle: .module)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 12, height: 12)
                        .foregroundStyle(Color.browsemiumSecondary)
                } else {
                    Text(searchEngineInitial)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.browsemiumSecondary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Color.browsemiumTertiary)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Search engine: \(model.activeSearchEngineName). Type !g, !d, !b or !br for a one-off search.")
        .accessibilityLabel("Search engine, \(model.activeSearchEngineName)")
    }

    /// Brand marks for the four presets. Sources are CC0 (simple-icons and
    /// the SVG Logos collection); see ThirdPartyNotices.
    static func engineIconName(for engineName: String) -> String? {
        switch engineName {
        case "Google": "EngineGoogle"
        case "DuckDuckGo": "EngineDuckDuckGo"
        case "Bing": "EngineBing"
        case "Brave": "EngineBrave"
        default: nil
        }
    }

    private var searchEngineInitial: String {
        let name = model.activeSearchEngineName
        return name == "Custom" ? "…" : String(name.prefix(1))
    }

    private var credentialMenu: some View {
        Menu {
            let credentials = model.credentialsForActiveSite()
            if credentials.isEmpty {
                Text("No saved passwords for this site")
            } else {
                ForEach(credentials) { credential in
                    Button("Fill \(credential.username)") {
                        model.fillCredential(credential)
                    }
                }
            }
            Divider()
            Button("Manage Passwords…") { model.openPanel(.settings) }
        } label: {
            Image(systemName: "key")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(
                    model.credentialsForActiveSite().isEmpty
                        ? Color.browsemiumTertiary
                        : Color.browsemiumSecondary
                )
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Passwords")
    }

    private var overflowMenu: some View {
        Menu {
            Button("New Tab") { model.newTab() }
            Button("Reopen Closed Tab") { model.reopenClosedTab() }
            Divider()
            Button("History") { model.openPanel(.history) }
            Button("Bookmarks") { model.openPanel(.bookmarks) }
            Button(model.isBookmarksBarVisible ? "Hide Bookmarks Bar" : "Show Bookmarks Bar") {
                model.toggleBookmarksBar()
            }
            Button("Downloads") { model.openPanel(.downloads) }
            Divider()
            Button("Settings…") { model.openPanel(.settings) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.browsemiumSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions")
    }
}
