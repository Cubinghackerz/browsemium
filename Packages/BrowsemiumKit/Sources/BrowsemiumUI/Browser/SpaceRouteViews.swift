import BrowsemiumCore
import SwiftUI

/// The bottom-left notice for a routed tab: either "moved, undo" or, for a
/// locked destination, a choice that has not moved anything yet.
@MainActor
struct SpaceRouteNoticeBanner: View {
    @Bindable var model: BrowserWindowModel
    let notice: SpaceRouteCoordinator.Notice

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(BrowserType.font(.title))
                .foregroundStyle(Color.browsemiumSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.browsemiumField)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(BrowserType.font(.small, weight: .medium))
                    .foregroundStyle(Color.browsemiumPrimary)
                    .lineLimit(2)
                Text(detail)
                    .font(BrowserType.font(.caption))
                    .foregroundStyle(Color.browsemiumSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 290, alignment: .leading)

            HStack(spacing: 8) {
                switch notice {
                case .moved:
                    BrowsemiumTextButton("Dismiss") { model.routing.dismissNotice() }
                    BrowsemiumPrimaryButton("Undo") { model.routing.undo() }
                case .needsUnlock:
                    BrowsemiumTextButton("Not now") { model.routing.dismissNotice() }
                    BrowsemiumPrimaryButton("Unlock and move") { model.routing.confirmUnlockAndMove() }
                }
            }
            .padding(.top, 1)
        }
        .padding(12)
        .browsemiumOverlaySurface(radius: BrowserMetrics.controlRadius, shadowRadius: 12, shadowY: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(detail)")
    }

    private var icon: String {
        switch notice {
        case .moved: "arrow.right.square"
        case .needsUnlock: "lock"
        }
    }

    private var title: String {
        switch notice {
        case .moved(let moved): "Moved to \(moved.toSpaceName)"
        case .needsUnlock(let pending): "\(pending.host) belongs in \(pending.toSpaceName)"
        }
    }

    private var detail: String {
        switch notice {
        case .moved(let moved): "\(moved.host) is set to open here. It was in \(moved.fromSpaceName)."
        case .needsUnlock(let pending): "\(pending.toSpaceName) is locked, so the tab has not moved. Unlocking asks for Touch ID or your password."
        }
    }
}

/// Settings: the profile's routing rules, with an editor for a new one.
@MainActor
struct SpaceRoutesSettingsView: View {
    @Bindable var model: BrowserWindowModel
    @State private var host = ""
    @State private var includesSubdomains = false
    @State private var spaceID: SpaceID?
    @State private var problem: String?

    var body: some View {
        SettingsCard("Site routing", systemImage: "arrow.triangle.branch") {
            if model.routing.routes.isEmpty {
                SettingsRow("No rules yet") {
                    Text("Send a site to a space, such as github.com to Work.")
                        .font(BrowserType.font(.small))
                        .foregroundStyle(Color.browsemiumSecondary)
                }
            } else {
                ForEach(model.routing.routes) { route in
                    SettingsRow(route.host + (route.includesSubdomains ? " and subdomains" : "")) {
                        HStack(spacing: 12) {
                            Text(spaceName(route.spaceID))
                                .font(BrowserType.font(.small))
                                .foregroundStyle(spaceExists(route.spaceID) ? Color.browsemiumSecondary : Color.browsemiumWarning)
                            BrowsemiumTextButton("Remove", role: .destructive) {
                                model.routing.removeRoute(route)
                            }
                        }
                    }
                }
            }

            SettingsRow("Add a rule") {
                HStack(spacing: 8) {
                    TextField("github.com", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(minWidth: 140)
                        .onSubmit { add() }
                        .accessibilityLabel("Site to route")
                    Picker("Space", selection: spaceBinding) {
                        ForEach(model.session.spaces) { space in
                            Text(space.name).tag(Optional(space.id))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 130)
                    BrowsemiumTextButton("Add") { add() }
                        .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            SettingsRow("Include subdomains") {
                Toggle("", isOn: $includesSubdomains)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Color.browsemiumAccentFill)
                    .accessibilityLabel("Include subdomains")
            }
            if let problem {
                Text(problem)
                    .font(BrowserType.font(.small))
                    .foregroundStyle(Color.browsemiumWarning)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            SettingsNote("When a tab you are looking at loads a routed site, it moves to that space and a notice lets you undo it. Private windows, previews, background tabs, pinned tabs and split view are never moved. A locked space asks before anything moves into it.")
        }
    }

    private var spaceBinding: Binding<SpaceID?> {
        Binding(
            get: { spaceID ?? model.session.spaces.first?.id },
            set: { spaceID = $0 }
        )
    }

    private func spaceExists(_ id: SpaceID) -> Bool {
        model.session.spaces.contains { $0.id == id }
    }

    private func spaceName(_ id: SpaceID) -> String {
        model.session.spaces.first { $0.id == id }?.name ?? "Missing space"
    }

    private func add() {
        guard let target = spaceBinding.wrappedValue else { return }
        switch SpaceRouteHost.normalize(host, includesSubdomains: includesSubdomains) {
        case .failure(let error):
            problem = error.message
        case .success:
            problem = nil
            if model.routing.setRoute(host: host, includesSubdomains: includesSubdomains, to: target) {
                host = ""
                model.routing.routeActiveTabNow()
            }
        }
    }
}

/// Offers to remember a password after a sign-in. It appears only after the
/// person submitted the form, and nothing is stored until they press Save.
@MainActor
struct PasswordSaveBanner: View {
    @Bindable var model: BrowserWindowModel
    let offer: BrowserWindowModel.PasswordSaveOffer

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "key")
                .font(BrowserType.font(.title))
                .foregroundStyle(Color.browsemiumSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.browsemiumField)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Save password for \(offer.host)?")
                    .font(BrowserType.font(.small, weight: .medium))
                    .foregroundStyle(Color.browsemiumPrimary)
                    .lineLimit(1)
                Text("\(offer.username) · Saved to your Keychain on this Mac, and only filled when you choose.")
                    .font(BrowserType.font(.caption))
                    .foregroundStyle(Color.browsemiumSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 290, alignment: .leading)

            HStack(spacing: 8) {
                BrowsemiumTextButton("Not now") { model.declinePasswordOffer() }
                BrowsemiumPrimaryButton("Save") { model.savePasswordOffer() }
            }
            .padding(.top, 1)
        }
        .padding(12)
        .browsemiumOverlaySurface(radius: BrowserMetrics.controlRadius, shadowRadius: 12, shadowY: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Save the password for \(offer.host)? Saved to your Keychain on this Mac.")
    }
}
