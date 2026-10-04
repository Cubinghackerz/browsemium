import AppKit
import BrowsemiumAgent
import BrowsemiumCore
import BrowsemiumEngine
import SwiftUI

/// The task window. It is a non-activating panel, so showing it never steals
/// focus or changes the person's selected tab in any browser window. Closing
/// it is a Stop.
@MainActor
final class AgentPanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private weak var coordinator: AgentCoordinator?

    init(coordinator: AgentCoordinator) {
        self.coordinator = coordinator
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = "Agent task"
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 560, height: 440)
        panel.contentView = NSHostingView(rootView: AgentTaskView(coordinator: coordinator))
        panel.setFrameAutosaveName("BrowsemiumAgentTask")
        if !panel.setFrameUsingName("BrowsemiumAgentTask") { panel.center() }
        panel.delegate = self
    }

    /// Orders the panel in without activating the app. `attention` asks the
    /// Dock to bounce once (informational), which is the only nudge.
    func show(attention: Bool) {
        panel.orderFront(nil)
        if attention { NSApp.requestUserAttention(.informationalRequest) }
    }

    func close() {
        guard panel.isVisible else { return }
        panel.delegate = nil
        panel.orderOut(nil)
        panel.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        coordinator?.panelDidClose()
    }
}

// MARK: - Task view

@MainActor
struct AgentTaskView: View {
    @Bindable var coordinator: AgentCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var gate: AgentActionGate { coordinator.gate }

