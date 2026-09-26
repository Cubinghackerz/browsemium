import AppKit
import BrowsemiumCore
import BrowsemiumExtensions
import SwiftUI
import BrowsemiumEngineKit

@MainActor
struct BrowserToolbar: View {
    @Bindable var model: BrowserWindowModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @FocusState private var addressFocused: Bool
    @State private var isFieldHovering = false
    @State private var isSearchEnginePanelPresented = false
    @State private var isOverflowPanelPresented = false
    @State private var isCredentialPanelPresented = false
    @State private var actionPresenter: ExtensionActionPresenter?

    var body: some View {
        HStack(spacing: 4) {
            if model.session.isPrivate {
                privateBadge
            }

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

            siteShield

            downloadIndicator

            extensionActionButtons

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

            privateWindowButton

            overflowMenu
        }
        .padding(.horizontal, 8)
        .frame(height: BrowserMetrics.toolbarHeight)
        .frame(maxWidth: .infinity)
        .onAppear {
            if #available(macOS 15.4, *) {
                let presenter = actionPresenter ?? ExtensionActionPresenter(model: model)
                actionPresenter = presenter
                model.registerExtensionActionPresenter(presenter)
            }
        }        .onDisappear {
            if #available(macOS 15.4, *), let presenter = actionPresenter {
                model.unregisterExtensionActionPresenter(presenter)
            }
        }
    }

    /// One button per extension action. Left-click runs the action (a popup
    /// action opens its popover, anchored to the button); right-click shows
    /// the extension's own menu items plus Browsemium's management entries.
    @ViewBuilder
    private var extensionActionButtons: some View {
        ForEach(model.extensionActions) { action in
            ExtensionActionButtonView(
                model: model,
                action: action,
                presenter: actionPresenter
            )
        }
    }

    /// The incognito toggle. In a normal window it opens a private window
    /// (⌘⇧N); in a private window it is lit and closes the window — a private
    /// session is disposable by definition, so there is nothing to "switch
    /// back" to and the user's normal tabs were never touched.
    private var privateWindowButton: some View {
        BrowsemiumIconButton(
            systemName: model.session.isPrivate ? "theatermasks.fill" : "theatermasks",
            label: model.session.isPrivate ? "Close Private Window" : "New Private Window",
            isActive: model.session.isPrivate
        ) {
            BrowserHaptics.perform()
            if model.session.isPrivate {
                dismiss()
            } else {
                PrivateWindowRequest.shared.arm()
                openWindow(id: "main")
            }
        }
        .help(model.session.isPrivate ? "Close this private window (⌘W)" : "New Private Window (⇧⌘N)")
    }

    /// Always-visible proof of which mode the window is in — a private
    /// session must be unmistakable at a glance.
    private var siteShield: some View {
        let paused = model.isBlockingPaused(for: model.activePageURL)
        return BrowsemiumIconButton(
            systemName: paused ? "shield.slash" : "shield",
            label: paused ? "Blocking paused on this site" : "Site protection",
            isActive: paused || model.pendingElementPick != nil
        ) {
            model.isSiteShieldPresented = true
        }
        // The picker opens this panel for its confirmation step, so the
        // presentation state lives on the model rather than in the toolbar.
        .popover(isPresented: $model.isSiteShieldPresented, arrowEdge: .bottom) {
            SiteShieldPanel(model: model)
            .presentationBackground(.clear)
        }
        .help(model.siteShieldStatus)
    }

    private var privateBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "theatermasks.fill")
                .font(.system(size: 9, weight: .semibold))
            Text("Private")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(Self.privateTint)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(
            Capsule().fill(Self.privateTint.opacity(0.14))
        )
        .overlay {
            Capsule().stroke(Self.privateTint.opacity(0.35), lineWidth: 1)
        }
        .accessibilityLabel("Private browsing window")
        .help("Nothing from this window is saved to disk")
    }

    /// The private-mode accent — a violet that reads clearly in both
    /// appearances without colliding with the app accent.
    static let privateTint = Color(red: 0.52, green: 0.36, blue: 0.92)

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
                        Text("\(download.filename) — Downloaded")
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
                    ? "Downloading \(model.activeDownloads.count) \(model.activeDownloads.count == 1 ? "file" : "files")"
                    : "Downloads"
            )
        }
    }

    /// Quick search-engine switch, right in the address bar. The chosen engine
    /// becomes the default; typing "!d query" uses one engine for a single
    /// search without changing it.
    private var searchEngineMenu: some View {
        Button {
            BrowserHaptics.perform()
            isSearchEnginePanelPresented = true
        } label: {
            HStack(spacing: 4) {
                SearchEngineMark(engineName: model.activeSearchEngineName, size: 16)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Color.browsemiumTertiary)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isSearchEnginePanelPresented, arrowEdge: .bottom) {
            SearchEngineMenuPanel(model: model) {
                isSearchEnginePanelPresented = false
            }
                .presentationBackground(.clear)
        }
        .help("Search engine: \(model.activeSearchEngineName). Type !g, !d, !b or !br for a one-off search.")
        .accessibilityLabel("Search engine, \(model.activeSearchEngineName)")
    }

    private var credentialMenu: some View {
        Button {
            BrowserHaptics.perform()
            isCredentialPanelPresented = true
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
        .buttonStyle(.plain)
        .popover(isPresented: $isCredentialPanelPresented, arrowEdge: .bottom) {
            CredentialMenuPanel(model: model) {
                isCredentialPanelPresented = false
            }
            .presentationBackground(.clear)
        }
        .help("Passwords")
        .accessibilityLabel("Passwords")
    }

    private var overflowMenu: some View {
        Button {
            BrowserHaptics.perform()
            isOverflowPanelPresented = true
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.browsemiumSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOverflowPanelPresented, arrowEdge: .bottom) {
            OverflowMenuPanel(model: model) {
                isOverflowPanelPresented = false
            }
            .presentationBackground(.clear)
        }
        .help("More actions")
        .accessibilityLabel("More actions")
    }
}

