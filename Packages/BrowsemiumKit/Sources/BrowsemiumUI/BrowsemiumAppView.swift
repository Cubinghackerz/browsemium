import AppKit
import BrowsemiumCore
import SwiftUI

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

            if let status = model.statusMessage, model.activePanel == .none {
                VStack {
                    Spacer()
                    ToastView(status)
                        .padding(.bottom, 28)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
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
        .sheet(isPresented: $showFirstRun) {
            FirstRunView(model: model) {
                UserDefaults.standard.set(true, forKey: Self.onboardingKey)
                showFirstRun = false
            }
        }
        .onAppear {
            model.ensureLoaded(model.session.activeTabID ?? TabID())
        }
    }

    private var dockTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity)
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
            BrowserTabStrip(model: model)

            Rectangle()
                .fill(Color.browsemiumBorder)
                .frame(height: 1)

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
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
        }
        .browsemiumPanel(background: .browsemiumRaised)
    }

    @ViewBuilder
    private var content: some View {
        switch model.activePanel {
        case .history, .bookmarks, .downloads:
            LibraryView(model: model)
        case .settings:
            SettingsView(model: model)
        case .none:
            if let tabID = model.session.activeTabID,
               model.tabURLs[tabID] != nil || model.activeTab?.lastCommittedURL != nil {
                WebViewHost(
                    runtime: model.environment.runtime,
                    tabID: tabID,
                    isPrivate: model.session.isPrivate
                )
                .onAppear { model.ensureLoaded(tabID) }
            } else {
                NewTabView(model: model)
            }
        }
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
