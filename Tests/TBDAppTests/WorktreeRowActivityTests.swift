import Foundation
import Testing
import TBDShared
@testable import TBDApp

@Suite("WorktreeRowView — foreground activity")
struct WorktreeRowActivityTests {
    private func terminal(
        kind: TerminalKind,
        activityState: TerminalActivityState
    ) -> TBDShared.Terminal {
        TBDShared.Terminal(
            worktreeID: UUID(),
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            kind: kind,
            activityState: activityState
        )
    }

    @Test func claudeUsesRawWorkingActivity() {
        let claude = terminal(kind: .claude, activityState: .working)

        #expect(WorktreeRowView.isForegroundWorking(claude))
    }

    @Test func claudeRawNonworkingActivityDoesNotAnimate() {
        let idle = terminal(kind: .claude, activityState: .idle)
        let waiting = terminal(kind: .claude, activityState: .waitingForUser)

        #expect(!WorktreeRowView.isForegroundWorking(idle))
        #expect(!WorktreeRowView.isForegroundWorking(waiting))
    }

    /// Codex reads its column the same way Claude does: the column is the
    /// agent's own report.
    @Test func codexWorkingColumnAnimates() {
        let codex = terminal(kind: .codex, activityState: .working)

        #expect(WorktreeRowView.isForegroundWorking(codex))
    }

    @Test func codexNonworkingColumnDoesNotAnimate() {
        let idle = terminal(kind: .codex, activityState: .idle)
        let waiting = terminal(kind: .codex, activityState: .waitingForUser)

        #expect(!WorktreeRowView.isForegroundWorking(idle))
        #expect(!WorktreeRowView.isForegroundWorking(waiting))
    }

    @Test func terminalCollectionReportsAnyForegroundWork() {
        let idleCodex = terminal(kind: .codex, activityState: .idle)
        let workingClaude = terminal(kind: .claude, activityState: .working)

        #expect(WorktreeRowView.hasForegroundWork(in: [idleCodex, workingClaude]))
        #expect(!WorktreeRowView.hasForegroundWork(in: [idleCodex]))
        #expect(!WorktreeRowView.hasForegroundWork(in: []))
    }
}

@Suite("WorktreeRowView — prompt on screen")
struct WorktreeRowPromptOnScreenTests {
    private func terminal(notificationType: String?) -> Terminal {
        var terminal = Terminal(
            worktreeID: UUID(),
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            kind: .claude,
            activityState: .working
        )
        terminal.awaitingInputReason = AwaitingInputReason(
            message: "Claude needs your permission to use Bash",
            hookEventName: "Notification",
            notificationType: notificationType)
        terminal.awaitingInputObservedAt = Date(timeIntervalSince1970: 1)
        return terminal
    }

    @Test(arguments: ["permission_prompt", "elicitation_dialog", "agent_needs_input"])
    func promptClassesAreRecognized(notificationType: String) {
        #expect(terminal(notificationType: notificationType).hasPromptOnScreen)
    }

    @Test func noReasonIsNoSignal() {
        let working = Terminal(
            worktreeID: UUID(),
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            kind: .claude,
            activityState: .working)

        #expect(!working.hasPromptOnScreen)
    }

    /// `.doneWaiting`, `.informational`, and `.unrecognized` are not prompts.
    /// A type this build has never heard of must NOT be guessed into the
    /// prompt class on the strength of its spelling.
    @Test(arguments: [
        "idle_prompt", "auth_success", "agent_completed", "a_brand_new_prompt_type",
    ])
    func otherClassesAreNoSignal(notificationType: String) {
        #expect(!terminal(notificationType: notificationType).hasPromptOnScreen)
    }

    @Test func absentNotificationTypeIsNoSignal() {
        #expect(!terminal(notificationType: nil).hasPromptOnScreen)
    }

    /// Parking kills the agent process, so whatever prompt was on screen went
    /// with it. `.attention` outranks `.hibernated`, so without this the calm
    /// moon would be replaced by "needs your attention" on a dead session for
    /// as long as the stale columns survived.
    @Test func aParkedTerminalIsNeverPrompting() {
        var parked = terminal(notificationType: "permission_prompt")
        #expect(parked.hasPromptOnScreen)

        parked.hibernatedAt = Date(timeIntervalSince1970: 100)

        #expect(parked.isParked)
        #expect(!parked.hasPromptOnScreen)
        #expect(!WorktreeRowView.hasPromptOnScreen(in: [parked]))
    }

    @Test func collectionReportsAnyPromptOnScreen() {
        let prompt = terminal(notificationType: "permission_prompt")
        let idlePrompt = terminal(notificationType: "idle_prompt")

        #expect(WorktreeRowView.hasPromptOnScreen(in: [idlePrompt, prompt]))
        #expect(!WorktreeRowView.hasPromptOnScreen(in: [idlePrompt]))
        #expect(!WorktreeRowView.hasPromptOnScreen(in: []))
    }
}
