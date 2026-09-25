import AppKit
import BrowsemiumCore
import SwiftUI
import BrowsemiumEngineKit

/// Lets menu commands act on the focused window's model.
public struct BrowserModelFocusKey: FocusedValueKey {
    public typealias Value = BrowserWindowModel
}

public extension FocusedValues {
    var browserModel: BrowserWindowModel? {
        get { self[BrowserModelFocusKey.self] }
        set { self[BrowserModelFocusKey.self] = newValue }
    }
}

@MainActor
public struct BrowsemiumAppView: View {
    @State private var model: BrowserWindowModel
    @State private var ai: AIDockViewModel
    @State private var showFirstRun: Bool
    @State private var dockWidth: CGFloat = BrowserMetrics.restoredDockWidth

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let onboardingKey = "browsemium.hasCompletedOnboarding"

    public init(model: BrowserWindowModel = BrowserWindowModel()) {
        _model = State(initialValue: model)
        _ai = State(initialValue: AIDockViewModel(environment: model.environment))
        _showFirstRun = State(initialValue: !UserDefaults.standard.bool(forKey: Self.onboardingKey))
    }

    public var body: some View {
        ZStack {
            Color.browsemiumCanvas
                .ignoresSafeArea()

            GeometryReader { geometry in
                HStack(spacing: BrowserMetrics.elementSeparation) {
                    if model.tabLayout == .sidebar {
                        if model.isSidebarCollapsed {
                            collapsedSidebarRail
                        } else {
                            TabSidebar(model: model)
                                .browsemiumPanel()
                                .transition(sidebarTransition)
                        }
                    }

                    browserPanel

                    if model.isAIDockVisible {
                        AIDockView(model: model, ai: ai)
                            .frame(width: dockWidth)
                            // Live resizing must not animate; animating every
                            // drag frame is what made the dock feel laggy.
                            .animation(nil, value: dockWidth)
                            .browsemiumPanel()
                            .overlay(alignment: .leading) {
                                AIDockResizeHandle(
                                    width: $dockWidth,
                                    maximumWidth: dockMaximumWidth(in: geometry.size.width),
                                    onCommit: persistDockWidth
                                )
                            }
                            .transition(dockTransition)
                    }
                }
                .padding(.horizontal, BrowserMetrics.elementSeparation)
                .padding(.top, BrowserMetrics.windowEdgeInset)
                .padding(.bottom, BrowserMetrics.windowEdgeInset)
                .onChange(of: geometry.size.width) {
                    // A stored width must never squeeze the page out after the
                    // window shrinks.
                    dockWidth = min(dockWidth, dockMaximumWidth(in: geometry.size.width))
                }
            }

            if model.isCommandPaletteVisible {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { model.dismissCommandPalette() }
                CommandPaletteView(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            if let peek = model.peek {
                PeekOverlay(model: model, peek: peek)
            }

            if let request = model.pendingPermissionRequest {
                Color.black.opacity(0.24)
                    .ignoresSafeArea()
                PermissionPromptCard(request: request) { answer in
                    model.answerPermissionRequest(answer)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            if let extensionRequest = model.pendingExtensionPermission {
                Color.black.opacity(0.24)
                    .ignoresSafeArea()
                ExtensionPermissionCard(request: extensionRequest) { granted in
                    model.answerExtensionPermission(granted: granted)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            if let status = model.statusMessage, model.activePanel == .none {
                VStack {
                    Spacer()
                    ToastView(status)
                        .padding(.bottom, 28)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if let offer = model.webStoreOffer, model.activePanel == .none {
                VStack {
                    Spacer()
                    HStack {
                        WebStoreInstallBanner(model: model, offer: offer)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 16)
                    .padding(.bottom, 16)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: model.statusMessage) {
            guard model.statusMessage != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            model.statusMessage = nil
        }
        .frame(
            minWidth: BrowserMetrics.minimumWindowWidth,
            idealWidth: 1280,
            minHeight: BrowserMetrics.minimumWindowHeight,
            idealHeight: 800
        )
        .background(Color.browsemiumCanvas)
        .foregroundStyle(Color.browsemiumPrimary)
        .tint(Color.browsemiumFocus)
        .preferredColorScheme(preferredScheme)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.isAIDockVisible)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.isCommandPaletteVisible)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.peek?.tabID)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.tabLayout)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.isSidebarCollapsed)
        .sheet(isPresented: $showFirstRun) {
            FirstRunView(model: model) {
                UserDefaults.standard.set(true, forKey: Self.onboardingKey)
                showFirstRun = false
            } onMoveFromChrome: {
                UserDefaults.standard.set(true, forKey: Self.onboardingKey)
                showFirstRun = false
                model.openPanel(.settings)
            }
        }
        .onAppear {
            LaunchMetrics.mark(.firstFrame)
            model.startObservingRuntime()
            model.ensureLoaded(model.session.activeTabID ?? TabID())
            model.performDeferredStartup()
        }
        .focusedSceneValue(\.browserModel, model)
        .onOpenURL { url in
            // Links from other apps (Mail, Slack, Terminal) when Browsemium is
            // the default browser.
            model.newTab(url: url)
        }
        .onChange(of: model.profileSwitchToken) {
            // Provider panels and conversations belong to the previous
            // profile's WebKit data store and database — never carry them over.
            ai.providerPanel.releaseAll()
            ai.clearAttachments()
            ai.clearConversation()
            ai.refreshCredentialState()
        }
        .onChange(of: model.aiContextToken) {
            // Context captured from the page's context menu lands in the
            // assistant composer, ready for the user's question.
            ai.adopt(model.consumePendingAIContext())
        }
        .onChange(of: model.aiQuickActionToken) {
            // Palette/menu quick actions are consumed here, not in the dock:
            // the dock view does not exist while hidden, but this handler
            // does — and requestAIQuickAction opens the dock first.
            guard let action = model.consumePendingAIQuickAction() else { return }
            Task { await ai.runQuickAction(action, tabID: model.session.activeTabID) }
        }
        .onChange(of: model.assistantTaskToken) {
            // Saved skills fill the composer; "summarize open tabs" captures
            // each live tab and opens the review sheet. Neither sends.
            guard let task = model.consumePendingAssistantTask() else { return }
            switch task {
            case .skill(let skill):
                ai.applySkill(skill)
            case .summarizeOpenTabs:
                Task { await ai.runMultiTabSummary(windowModel: model) }
            }
        }
        .onDisappear {
            // A closed window must not keep receiving runtime events or hold
            // an unanswered permission request.
            model.stopObservingRuntime()
        }
    }

    private var dockTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity)
    }

    private var sidebarTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity)
    }

    /// The slim rail left behind when the sidebar collapses: traffic-light
    /// drag space on top, one expand button, and nothing else — the pane
    /// stays discoverable instead of vanishing entirely.
    private var collapsedSidebarRail: some View {
        VStack(spacing: 0) {
            WindowDragView()
                .frame(height: BrowserMetrics.sidebarTrafficLightInset)
            BrowsemiumIconButton(systemName: "sidebar.right", label: "Show sidebar") {
                model.toggleSidebarCollapsed()
            }
            Spacer(minLength: 0)
        }
        .frame(width: 30)
        .frame(maxHeight: .infinity)
        .browsemiumPanel()
        .transition(sidebarTransition)
        .help("Show sidebar")
        .accessibilityLabel("Show sidebar")
    }

    /// Persists the assistant dock width so it survives relaunches.
    private func persistDockWidth() {
        UserDefaults.standard.set(Double(dockWidth), forKey: BrowserMetrics.aiDockWidthDefaultsKey)
    }

    /// Half the window at most, and never so wide that the page is squeezed
    /// below a usable width.
    private func dockMaximumWidth(in windowWidth: CGFloat) -> CGFloat {
        let half = windowWidth * BrowserMetrics.aiDockMaximumWidthFraction
        let leavingRoomForPage = windowWidth - BrowserMetrics.minimumBrowserPanelWidth
        return max(
            BrowserMetrics.aiDockMinimumWidth,
            min(half, leavingRoomForPage)
        )
    }

    private var preferredScheme: ColorScheme? {
        switch model.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    private var browserPanel: some View {
        VStack(spacing: 0) {
            // In sidebar mode the strip is replaced by the floating sidebar;
            // the toolbar stays so navigation and the address bar are unmoved.
            if model.tabLayout == .top {
                BrowserTabStrip(model: model)

                Rectangle()
                    .fill(Color.browsemiumBorder)
                    .frame(height: 1)
            }

            BrowserToolbar(model: model)

            Rectangle()
                .fill(Color.browsemiumBorder)
                .frame(height: 1)

            if model.isBookmarksBarVisible, !model.bookmarks.isEmpty {
                BookmarksBar(model: model)

                Rectangle()
                    .fill(Color.browsemiumBorder)
                    .frame(height: 1)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    if model.isShowingAddressSuggestions {
                        // Drawn above the page and the bookmarks bar, centred
                        // under the address field.
                        AddressSuggestionList(model: model)
                            .padding(.top, 6)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if model.isFindBarVisible {
                        FindBar(model: model)
                            .padding(10)
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    // Panels and reader replace the page entirely; a leftover
                    // hover state can never clear there because the pointer is
                    // over app chrome, so the bar is gated off.
                    if let hovered = model.hoveredLinkURL,
                       model.activePanel == .none,
                       model.readerArticle == nil {
                        LinkStatusBar(url: hovered, favicon: model.favicons.image(for: hovered))
                            .padding(.leading, 8)
                            .padding(.bottom, 8)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    // Drag a tab to either edge to tile it beside the focused
                    // pane. The zones exist only while a drag is in progress,
                    // so ordinary clicking is untouched.
                    if model.isTabDragActive {
                        HStack(spacing: 0) {
                            SplitEdgeDropZone(model: model)
                            Spacer(minLength: 0)
                            SplitEdgeDropZone(model: model)
                        }
                        .transition(.opacity)
                    }
                }
        }
        .browsemiumPanel(background: .browsemiumRaised)
    }

    @ViewBuilder
    private var content: some View {
        if let article = model.readerArticle, model.activePanel == .none {
            ReaderView(model: model, article: article)
        } else {
            switch model.activePanel {
            case .history, .bookmarks, .downloads, .recentlyClosed:
                LibraryView(model: model)
            case .settings:
                SettingsView(model: model)
            case .none:
                webContent
            }
        }
    }

    @ViewBuilder
    private var webContent: some View {
        if model.isSplitViewActive {
            // Panes are separated by the border colour showing through a
            // one-point gap; the focused pane gets an accent bar.
            HStack(spacing: 1) {
                ForEach(model.visiblePanes, id: \.pane) { entry in
                    SplitPaneView(
                        model: model,
                        pane: entry.pane,
                        tab: entry.tab,
                        isPrimary: entry.pane == model.paneID
                    )
                }
            }
            .background(Color.browsemiumBorder)
        } else if let tabID = model.session.activeTabID,
           model.tabURLs[tabID] != nil || model.activeTab?.lastCommittedURL != nil {
            WebViewHost(
                engine: model.environment.engine,
                tabID: tabID,
                isPrivate: model.session.isPrivate
            )
            .onAppear { model.ensureLoaded(tabID) }
        } else {
            NewTabView(model: model)
        }
    }

}

/// Chrome-style status bar, grown into a small link-preview card: where the
/// hovered link points, which site it belongs to, and how to look inside it
/// without leaving the page. Read-only — clicking through it is impossible
/// by design.
@MainActor
private struct LinkStatusBar: View {
    let url: URL
    let favicon: NSImage?

    var body: some View {
        HStack(spacing: 7) {
            if let favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 13, height: 13)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                Image(systemName: "link")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.browsemiumTertiary)
                    .frame(width: 13, height: 13)
            }

            VStack(alignment: .leading, spacing: 1) {
                if let host = url.host {
                    Text(host)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.browsemiumSecondary)
                        .lineLimit(1)
                }
                Text(url.absoluteString)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.browsemiumSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Text("⌘-click to preview")
                .font(.system(size: 9))
                .foregroundStyle(Color.browsemiumTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.browsemiumField)
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 480, alignment: .leading)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: BrowserMetrics.controlRadius,
                topTrailingRadius: BrowserMetrics.controlRadius,
                style: .continuous
            )
            .fill(Color.browsemiumRaised.opacity(0.96))
        )
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: BrowserMetrics.controlRadius,
                topTrailingRadius: BrowserMetrics.controlRadius,
                style: .continuous
            )
            .stroke(Color.browsemiumBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 4, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Link to \(url.host ?? url.absoluteString)")
        .accessibilityHint("Command-click to preview the page")
    }
}

