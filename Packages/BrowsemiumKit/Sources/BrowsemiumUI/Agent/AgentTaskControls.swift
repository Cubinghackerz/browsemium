import BrowsemiumCore
import SwiftUI

/// One button in the task panel's control row.
struct AgentTaskControl: Equatable, Identifiable {
    enum Kind: String, Equatable { case takeOver, handBack, stop, close }

    let kind: Kind
    let title: String
    /// Read by VoiceOver after the label: what pressing it does, in full.
    let hint: String
    let isPrimary: Bool
    let isDestructive: Bool
    /// A key equivalent, always with Command. Nil means none.
    let shortcutKey: Character?
    let shortcutOption: Bool

    var id: Kind { kind }

    var shortcutDescription: String? {
        shortcutKey.map { (shortcutOption ? "⌥" : "") + "⌘" + String($0).uppercased() }
    }
}

/// Which controls the task panel offers in each state. One place, so the view,
/// the tests and the VoiceOver wording cannot drift apart.
///
/// The person can always do two things while a task has authority or is
/// paused: take over (or hand back) and stop. Ending the task from a paused
/// state must not require closing the window.
enum AgentTaskControls {
    static let takeOver = AgentTaskControl(
        kind: .takeOver, title: "Take over",
        hint: "Pauses the agent. It cannot act until you hand control back, and its pages stay open.",
        isPrimary: false, isDestructive: false, shortcutKey: "p", shortcutOption: true
    )
    static let handBack = AgentTaskControl(
        kind: .handBack, title: "Hand back",
        hint: "Lets the agent continue within the time and calls it has left.",
        isPrimary: true, isDestructive: false, shortcutKey: "p", shortcutOption: true
    )
    static let stop = AgentTaskControl(
        kind: .stop, title: "Stop",
        hint: "Ends the task now. The pages stay open for you.",
        isPrimary: false, isDestructive: true, shortcutKey: ".", shortcutOption: false
    )
    static let close = AgentTaskControl(
        kind: .close, title: "Close",
        hint: "Closes the task window and its pages.",
        isPrimary: true, isDestructive: false, shortcutKey: nil, shortcutOption: false
    )

    static func controls(for state: AgentTaskState) -> [AgentTaskControl] {
        switch state {
        case .waiting, .ready, .reading, .acting: [takeOver, stop]
        case .paused: [handBack, stop]
        case .finished, .stopped: [close]
        }
    }

    /// What VoiceOver announces when the state changes, or nil for none.
    static func announcement(from old: AgentTaskState, to new: AgentTaskState) -> String? {
        guard old != new else { return nil }
        switch new {
        case .paused: return "You are in control. The agent is paused."
        case .finished: return "The task has ended."
        case .stopped: return "The task was stopped."
        case .ready where old == .paused: return "Control handed back to the agent."
        case .waiting: return "The task is waiting for your answer."
        default: return nil
        }
    }

    @MainActor
    static func perform(_ kind: AgentTaskControl.Kind, on coordinator: AgentCoordinator) {
        switch kind {
        case .takeOver: coordinator.takeOver()
        case .handBack: coordinator.handBack()
        case .stop: coordinator.stopTask()
        case .close: coordinator.closeWorkspace()
        }
    }
}

/// Renders a control with its label, hint and key equivalent.
@MainActor
struct AgentTaskControlButton: View {
    let control: AgentTaskControl
    let action: () -> Void

    var body: some View {
        Group {
            if control.isPrimary {
                BrowsemiumPrimaryButton(control.title, action: action)
            } else {
                BrowsemiumTextButton(control.title, role: control.isDestructive ? .destructive : .normal, action: action)
            }
        }
        .accessibilityHint(control.hint)
        .help(control.shortcutDescription.map { "\(control.title) (\($0))" } ?? control.title)
        .modifier(OptionalShortcut(key: control.shortcutKey, option: control.shortcutOption))
    }
}

private struct OptionalShortcut: ViewModifier {
    let key: Character?
    let option: Bool

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: option ? [.command, .option] : .command)
        } else {
            content
        }
    }
}
