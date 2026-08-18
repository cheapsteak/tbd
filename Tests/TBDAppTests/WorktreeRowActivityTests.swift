import Foundation
import Testing
import TBDShared
@testable import TBDApp

@Suite("WorktreeRowView — foreground activity")
struct WorktreeRowActivityTests {
    private func terminal(
        kind: TerminalKind,
        activityState: TerminalActivityState,
        presentationActivityState: TerminalActivityState? = nil
    ) -> Terminal {
        Terminal(
            worktreeID: UUID(),
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            kind: kind,
            activityState: activityState,
            presentationActivityState: presentationActivityState
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

    @Test func codexUsesTranscriptWorkingActivity() {
        let codex = terminal(
            kind: .codex,
            activityState: .idle,
            presentationActivityState: .working
        )

        #expect(WorktreeRowView.isForegroundWorking(codex))
    }

    @Test func codexTranscriptIdleOverridesStaleRawWorkingActivity() {
        let codex = terminal(
            kind: .codex,
            activityState: .working,
            presentationActivityState: .idle
        )

        #expect(!WorktreeRowView.isForegroundWorking(codex))
    }

    @Test func codexWithoutTranscriptEvidencePrefersFalseIdle() {
        let codex = terminal(
            kind: .codex,
            activityState: .working,
            presentationActivityState: nil
        )

        #expect(!WorktreeRowView.isForegroundWorking(codex))
    }

    @Test func terminalCollectionReportsAnyTruthfulForegroundWork() {
        let staleCodex = terminal(
            kind: .codex,
            activityState: .working,
            presentationActivityState: .idle
        )
        let workingClaude = terminal(kind: .claude, activityState: .working)

        #expect(WorktreeRowView.hasForegroundWork(in: [staleCodex, workingClaude]))
        #expect(!WorktreeRowView.hasForegroundWork(in: [staleCodex]))
        #expect(!WorktreeRowView.hasForegroundWork(in: []))
    }
}