    var body: some View {
        ZStack {
            Color.browsemiumRaised.ignoresSafeArea()

            if let pending = coordinator.pendingGrant, !gate.state.hasAuthority {
                AgentGrantCard(coordinator: coordinator, pending: pending)
            } else if gate.task != nil {
                taskContent
            } else {
                Text("No task is running.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.browsemiumSecondary)
            }
        }
        .foregroundStyle(Color.browsemiumPrimary)
        .overlay {
            // A restrained border marks a window the agent can act in. With
            // Reduce Motion it is static.
            if gate.state.hasAuthority {
                Rectangle()
                    .strokeBorder(Color.browsemiumFocus.opacity(reduceMotion ? 0.7 : (pulse ? 0.85 : 0.35)), lineWidth: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
        }
        .onChange(of: gate.pendingApproval?.id) {
            if gate.pendingApproval != nil { coordinator.requestAttention() }
        }
    }

    private var taskContent: some View {
        VStack(spacing: 0) {
            AgentActivityBar(coordinator: coordinator)
            Rectangle().fill(Color.browsemiumBorder).frame(height: 1)
            tabPicker
            ZStack(alignment: .bottom) {
                AgentPageHost(actuator: coordinator.actuator, tab: currentTab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.browsemiumCanvas)
                if gate.state == .paused {
                    banner("You are in control. The agent cannot act until you hand control back.")
                } else if !gate.state.hasAuthority {
                    banner(endedMessage)
                }
                if let request = gate.pendingApproval {
                    AgentApprovalCard(gate: gate, request: request)
                        .padding(14)
                        .transition(.opacity)
                }
            }
            Rectangle().fill(Color.browsemiumBorder).frame(height: 1)
            AgentTimeline(entries: gate.audit)
        }
    }

    private var currentTab: TabID? {
        if let selected = coordinator.selectedTab, gate.tabs.contains(selected) { return selected }
        return gate.tabs.first
    }

    @ViewBuilder
    private var tabPicker: some View {
        if gate.tabs.count > 1 {
            HStack(spacing: 6) {
                ForEach(Array(gate.tabs.enumerated()), id: \.element) { index, tab in
                    Button("Tab \(index + 1)") { coordinator.selectedTab = tab }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: tab == currentTab ? .semibold : .regular))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(tab == currentTab ? Color.browsemiumSelection : Color.clear))
                        .accessibilityLabel("Task tab \(index + 1)")
                        .accessibilityAddTraits(tab == currentTab ? .isSelected : [])
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Rectangle().fill(Color.browsemiumBorder).frame(height: 1)
        }
    }

    private var endedMessage: String {
        switch gate.state {
        case .finished: "This task has ended. The pages stay here for you; close the window when you are done."
        default: "This task was stopped. The pages stay here for you; close the window when you are done."
        }
    }

    private func banner(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.browsemiumRaised.opacity(0.96))
            .overlay(alignment: .top) { Rectangle().fill(Color.browsemiumBorder).frame(height: 1) }
            .frame(maxHeight: .infinity, alignment: .top)
            .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Activity bar

@MainActor
private struct AgentActivityBar: View {
    @Bindable var coordinator: AgentCoordinator
    private var gate: AgentActionGate { coordinator.gate }

    var body: some View {
        HStack(spacing: 10) {
            statePill
            VStack(alignment: .leading, spacing: 1) {
                Text(gate.task?.title ?? "")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.browsemiumSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if gate.state == .paused {
                BrowsemiumPrimaryButton("Hand back") { coordinator.handBack() }
            } else if gate.state.hasAuthority {
                BrowsemiumTextButton("Take over") { coordinator.takeOver() }
                BrowsemiumTextButton("Stop", role: .destructive) { coordinator.stopTask() }
            } else {
                BrowsemiumPrimaryButton("Close") { coordinator.closeWorkspace() }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .accessibilityElement(children: .contain)
    }

    private var detail: String {
        let client = "Requested by “\(gate.task?.clientName ?? "")” (name not verified)"
        guard gate.state.hasAuthority || gate.state == .paused, let end = gate.expiresAt else { return client }
        let minutes = max(0, Int(end.timeIntervalSinceNow) / 60)
        return "\(client) · \(minutes) min and \(gate.callsRemaining) calls left"
    }

    private var statePill: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11.5, weight: .semibold))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(Color.browsemiumField))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Task state: \(label)")
    }

    private var label: String {
        switch gate.state {
        case .waiting: "Waiting for you"
        case .ready: "Ready"
        case .reading: "Reading"
        case .acting: "Acting"
        case .paused: "Paused"
        case .finished: "Finished"
        case .stopped: "Stopped"
        }
    }

    private var color: Color {
        switch gate.state {
        case .waiting: .browsemiumWarning
        case .ready, .reading, .acting: .browsemiumSuccess
        case .paused: .browsemiumTertiary
        case .finished, .stopped: .browsemiumSecondary
        }
    }
}

// MARK: - Grant card

@MainActor
private struct AgentGrantCard: View {
    @Bindable var coordinator: AgentCoordinator
    let pending: AgentCoordinator.PendingGrant
    @State private var armed = false
    @FocusState private var declineFocused: Bool

    private var request: AgentGrantRequest { pending.request }
    private var profileName: String { coordinator.profileName }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.browsemiumWarning)
                        .accessibilityHidden(true)
                    Text("Allow this task?")
                        .font(.system(size: 17, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                }

                fact("Asked by", "“\(request.clientName)” — this name is supplied by the app and cannot be verified.")
                fact("Task", request.title)
                fact("Profile", "\(profileName). Pages open with this profile's logins and cookies.")

                VStack(alignment: .leading, spacing: 4) {
                    label("Sites it may use")
                    ForEach(request.origins, id: \.description) { origin in
                        Text(origin.description)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    label("It will be able to")
                    capability("Read the text of pages on those sites")
                    capability("Navigate within those sites")
                    if request.capabilities.contains(.interact) {
                        capability("Click and type — you confirm every one")
                    }
                    if request.capabilities.contains(.screenshot) {
                        capability("Take screenshots, which may show sensitive information")
                    }
                }

                Text("The grant ends after 15 minutes or 100 actions. You can take over or stop at any time. Page text and screenshots may be passed on by the app to its AI model. If you are logged in to these sites, the task can change your accounts, and Browsemium cannot tell whether a page action is harmless.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.browsemiumSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Spacer()
                    // Decline is the focused choice, and there is no default
                    // (Return) action: approving needs a deliberate click.
                    Button("Decline") { coordinator.answerGrant(false) }
                        .keyboardShortcut(.cancelAction)
                        .focused($declineFocused)
                    BrowsemiumPrimaryButton("Allow task", isDisabled: !armed) { coordinator.answerGrant(true) }
                }
            }
            .padding(22)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: pending.id) {
            armed = false
            declineFocused = true
            try? await Task.sleep(for: .seconds(AgentCoordinator.approveDelay))
            armed = true
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.browsemiumSecondary)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            label(title)
            Text(value).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func capability(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.browsemiumSecondary)
                .accessibilityHidden(true)
            Text(text).font(.system(size: 12.5))
        }
    }
}

