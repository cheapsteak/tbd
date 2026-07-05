import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

/// Every branch of the auto-hibernate gating decision — one test per rail, per
/// CLAUDE.md's "test every branch of gating conditionals" rule. Pure: no DB,
/// no tmux, no actor.
@Suite("HibernationGate")
struct HibernationGateTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// A resumable, idle-at-rest Claude terminal — the baseline that SHOULD be
    /// eligible so each test can flip exactly one rail.
    private func claudeTerminal(
        activityState: TerminalActivityState = .idle,
        keepWarm: Bool = false,
        hibernatedAt: Date? = nil,
        suspendedAt: Date? = nil,
        sessionID: String? = "sess-1",
        kind: TerminalKind? = .claude
    ) -> Terminal {
        Terminal(
            worktreeID: UUID(), tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", claudeSessionID: sessionID,
            suspendedAt: suspendedAt, kind: kind,
            activityState: activityState, hibernatedAt: hibernatedAt, keepWarm: keepWarm
        )
    }

    private func decide(
        _ terminal: Terminal,
        enabled: Bool = true,
        timeout: TimeInterval = 30 * 60,
        idleSince: Date?
    ) -> HibernationGate.Decision {
        HibernationGate.decide(
            terminal: terminal, autoHibernateEnabled: enabled,
            idleTimeout: timeout, idleSince: idleSince, now: now
        )
    }

    // MARK: - The go path

    @Test func eligibleWhenIdlePastTimeout() {
        let t = claudeTerminal()
        // Idle since 31 minutes ago, timeout 30 min → eligible.
        let idleSince = now.addingTimeInterval(-31 * 60)
        #expect(decide(t, idleSince: idleSince) == .eligible)
    }

    // MARK: - Rail: feature disabled

    @Test func featureDisabledBlocks() {
        let t = claudeTerminal()
        let idleSince = now.addingTimeInterval(-60 * 60)
        #expect(decide(t, enabled: false, idleSince: idleSince) == .featureDisabled)
    }

    // MARK: - Rail: not a resumable Claude session

    @Test func nonClaudeBlocked() {
        let shell = claudeTerminal(sessionID: nil, kind: .shell)
        let idleSince = now.addingTimeInterval(-60 * 60)
        #expect(decide(shell, idleSince: idleSince) == .notClaudeResumable)
    }

    @Test func codexBlocked() {
        let codex = claudeTerminal(kind: .codex)
        let idleSince = now.addingTimeInterval(-60 * 60)
        #expect(decide(codex, idleSince: idleSince) == .notClaudeResumable)
    }

    // MARK: - Rail: already hibernated / suspended

    @Test func alreadyHibernatedBlocked() {
        let t = claudeTerminal(hibernatedAt: now.addingTimeInterval(-5 * 60))
        let idleSince = now.addingTimeInterval(-60 * 60)
        #expect(decide(t, idleSince: idleSince) == .alreadyHibernated)
    }

    @Test func suspendedBlocked() {
        let t = claudeTerminal(suspendedAt: now.addingTimeInterval(-5 * 60))
        let idleSince = now.addingTimeInterval(-60 * 60)
        #expect(decide(t, idleSince: idleSince) == .suspended)
    }

    // MARK: - Rail: keep-warm

    @Test func keepWarmBlocked() {
        let t = claudeTerminal(keepWarm: true)
        let idleSince = now.addingTimeInterval(-60 * 60)
        #expect(decide(t, idleSince: idleSince) == .keepWarm)
    }

    // MARK: - Rail: actively running a turn

    @Test func runningTurnBlocked() {
        let t = claudeTerminal(activityState: .working)
        let idleSince = now.addingTimeInterval(-60 * 60)
        #expect(decide(t, idleSince: idleSince) == .running)
    }

    // MARK: - Rail: waiting on a permission prompt (raised hand)

    @Test func waitingForPermissionBlocked() {
        let t = claudeTerminal(activityState: .waitingForUser)
        let idleSince = now.addingTimeInterval(-60 * 60)
        #expect(decide(t, idleSince: idleSince) == .waitingForUser)
    }

    // MARK: - Rail: idle but not long enough / no marker

    @Test func notIdleLongEnoughBlocked() {
        let t = claudeTerminal()
        // Idle only 5 minutes; timeout 30 → not yet.
        let idleSince = now.addingTimeInterval(-5 * 60)
        #expect(decide(t, idleSince: idleSince) == .notIdleLongEnough)
    }

    @Test func noIdleMarkerBlocked() {
        let t = claudeTerminal()
        #expect(decide(t, idleSince: nil) == .notIdleLongEnough)
    }

    @Test func unknownActivityCountsAsAtRest() {
        // `.unknown` (hook hasn't fired) is treated as at-rest so a genuinely
        // idle session isn't kept awake forever by a missing hook.
        let t = claudeTerminal(activityState: .unknown)
        let idleSince = now.addingTimeInterval(-31 * 60)
        #expect(decide(t, idleSince: idleSince) == .eligible)
    }

    // MARK: - Rail precedence (a louder rail wins over idle-time)

    @Test func runningWinsOverIdleTime() {
        // Both "running" and "past timeout" true → running is reported, so a
        // long-idle-then-resumed session is never killed mid-turn.
        let t = claudeTerminal(activityState: .working)
        let idleSince = now.addingTimeInterval(-60 * 60)
        #expect(decide(t, idleSince: idleSince) == .running)
    }
}
