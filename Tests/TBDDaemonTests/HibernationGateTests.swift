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

    // MARK: - Auto-hibernation derives from the master switch on every transport

    /// A holder-backed row that passes every other rail. Only `transport`
    /// differs from the baseline above, so the tests below are about the
    /// transport and nothing else.
    private func holderTerminal() -> Terminal {
        Terminal(
            worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            label: "claude", claudeSessionID: "sess-1", kind: .claude,
            activityState: .idle, transport: .holder)
    }

    /// The ON branch of the derived condition. Holder-ness is a transport
    /// property, not a separate opt-in: with `auto_hibernate_enabled` on, an
    /// idle holder row is as eligible as an idle tmux one.
    @Test func holderRowIsEligibleWhenAutoHibernateIsOn() {
        let idleSince = now.addingTimeInterval(-31 * 60)
        #expect(HibernationGate.decide(
            terminal: holderTerminal(), autoHibernateEnabled: true,
            idleTimeout: 30 * 60,
            idleSince: idleSince, now: now) == .eligible)
    }

    /// The OFF branch, and it reports the master switch by name — `.featureDisabled`,
    /// exactly what a tmux row gets — rather than anything transport-shaped.
    @Test func holderRowIsRefusedWhenAutoHibernateIsOff() {
        let idleSince = now.addingTimeInterval(-31 * 60)
        #expect(HibernationGate.decide(
            terminal: holderTerminal(), autoHibernateEnabled: false,
            idleTimeout: 30 * 60,
            idleSince: idleSince, now: now) == .featureDisabled)
        // …and the same answer a tmux row gets, so the two transports are not
        // merely both refused but refused for the same stated reason.
        #expect(HibernationGate.decide(
            terminal: claudeTerminal(), autoHibernateEnabled: false,
            idleTimeout: 30 * 60,
            idleSince: idleSince, now: now) == .featureDisabled)
    }

    /// Manual park needs no flag at all, on either transport — the user asked.
    @Test func manualParkIsPermittedOnBothTransportsRegardlessOfTheAutoFlag() {
        #expect(holderTerminal().isManuallyHibernatable())
        #expect(claudeTerminal().isManuallyHibernatable())
        // The hard rails still apply on both.
        var busyHolder = holderTerminal()
        busyHolder.activityState = .working
        #expect(!busyHolder.isManuallyHibernatable())
    }

    // MARK: - Parity with the predicate the app reads

    /// `blockingRail` and `Terminal.isManuallyHibernatable` are two cascades
    /// over the same rails, and this is what stops them drifting.
    ///
    /// They are duplicated on purpose — the gate needs a per-rail *reason* and
    /// the model needs a yes or no — but nothing in the compiler notices when
    /// one grows a rail the other has not got, and the two are read by
    /// different halves of the product: the daemon refuses a park by the first
    /// and the app decides whether to offer one by the second. A row they
    /// disagree about is a menu item that fails when the user clicks it, or a
    /// park the daemon performs that the app said was impossible.
    ///
    /// The equivalences, and why they are what they are:
    ///
    /// - `blockingRail == nil` ⇔ `isAutoHibernationEligible`. Both are "every
    ///   hard rail passes, keep-warm included".
    /// - `blockingRail(the same row with keep-warm cleared) == nil` ⇔
    ///   `isManuallyHibernatable`. A manual park overrides keep-warm and
    ///   nothing else, so the honest way to say that is to ask the cascade the
    ///   question with keep-warm taken out of it.
    ///
    /// **Not** `rail == nil || rail == .keepWarm`, which is the obvious
    /// spelling and is wrong: `blockingRail` returns the most specific blocker
    /// in ITS order, and keep-warm sits ahead of the activity rails — so a
    /// keep-warm row that is mid-turn answers `.keepWarm`, and forgiving that
    /// answer would read as "only keep-warm blocks this" while
    /// `isManuallyHibernatable` correctly refuses it for running a turn. This
    /// test was written with that spelling and found the twelve rows where it
    /// disagrees, which is the whole argument for having it. Nothing in
    /// production computes manual eligibility from `blockingRail` — the manual
    /// path calls the predicate directly — so those rows were a defect in the
    /// assertion rather than in the daemon.
    ///
    /// The structural fix — `isManuallyHibernatable` becoming
    /// `blockingRail(...) == nil`, with the reason-bearing cascade moved into
    /// `TBDShared` — is better than this test and larger than this change; it
    /// is a follow-up. Until then this matrix is the ratchet.
    @Test func blockingRailAgreesWithTheModelPredicateOverEveryRow() {
        var rows = 0
        var passedEveryRail = 0
        for transport in [TerminalTransport.tmux, .holder] {
            for sessionID in [String?.none, "sess-1"] {
                for kind in [TerminalKind?.none, .claude, .codex, .shell] {
                    for hibernatedAt in [Date?.none, now] {
                        for suspendedAt in [Date?.none, now] {
                            for keepWarm in [false, true] {
                                for activity in [TerminalActivityState.idle, .unknown,
                                                 .working, .waitingForUser] {
                                    let terminal = Terminal(
                                        worktreeID: UUID(),
                                        tmuxWindowID: transport == .holder ? "" : "@0",
                                        tmuxPaneID: transport == .holder ? "" : "%0",
                                        label: "claude", claudeSessionID: sessionID,
                                        suspendedAt: suspendedAt, kind: kind,
                                        activityState: activity, hibernatedAt: hibernatedAt,
                                        keepWarm: keepWarm, transport: transport)
                                    let rail = HibernationGate.blockingRail(
                                        terminal: terminal)
                                    var withoutKeepWarm = terminal
                                    withoutKeepWarm.keepWarm = false
                                    let railIgnoringKeepWarm = HibernationGate.blockingRail(
                                        terminal: withoutKeepWarm)
                                    let auto = terminal.isAutoHibernationEligible()
                                    let manual = terminal.isManuallyHibernatable()
                                    #expect((rail == nil) == auto,
                                            "blockingRail said \(String(describing: rail)) while isAutoHibernationEligible said \(auto) for \(transport) session=\(String(describing: sessionID)) kind=\(String(describing: kind)) hibernated=\(hibernatedAt != nil) suspended=\(suspendedAt != nil) keepWarm=\(keepWarm) activity=\(activity)")
                                    #expect((railIgnoringKeepWarm == nil) == manual,
                                            "blockingRail with keep-warm cleared said \(String(describing: railIgnoringKeepWarm)) while isManuallyHibernatable said \(manual) for \(transport) session=\(String(describing: sessionID)) kind=\(String(describing: kind)) hibernated=\(hibernatedAt != nil) suspended=\(suspendedAt != nil) keepWarm=\(keepWarm) activity=\(activity)")
                                    rows += 1
                                    if rail == nil { passedEveryRail += 1 }
                                }
                            }
                        }
                    }
                }
            }
        }
        // The matrix has to have actually run, and it has to contain both
        // answers: a loop that produced only blocked rows would agree with any
        // predicate that refuses everything.
        #expect(rows == 2 * 2 * 4 * 2 * 2 * 2 * 4)
        #expect(passedEveryRail > 0,
                "no row in the matrix passed every rail, so the parity above agrees with any predicate that refuses everything")
        #expect(passedEveryRail < rows,
                "every row in the matrix passed every rail, so the parity above agrees with any predicate that allows everything")
    }

    /// The rails read the row, never the transport: the same facts produce the
    /// same decision on tmux and on holder. An implementation that special-cased
    /// either transport would fail one half of this.
    @Test func bothTransportsGetTheSameDecisionFromTheSameFacts() {
        let idleSince = now.addingTimeInterval(-31 * 60)
        var busyHolder = holderTerminal()
        busyHolder.activityState = .working
        #expect(HibernationGate.decide(
            terminal: claudeTerminal(), autoHibernateEnabled: true,
            idleTimeout: 30 * 60, idleSince: idleSince, now: now) == .eligible)
        #expect(HibernationGate.decide(
            terminal: holderTerminal(), autoHibernateEnabled: true,
            idleTimeout: 30 * 60, idleSince: idleSince, now: now) == .eligible)
        #expect(HibernationGate.decide(
            terminal: claudeTerminal(activityState: .working),
            autoHibernateEnabled: true,
            idleTimeout: 30 * 60, idleSince: idleSince, now: now) == .running)
        #expect(HibernationGate.decide(
            terminal: busyHolder, autoHibernateEnabled: true,
            idleTimeout: 30 * 60, idleSince: idleSince, now: now) == .running)
    }
}