// MARK: - Approval card

@MainActor
private struct AgentApprovalCard: View {
    let gate: AgentActionGate
    let request: AgentApprovalRequest
    @State private var armed = false
    @FocusState private var declineFocused: Bool

    private var verb: String { request.kind == .click ? "click" : "type into" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The task wants to \(verb) an element")
                .font(.system(size: 13.5, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            // The label is the page's own text, so it is quoted and labelled.
            Text("On \(request.origin.description), the page calls it “\(request.name)” (\(request.role)). This label comes from the page and may not describe what really happens.")
                .font(.system(size: 12))
                .foregroundStyle(Color.browsemiumSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let typed = request.typedText {
                Text(typed.count > 400 ? String(typed.prefix(400)) + "…" : typed)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.browsemiumField))
                    .accessibilityLabel("Text to type: \(typed.prefix(400))")
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Decline") { gate.resolveApproval(id: request.id, approved: false) }
                    .keyboardShortcut(.cancelAction)
                    .focused($declineFocused)
                BrowsemiumPrimaryButton(request.kind == .click ? "Allow click" : "Allow typing", isDisabled: !armed) {
                    guard armed else { return }
                    gate.resolveApproval(id: request.id, approved: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 560)
        .background(RoundedRectangle(cornerRadius: BrowserMetrics.overlayRadius, style: .continuous).fill(Color.browsemiumRaised))
        .overlay(RoundedRectangle(cornerRadius: BrowserMetrics.overlayRadius, style: .continuous)
            .stroke(Color.browsemiumBorderStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 14, y: 4)
        .accessibilityElement(children: .contain)
        .task(id: request.id) {
            armed = false
            declineFocused = true
            try? await Task.sleep(for: .seconds(AgentCoordinator.approveDelay))
            armed = true
        }
    }
}

// MARK: - Timeline

@MainActor
private struct AgentTimeline: View {
    let entries: [AgentAuditEntry]
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if entries.isEmpty {
                Text("Nothing has happened yet.")
                    .font(.system(size: 11.5)).foregroundStyle(Color.browsemiumTertiary)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(entries.suffix(30).reversed()) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.time, style: .time)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.browsemiumTertiary)
                                Text(entry.action).font(.system(size: 11.5, weight: .medium))
                                Text(entry.origin).font(.system(size: 11)).foregroundStyle(Color.browsemiumSecondary).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(entry.result).font(.system(size: 11)).foregroundStyle(Color.browsemiumSecondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            }
        } label: {
            Text("Activity").font(.system(size: 11.5, weight: .semibold))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

// MARK: - Page host

/// Hosts the task's WKWebView. Attaching only parents the view; it never
/// selects a tab in a browser window or makes anything first responder.
@MainActor
private struct AgentPageHost: NSViewRepresentable {
    let actuator: WebKitPageActuator
    let tab: TabID?

    final class Holder { var attached: TabID? }

    func makeCoordinator() -> Holder { Holder() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.attached != tab else { return }
        if let old = context.coordinator.attached { actuator.detach(old) }
        context.coordinator.attached = tab
        if let tab { actuator.attach(tab, to: view) }
    }
}
