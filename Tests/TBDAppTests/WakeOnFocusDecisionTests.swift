import Foundation
import Testing
import TBDShared
@testable import TBDApp

/// The spawn-storm fix: on focus, wake EXACTLY ONE parked terminal, never fan
/// out to all N (which queued respawns past the 300s ceiling and hung the
/// daemon). Tests the pure decision `terminalIDToWakeOnFocus` across its three
/// branches without needing a live `DaemonClient`.
@MainActor
@Suite("Wake-on-focus decision (spawn-storm fix)")
struct WakeOnFocusDecisionTests {
    private func terminal(_ id: UUID, parked: Bool) -> Terminal {
        Terminal(id: id, worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
                 claudeSessionID: UUID().uuidString,
                 hibernatedAt: parked ? Date() : nil)
    }

    private func parkedTerminal(_ id: UUID, reason: HibernateReason?) -> Terminal {
        Terminal(id: id, worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
                 claudeSessionID: UUID().uuidString,
                 hibernatedAt: Date(), hibernateReason: reason)
    }

    /// Focus `terminalID`'s tab in `wt` so `terminalIDForAutofocus` resolves it.
    private func focus(_ state: AppState, worktreeID wt: UUID, terminalID: UUID) {
        state.tabs[wt] = [Tab(id: UUID(), content: .terminal(terminalID: terminalID), label: nil)]
        state.activeTabIndices[wt] = 0
    }

