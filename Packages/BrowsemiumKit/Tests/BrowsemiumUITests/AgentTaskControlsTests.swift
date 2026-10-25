import BrowsemiumCore
import Foundation
import Testing
@testable import BrowsemiumUI

@Suite("Agent task panel controls")
struct AgentTaskControlsTests {
    private let active: [AgentTaskState] = [.waiting, .ready, .reading, .acting]

    @Test func everyStateOffersTheRightControls() {
        for state in active {
            #expect(AgentTaskControls.controls(for: state).map(\.kind) == [.takeOver, .stop], "\(state)")
        }
        #expect(AgentTaskControls.controls(for: .paused).map(\.kind) == [.handBack, .stop])
        #expect(AgentTaskControls.controls(for: .finished).map(\.kind) == [.close])
        #expect(AgentTaskControls.controls(for: .stopped).map(\.kind) == [.close])
    }

    @Test func theTaskCanAlwaysBeEndedWithoutClosingTheWindowWhileItIsLive() {
        for state in active + [.paused] {
            #expect(AgentTaskControls.controls(for: state).contains { $0.kind == .stop }, "\(state)")
        }
    }

    @Test func everyControlHasALabelAHintAndAUniqueKeyAmongThoseShownTogether() {
        let states: [AgentTaskState] = [.ready, .paused, .finished, .stopped, .waiting]
        for state in states {
            let controls = AgentTaskControls.controls(for: state)
            for control in controls {
                #expect(!control.title.isEmpty)
                #expect(control.hint.count > 15, "\(control.title) needs a hint that says what it does")
            }
            let shortcuts = controls.compactMap(\.shortcutDescription)
            #expect(Set(shortcuts).count == shortcuts.count, "\(state) shows two controls with one key")
        }
    }

    @Test func stopIsDestructiveAndHandBackIsThePrimaryActionWhilePaused() {
        let paused = AgentTaskControls.controls(for: .paused)
        #expect(paused.first { $0.kind == .handBack }?.isPrimary == true)
        #expect(paused.first { $0.kind == .stop }?.isDestructive == true)
        #expect(AgentTaskControls.stop.shortcutDescription == "⌘.")
        #expect(AgentTaskControls.takeOver.shortcutDescription == "⌥⌘P")
    }

    @Test func theHintsStateTheLimitsHonestly() {
        #expect(AgentTaskControls.takeOver.hint.contains("pages stay open"))
        #expect(AgentTaskControls.handBack.hint.contains("time and calls it has left"), "The clock keeps running during a takeover")
        #expect(AgentTaskControls.stop.hint.contains("pages stay open"))
    }

    @Test func stateChangesAreAnnouncedForVoiceOver() {
        #expect(AgentTaskControls.announcement(from: .ready, to: .paused)?.contains("in control") == true)
        #expect(AgentTaskControls.announcement(from: .paused, to: .ready)?.contains("handed back") == true)
        #expect(AgentTaskControls.announcement(from: .acting, to: .stopped) == "The task was stopped.")
        #expect(AgentTaskControls.announcement(from: .acting, to: .finished) == "The task has ended.")
        #expect(AgentTaskControls.announcement(from: .ready, to: .waiting)?.contains("waiting for your answer") == true)
        #expect(AgentTaskControls.announcement(from: .ready, to: .reading) == nil, "Routine progress is not announced")
        #expect(AgentTaskControls.announcement(from: .ready, to: .ready) == nil)
    }
}