/// Transient feedback that never occupies permanent space in the chrome.
@MainActor
private struct ToastView: View {
    private let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(Color.browsemiumPrimary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: 380)
            .browsemiumPanel(background: .browsemiumRaised, radius: BrowserMetrics.controlRadius)
            .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
            .accessibilityAddTraits(.isStaticText)
    }
}

/// The bottom-left offer shown while the active tab is a Chrome Web Store
/// listing. Installing is one click; the wording is explicit that this is the
/// beta path and that Chrome-only features may not run.
@MainActor
private struct WebStoreInstallBanner: View {
    @Bindable var model: BrowserWindowModel
    let offer: BrowserWindowModel.WebStoreOffer

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.browsemiumSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.browsemiumField)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(offer.isInstalled
                     ? "“\(offer.name)” is already installed"
                     : "“\(offer.name)” is a Chrome extension")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.browsemiumPrimary)
                    .lineLimit(1)
                Text(offer.isInstalled
                     ? "Manage it in Settings. Chrome-only features may not run."
                     : "Install it in Browsemium (Beta). Chrome-only features may not run.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.browsemiumSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 290, alignment: .leading)

            HStack(spacing: 8) {
                BrowsemiumTextButton("Not now") {
                    model.dismissWebStoreOffer()
                }
                if offer.isInstalled {
                    BrowsemiumPrimaryButton("Settings") {
                        model.dismissWebStoreOffer()
                        model.openPanel(.settings)
                    }
                } else {
                    BrowsemiumPrimaryButton(
                        model.isInstallingFromWebStore ? "Installing…" : "Install",
                        isDisabled: model.isInstallingFromWebStore
                    ) {
                        model.installWebStoreOffer()
                    }
                }
            }
            .padding(.top, 1)
        }
        .padding(12)
        .browsemiumPanel(background: .browsemiumRaised, radius: BrowserMetrics.controlRadius)
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chrome extension available: \(offer.name). You can install it in Browsemium beta.")
    }
}

/// One edge of the content area while a tab is being dragged: dropping a tab
/// here tiles it beside the focused pane. Mounted only while a drag is in
/// progress, so it never sits under the pointer during ordinary clicking.
@MainActor
struct SplitEdgeDropZone: View {
    @Bindable var model: BrowserWindowModel
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            if isTargeted {
                Color.browsemiumFocus.opacity(0.10)
                Rectangle()
                    .fill(Color.browsemiumFocus)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 30)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            defer { model.endTabDrag() }
            guard let payload = items.first,
                  let uuid = UUID(uuidString: payload),
                  let tab = model.session.tabs.first(where: { $0.id.rawValue == uuid }) else {
                return false
            }
            model.dropTabOnSplitEdge(tab.id)
            return true
        } isTargeted: { isTargeted = $0 }
        .accessibilityHidden(true)
    }
}