    /// Branch 1: the focused terminal is itself parked → wake exactly it (not
    /// merely the first parked row).
    @Test func wakesTheFocusedParkedTerminal() {
        let state = AppState()
        let wt = UUID()
        let other = UUID()
        let focused = UUID()
        // `focused` is SECOND so a naive "first parked" would wrongly pick `other`.
        state.terminals[wt] = [terminal(other, parked: true), terminal(focused, parked: true)]
        let tabID = UUID()
        state.tabs[wt] = [Tab(id: tabID, content: .terminal(terminalID: focused), label: nil)]
        state.activeTabIndices[wt] = 0

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == focused)
    }

    /// Branch 2: no resolvable focused terminal (history view active) → fall back
    /// to the FIRST parked terminal — one, not a fan-out.
    @Test func fallsBackToFirstParkedWhenNoFocusResolvable() {
        let state = AppState()
        let wt = UUID()
        let firstParked = UUID()
        let secondParked = UUID()
        state.terminals[wt] = [terminal(firstParked, parked: true), terminal(secondParked, parked: true)]
        let tabID = UUID()
        state.tabs[wt] = [Tab(id: tabID, content: .terminal(terminalID: firstParked), label: nil)]
        // History view active → terminalIDForAutofocus returns nil.
        state.historyActiveWorktrees.insert(wt)

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == firstParked)
    }

    /// Branch 3: nothing parked → nil (nothing to wake).
    @Test func returnsNilWhenNoParkedTerminals() {
        let state = AppState()
        let wt = UUID()
        state.terminals[wt] = [terminal(UUID(), parked: false), terminal(UUID(), parked: false)]

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == nil)
    }

    // MARK: - Manual-park exclusion (hibernateReason)
    //
    // An explicit "Hibernate now" (`hibernateReason == .manual`) must NOT be
    // silently undone by navigating back to the worktree: focus-wake skips it
    // at BOTH decision points (the focused-terminal match and the `.first`
    // fallback). Auto, recovery, and legacy nil-reason parks keep the old
    // behavior and still wake on focus.

    /// A manually-parked session is skipped even when it is the FOCUSED
    /// terminal — and with nothing else parked, nothing is woken at all.
    @Test func skipsManuallyParkedTerminalEvenWhenFocused() {
        let state = AppState()
        let wt = UUID()
        let manual = UUID()
        state.terminals[wt] = [parkedTerminal(manual, reason: .manual)]
        focus(state, worktreeID: wt, terminalID: manual)

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == nil)
    }

    /// An auto-parked (idle-sweep) session still wakes on focus.
    @Test func wakesAutoParkedTerminalOnFocus() {
        let state = AppState()
        let wt = UUID()
        let auto = UUID()
        state.terminals[wt] = [parkedTerminal(auto, reason: .auto)]
        focus(state, worktreeID: wt, terminalID: auto)

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == auto)
    }

    /// A recovery-parked (crash-recovery reconcile) session still wakes on focus.
    @Test func wakesRecoveryParkedTerminalOnFocus() {
        let state = AppState()
        let wt = UUID()
        let recovery = UUID()
        state.terminals[wt] = [parkedTerminal(recovery, reason: .recovery)]
        focus(state, worktreeID: wt, terminalID: recovery)

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == recovery)
    }

    /// A merge-parked session (`hibernateReason == .merged`) still wakes on
    /// focus: auto-hibernate-on-merge is system-initiated, not an explicit
    /// user "Hibernate now", so navigating back to the worktree wakes it —
    /// unlike a `.manual` park. Pins the design decision.
    @Test func wakesMergedReasonParkedTerminalOnFocus() {
        let state = AppState()
        let wt = UUID()
        let merged = UUID()
        state.terminals[wt] = [parkedTerminal(merged, reason: .merged)]
        focus(state, worktreeID: wt, terminalID: merged)

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == merged)
    }

    /// A legacy parked row with NO reason (pre-v46) still wakes on focus —
    /// the old behavior is preserved for rows the migration can't attribute.
    @Test func wakesLegacyNilReasonParkedTerminalOnFocus() {
        let state = AppState()
        let wt = UUID()
        let legacy = UUID()
        state.terminals[wt] = [parkedTerminal(legacy, reason: nil)]
        focus(state, worktreeID: wt, terminalID: legacy)

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == legacy)
    }

    /// Mixed worktree: a manual park and an auto park coexist. The manual one
    /// is FIRST in the list (a naive `.first` fallback would pick it) and also
    /// FOCUSED (a naive focused-match would pick it) — the auto one must be
    /// chosen anyway, proving the exclusion applies at both decision points.
    @Test func mixedManualAndAutoParkedChoosesTheAutoOne() {
        let state = AppState()
        let wt = UUID()
        let manual = UUID()
        let auto = UUID()
        state.terminals[wt] = [
            parkedTerminal(manual, reason: .manual),
            parkedTerminal(auto, reason: .auto),
        ]
        focus(state, worktreeID: wt, terminalID: manual)

        #expect(state.terminalIDToWakeOnFocus(worktreeID: wt) == auto)
    }

    // MARK: - Wake-failure alert coalescing (modal-spam fix)
    //
    // After a reboot kills every tmux server, each wake failure used to fire
    // its own modal — alert spam. `wakeTerminal` no longer alerts at all; it
    // RETURNS the failure message. The automatic focus path ignores it
    // (silent — its "no alert" branch is structural), and the explicit Wake
    // menu action folds its batch of failures through this pure function
    // into at most ONE modal per user action. All three branches covered.

    /// No failures → nil → no alert shown.
    @Test func noWakeFailuresProducesNoAlert() {
        #expect(AppState.coalescedWakeFailureMessage(failures: []) == nil)
    }

    /// A single failure → the bare message, no count prefix.
    @Test func singleWakeFailureShowsBareMessage() {
        #expect(AppState.coalescedWakeFailureMessage(failures: ["tmux window @1 is gone"])
                == "Couldn't wake session: tmux window @1 is gone")
    }

    /// Multiple failures → ONE message carrying the count and the first
    /// failure — never one modal per terminal.
    @Test func multipleWakeFailuresCoalesceIntoOneMessage() {
        let message = AppState.coalescedWakeFailureMessage(
            failures: ["window @1 gone", "window @2 gone", "window @3 gone"]
        )
        #expect(message == "Couldn't wake 3 sessions: window @1 gone")
    }

    // MARK: - Wake-all batching (bounded concurrency)
    //
    // The explicit "Wake all parked" menu action uses bounded-concurrency
    // batches (at most wakeAllBatchSize in flight at once) to prevent the #367
    // spawn storm. The focus path stays one-per-focus (see
    // `terminalIDToWakeOnFocus` — covered by existing tests). Tests verify the
    // batching pure function's branches and the batch-size constant.

    /// Empty input → empty batches.
    @Test func wakeAllBatchesEmptyIsEmpty() {
        let result = AppState.wakeAllBatches([])
        #expect(result == [])
    }

    /// Input smaller than batch size → single batch containing all ids.
    @Test func wakeAllBatchesUnderSizeIsSingleBatch() {
        let ids = [UUID(), UUID()]
        let result = AppState.wakeAllBatches(ids)
        #expect(result.count == 1)
        #expect(result[0] == ids)
    }

    /// Input exactly a multiple of batch size → exact batches with no remainder.
    @Test func wakeAllBatchesExactMultiple() {
        let ids = (0..<6).map { _ in UUID() }
        let result = AppState.wakeAllBatches(ids, batchSize: 3)
        #expect(result.count == 2)
        #expect(result[0].count == 3)
        #expect(result[1].count == 3)
    }

    /// Input with remainder → last batch smaller than batch size.
    @Test func wakeAllBatchesWithRemainder() {
        let ids = (0..<7).map { _ in UUID() }
        let result = AppState.wakeAllBatches(ids, batchSize: 3)
        #expect(result.count == 3)
        #expect(result[0].count == 3)
        #expect(result[1].count == 3)
        #expect(result[2].count == 1)
        // Verify order is preserved (flattened = original).
        let flattened = result.flatMap { $0 }
        #expect(flattened == ids)
    }

    /// Verify the constant batch size and default argument behavior.
    @Test func wakeAllBatchesDefaultSizeIsThree() {
        #expect(AppState.wakeAllBatchSize == 3)
        let ids = (0..<4).map { _ in UUID() }
        let result = AppState.wakeAllBatches(ids)
        #expect(result.count == 2)
        #expect(result[0].count == 3)
        #expect(result[1].count == 1)
    }

    /// The focus path default stays one-per-focus. `terminalIDToWakeOnFocus`
    /// returns exactly one terminal (from existing tests). Pin that the bounded
    /// method is ONLY for the explicit user action, not the background focus path.
    @Test func focusPathStaysOneAtATime() {
        let state = AppState()
        let wt = UUID()
        let ids = (0..<5).map { _ in UUID() }
        state.terminals[wt] = ids.map { id in
            Terminal(id: id, worktreeID: wt, tmuxWindowID: "@1", tmuxPaneID: "%1",
                     claudeSessionID: UUID().uuidString,
                     hibernatedAt: Date())
        }
        // Focus the first parked terminal.
        state.tabs[wt] = [Tab(id: UUID(), content: .terminal(terminalID: ids[0]), label: nil)]
        state.activeTabIndices[wt] = 0

        // terminalIDToWakeOnFocus returns exactly one, never a batch.
        let focused = state.terminalIDToWakeOnFocus(worktreeID: wt)
        #expect(focused == ids[0],
                "focus wake must return exactly one terminal, not a batch")
    }

    // MARK: - Wake outcome classification (fallback-offer logic)
    //
    // When an explicit wake fails with profileMissing, the app offers a
    // default-account fallback retry. The classifier detects the code and
    // structured outcome, avoiding loops (a fallback retry that also fails
    // with the same code becomes `.failed`, never `.profileMissing` again).
    // All branches tested.

    /// Profile-missing code on first attempt → structured `.profileMissing`
    /// outcome so the app can offer a retry.
    @Test func wakeOutcomeProfileMissingCodeNotFallback() {
        let tid = UUID()
        let wid = UUID()
        let msg = "Profile gone"
        let outcome = AppState.wakeOutcome(
            forErrorCode: RPCErrorCode.profileMissing.rawValue,
            alreadyFallback: false,
            terminalID: tid, worktreeID: wid, message: msg)
        #expect(outcome == .profileMissing(terminalID: tid, worktreeID: wid, message: msg))
    }

    /// Profile-missing code but `alreadyFallback: true` → `.failed`, not
    /// `.profileMissing` again. Prevents the offer loop.
    @Test func wakeOutcomeProfileMissingCodeDuringFallbackIsFailed() {
        let tid = UUID()
        let wid = UUID()
        let msg = "Still missing"
        let outcome = AppState.wakeOutcome(
            forErrorCode: RPCErrorCode.profileMissing.rawValue,
            alreadyFallback: true,
            terminalID: tid, worktreeID: wid, message: msg)
        #expect(outcome == .failed(message: msg))
    }

    /// Different error code → `.failed`.
    @Test func wakeOutcomeOtherCodeIsFailed() {
        let tid = UUID()
        let wid = UUID()
        let msg = "Some other error"
        let outcome = AppState.wakeOutcome(
            forErrorCode: "someOtherCode",
            alreadyFallback: false,
            terminalID: tid, worktreeID: wid, message: msg)
        #expect(outcome == .failed(message: msg))
    }

    /// Nil code → `.failed`.
    @Test func wakeOutcomeNilCodeIsFailed() {
        let tid = UUID()
        let wid = UUID()
        let msg = "Unknown error"
        let outcome = AppState.wakeOutcome(
            forErrorCode: nil,
            alreadyFallback: false,
            terminalID: tid, worktreeID: wid, message: msg)
        #expect(outcome == .failed(message: msg))
    }

    // MARK: - Default-account fallback prompt copy
    //
    // The confirmation dialog copy is pure and testable so the wording is
    // pinned and can be audited.

    /// Singular case: one session.
    @Test func defaultAccountFallbackPromptSingular() {
        let (message, informative, confirm) = AppState.defaultAccountFallbackPrompt(count: 1)
        #expect(message == "Wake this session on your default account?")
        #expect(informative.contains("This session was"))
        #expect(informative.contains("pinned to an account profile"))
        #expect(confirm == "Wake on Default Account")
    }

    /// Plural case: multiple sessions.
    @Test func defaultAccountFallbackPromptPlural() {
        let (message, informative, confirm) = AppState.defaultAccountFallbackPrompt(count: 3)
        #expect(message == "Wake 3 sessions on your default account?")
        #expect(informative.contains("3 sessions were"))
        #expect(informative.contains("pinned to an account profile"))
        #expect(confirm == "Wake 3 on Default Account")
    }

    // MARK: - Wake outcome accessors
    //
    // Computed properties on `.WakeAttemptOutcome` extract fields for coalescing
    // failures and detecting profile-missing terminals. All branches tested.

    /// `.ok` outcome: all accessors return nil.
    @Test func wakeOutcomeAccessorsOkIsNil() {
        let outcome = AppState.WakeAttemptOutcome.ok
        #expect(outcome.failureMessage == nil)
        #expect(outcome.anyFailureMessage == nil)
        #expect(outcome.profileMissingTerminalID == nil)
        #expect(outcome.profileMissingMessage == nil)
    }

    /// `.failed` outcome: `failureMessage` and `anyFailureMessage` carry the
    /// message; profile accessors return nil.
    @Test func wakeOutcomeAccessorsFailed() {
        let msg = "Wake failed"
        let outcome = AppState.WakeAttemptOutcome.failed(message: msg)
        #expect(outcome.failureMessage == msg)
        #expect(outcome.anyFailureMessage == msg)
        #expect(outcome.profileMissingTerminalID == nil)
        #expect(outcome.profileMissingMessage == nil)
    }

    /// `.profileMissing` outcome: all accessors return their fields.
    @Test func wakeOutcomeAccessorsProfileMissing() {
        let tid = UUID()
        let wid = UUID()
        let msg = "Profile gone"
        let outcome = AppState.WakeAttemptOutcome.profileMissing(
            terminalID: tid, worktreeID: wid, message: msg)
        #expect(outcome.failureMessage == nil,
                "`failureMessage` is nil for `.profileMissing` (only `.failed` carries it)")
        #expect(outcome.anyFailureMessage == msg,
                "`anyFailureMessage` captures both `.failed` and `.profileMissing`")
        #expect(outcome.profileMissingTerminalID == tid)
        #expect(outcome.profileMissingMessage == msg)
    }
}
