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
        inputVetoEnabled: Bool = false,
        timeout: TimeInterval = 30 * 60,
        idleSince: Date?,
        lastInputAt: Date? = nil
    ) -> HibernationGate.Decision {
        HibernationGate.decide(
            terminal: terminal, autoHibernateEnabled: enabled,
            inputVetoEnabled: inputVetoEnabled,
            idleTimeout: timeout, idleSince: idleSince, lastInputAt: lastInputAt, now: now
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

    // MARK: - Rail: pending typed input (input veto)

    @Test func pendingTypedInputBlocksWhenVetoEnabled() {
        // Input veto on + lastInputAt >= idleSince + idle long enough →
        // `.pendingTypedInput`. This is the headline guarantee: pending typed
        // input is never eaten by the park.
        let t = claudeTerminal()
        let idleSince = now.addingTimeInterval(-31 * 60)
        let lastInputAt = now.addingTimeInterval(-10 * 60) // input 10m after idle
        #expect(decide(t, inputVetoEnabled: true, idleSince: idleSince, lastInputAt: lastInputAt) == .pendingTypedInput)
    }

    @Test func vetoDisabledProvesFlagIsGated() {
        // Flag OFF + same inputs (input after idle, idle long enough) →
        // `.eligible`. Proves the veto is truly gated; regression-guards
        // today's behavior (scrape-only guard).
        let t = claudeTerminal()
        let idleSince = now.addingTimeInterval(-31 * 60)
        let lastInputAt = now.addingTimeInterval(-10 * 60) // input 10m after idle
        #expect(decide(t, inputVetoEnabled: false, idleSince: idleSince, lastInputAt: lastInputAt) == .eligible)
    }

    @Test func inputBeforeIdleIsEligible() {
        // Input veto on + lastInputAt < idleSince (input consumed by last turn) →
        // `.eligible`. The session DID see the input (it was processed in a turn),
        // so it's safe to park.
        let t = claudeTerminal()
        let idleSince = now.addingTimeInterval(-30 * 60)
        let lastInputAt = now.addingTimeInterval(-35 * 60) // input 35m ago, before idle
        #expect(decide(t, inputVetoEnabled: true, idleSince: idleSince, lastInputAt: lastInputAt) == .eligible)
    }

    @Test func noRecordedInputIsEligible() {
        // Input veto on + lastInputAt == nil (no input recorded, e.g. post-restart,
        // or a pane never typed into) → `.eligible` from the gate. The scrape veto
        // in performHibernate covers this branch.
        let t = claudeTerminal()
        let idleSince = now.addingTimeInterval(-31 * 60)
        #expect(decide(t, inputVetoEnabled: true, idleSince: idleSince, lastInputAt: nil) == .eligible)
    }

    @Test func inputVetoLosesToRunning() {
        // Precedence: `.running` wins over the input veto. A session that
        // received input AND is actively running is reported as running, not
        // pending-input.
        let t = claudeTerminal(activityState: .working)
        let idleSince = now.addingTimeInterval(-31 * 60)
        let lastInputAt = now.addingTimeInterval(-10 * 60) // input after idle
        #expect(decide(t, inputVetoEnabled: true, idleSince: idleSince, lastInputAt: lastInputAt) == .running)
    }

    @Test func inputVetoLosesToWaitingForUser() {
        // Precedence: `.waitingForUser` wins over the input veto.
        let t = claudeTerminal(activityState: .waitingForUser)
        let idleSince = now.addingTimeInterval(-31 * 60)
        let lastInputAt = now.addingTimeInterval(-10 * 60) // input after idle
        #expect(decide(t, inputVetoEnabled: true, idleSince: idleSince, lastInputAt: lastInputAt) == .waitingForUser)
    }

    @Test func inputVetoLosesToNotIdleLongEnough() {
        // Precedence: `.notIdleLongEnough` wins over the input veto — the
        // timeout check comes before the input check.
        let t = claudeTerminal()
        let idleSince = now.addingTimeInterval(-5 * 60) // only 5m idle, not 30m
        let lastInputAt = now.addingTimeInterval(-2 * 60) // input 2m after idle
        #expect(decide(t, inputVetoEnabled: true, idleSince: idleSince, lastInputAt: lastInputAt) == .notIdleLongEnough)
    }

    @Test func inputAtExactIdleTimestampIsBlocked() {
        // Edge case: input at exactly idleSince → input >= idleSince is true →
        // blocked. Conservative: the comparison is >=, so input at the idle moment
        // is treated as "after idle".
        let t = claudeTerminal()
        let idleSince = now.addingTimeInterval(-31 * 60)
        let lastInputAt = idleSince // input exactly when idle was marked
        #expect(decide(t, inputVetoEnabled: true, idleSince: idleSince, lastInputAt: lastInputAt) == .pendingTypedInput)
    }

    @Test func tuiBreakSimulation() {
        // Headline guarantee (fail-safe test): a simulated Claude Code composer
        // redesign where the scraper is blind (would return false for pending input)
        // cannot eat typed-but-unsent input because the input veto catches it at
        // the gate level. This terminal received input AFTER going idle, and while
        // the gate passes only the decision (the scrape logic is separate), the
        // input veto alone suffices to block the park.
        let t = claudeTerminal()
        let idleSince = now.addingTimeInterval(-31 * 60)
        let lastInputAt = now.addingTimeInterval(-5 * 60) // typed something 5m after idle
        let decision = decide(t, inputVetoEnabled: true, idleSince: idleSince, lastInputAt: lastInputAt)
        #expect(decision == .pendingTypedInput)
        // The gate alone blocks, so even if the scrape is broken the park is safe.
    }
}