/// One extension's toolbar button: icon (or a puzzle piece when the
/// extension ships no icon), badge, tooltip, and the management menu.
@MainActor
private struct ExtensionActionButtonView: View {
    @Bindable var model: BrowserWindowModel
    let action: BrowserWindowModel.ExtensionActionButton
    let presenter: ExtensionActionPresenter?

    @State private var isHovering = false

    var body: some View {
        Button {
            BrowserHaptics.perform()
            model.performExtensionAction(action.id)
        } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let icon = action.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.browsemiumSecondary)
                    }
                }
                .frame(width: 16, height: 16)

                if let badge = action.badgeText {
                    Text(badge)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 0.5)
                        .background(
                            Capsule().fill(action.hasUnreadBadgeText ? Color.browsemiumFocus : Color.browsemiumSecondary)
                        )
                        .offset(x: 5, y: -4)
                }
            }
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: BrowserMetrics.controlRadius, style: .continuous)
                    .fill(isHovering ? Color.browsemiumHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.5)
        .onHover { isHovering = $0 }
        .background(
            ToolbarAnchorView { view in
                if #available(macOS 15.4, *) {
                    presenter?.register(view, for: action.id)
                }
            }
        )
        .contextMenu {
            ExtensionMenuItemsView(items: model.extensionActionMenuItems(action.id))
            if !model.extensionActionMenuItems(action.id).isEmpty {
                Divider()
            }
            Button("Extension Options…") { model.openExtensionOptions(action.id) }
            Button("Reload Extension") { model.reloadExtension(action.id) }
            Divider()
            Button("Remove “\(action.label)”", role: .destructive) {
                model.removeExtension(action.id)
            }
        }
        .help(action.label)
        .accessibilityLabel("\(action.label) extension action")
    }
}

/// Renders `NSMenuItem`s supplied by an extension inside a SwiftUI menu.
@MainActor
private struct ExtensionMenuItemsView: View {
    let items: [NSMenuItem]

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            if item.isSeparatorItem {
                Divider()
            } else {
                Button(item.title) {
                    guard let action = item.action else { return }
                    NSApp.sendAction(action, to: item.target, from: item)
                }
                .disabled(!item.isEnabled)
            }
        }
    }
}
