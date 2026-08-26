import Foundation
import os
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

struct FakeTmuxSendError: Error {}

/// Records every tmux call; scriptable pane state.
final class FakeResumeTmux: ResumeSendingTmux, @unchecked Sendable {
    private let queue = DispatchQueue(label: "FakeResumeTmux")
    var windowAlive = true
    var inMode = false
    /// When non-empty, `paneInMode` pops values off the front (in call
    /// order) before falling back to `inMode` — scripts a value that
    /// changes between an actuation's eligibility passes (e.g. attempt 1
    /// vs. attempt 2's re-check).
    var inModeSequence: [Bool] = []
    var panePIDValue = "4242"
    /// 1-indexed count of `sendKey(key: "Escape")` calls (i.e. actuation
    /// attempts) on which the send should throw instead of recording.
    var throwOnEscapeAttempts: Set<Int> = []
    private var _sends: [String] = []
    private var _escapeCount = 0
    var sends: [String] { queue.sync { _sends } }

    func windowExists(server: String, windowID: String) async -> Bool { windowAlive }
    func paneInMode(server: String, paneID: String) async throws -> Bool {
        queue.sync {
            if !inModeSequence.isEmpty { return inModeSequence.removeFirst() }
            return inMode
        }
    }
    func panePID(server: String, paneID: String) async throws -> String { panePIDValue }
    /// What the pane answers when the actuator asks who it is. Defaults to
    /// "alive, carrying no identity" — the branch that proceeds — so every
    /// pre-existing test behaves exactly as it did before the actuator started
    /// consulting its target.
    var paneTarget: PaneSendTarget = .live(terminalID: nil)
    /// When set, the consultation itself fails to run (wedged tmux).
    var paneTargetError: Error?
    func paneSendTarget(server: String, paneID: String) async throws -> PaneSendTarget {
        if let paneTargetError { throw paneTargetError }
        return paneTarget
    }
    func sendKeys(server: String, paneID: String, text: String) async throws {
        queue.sync { _sends.append("text:\(text)") }
    }
    func sendKey(server: String, paneID: String, key: String) async throws {
        if key == "Escape" {
            let attempt = queue.sync { _escapeCount += 1; return _escapeCount }
            if throwOnEscapeAttempts.contains(attempt) {
                throw FakeTmuxSendError()
            }
        }
        queue.sync { _sends.append("key:\(key)") }
    }
}

struct FakeInspector: PaneProcessInspecting {
    var claudePID: Int32?
    func foregroundClaudePID(panePID: Int32) -> Int32? { claudePID }
}

@Suite struct LimitResumeActuatorTests {
    let db: TBDDatabase
    let tmux = FakeResumeTmux()
    let terminalID: UUID
    let worktreeID: UUID
    let row: ScheduledResume

    init() async throws {
        db = try TBDDatabase(inMemory: true)
        // Production only ever calls `actuate` after `fire()`'s own gate
        // check passed, so the actuator's own re-check (checkEligibility
        // step 0a) needs the toggle on by default here too — tests that
        // exercise the toggle-off-mid-flight path flip it explicitly.
        try await db.config.setAutoResumeOnLimitReset(true)
        let repo = try await db.repos.create(
            path: "/tmp/act-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/act-wt-\(UUID().uuidString)", tmuxServer: "tbd-act")
        worktreeID = wt.id
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1")
        terminalID = terminal.id
        try await db.terminals.updateSession(
            id: terminal.id, sessionID: "sess", transcriptPath: "/tmp/act-transcript.jsonl")
        row = ScheduledResume(
            terminalID: terminal.id, worktreeID: wt.id, claudeSessionID: "sess",
            resetsAt: Date().addingTimeInterval(-120), fireAt: Date().addingTimeInterval(-60),
            limitType: "session", rawMessage: "m", createdAt: Date().addingTimeInterval(-3600))
        // Persist `row` as the terminal's pending row so checkEligibility's
        // "row still pending" re-check (step 1b) finds it — production only
        // ever actuates rows that came from `scheduler.schedule()`, which
        // always inserts first.
        _ = try await db.scheduledResumes.insertPending(row)
    }

    private func makeActuator(
        inspector: FakeInspector = FakeInspector(claudePID: 4242),
        transcript: Data? = Data("{}\n".utf8),
        transcriptMtime: Date? = nil
    ) -> LimitResumeActuator {
        LimitResumeActuator(
            db: db, tmux: tmux, inspector: inspector,
            readTranscript: { _ in transcript },
            transcriptModifiedAt: { _ in transcriptMtime },
            waiter: { _ in }, actuationLog: makeTestActuationLog())   // no real sleeping in unit tests
    }

    @Test func missingTerminalIsTerminalGone() async throws {
        let orphan = ScheduledResume(
            terminalID: UUID(), worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: row.resetsAt, fireAt: row.fireAt,
            limitType: "session", rawMessage: "m")
        let outcome = await makeActuator().actuate(orphan)
        #expect(outcome == .terminalGone)
        #expect(tmux.sends.isEmpty)
    }

    @Test func suspendedTerminalIsTerminalGone() async throws {
        try await db.terminals.setSuspended(id: terminalID, sessionID: "sess", snapshot: nil)
        let outcome = await makeActuator().actuate(row)
        #expect(outcome == .terminalGone)
        #expect(tmux.sends.isEmpty)
    }

    /// Reconciliation guard: under the unified park model a limit-parked
    /// session is HIBERNATED (authoritative `hibernatedAt`), its pane
    /// respawned to a bare shell. The actuator must never fire the
    /// Escape/continue/Enter sequence into a parked pane — it classifies
    /// `isParked` as `.terminalGone` (send nothing), the fire-time backstop
    /// for a park that raced the scheduler.
    @Test func hibernatedTerminalIsTerminalGone() async throws {
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess", snapshot: nil)
        let outcome = await makeActuator().actuate(row)
        #expect(outcome == .terminalGone)
        #expect(tmux.sends.isEmpty)
    }

    @Test func deadWindowIsTerminalGone() async throws {
        tmux.windowAlive = false
        let outcome = await makeActuator().actuate(row)
        #expect(outcome == .terminalGone)
    }

    // MARK: - Pane target consultation (eligibility step 1a)
    //
    // The auto-resume actuator is the component issue #384 caught typing into
    // a stranger: `windowExists` proves a window id resolves, never that the
    // pane still belongs to this terminal. Same rule as `terminal.send` —
    // only a POSITIVE disagreement refuses.

    @Test func paneOwnedByAnotherTerminalTypesNothing() async throws {
        tmux.paneTarget = .live(terminalID: UUID().uuidString)
        let outcome = await makeActuator().actuate(row)
        guard case .failed(let message) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(message.contains(terminalID.uuidString))
        #expect(message.contains("%1"))
        #expect(tmux.sends.isEmpty)
    }

    @Test func paneWithNoIdentityStillGetsTheResume() async throws {
        // The no-regression branch: absence is not disagreement.
        tmux.paneTarget = .live(terminalID: nil)
        try await db.terminals.setActivityState(id: terminalID, activityState: .working, source: .derived)
        let outcome = await makeActuator().actuate(row)
        #expect(outcome == .sent)
        #expect(tmux.sends == ["key:Escape", "text:continue", "key:Enter"])
    }

    @Test func paneIdentityMatchIsCaseInsensitiveAndSends() async throws {
        tmux.paneTarget = .live(terminalID: terminalID.uuidString.lowercased())
        try await db.terminals.setActivityState(id: terminalID, activityState: .working, source: .derived)
        let outcome = await makeActuator().actuate(row)
        #expect(outcome == .sent)
        #expect(tmux.sends == ["key:Escape", "text:continue", "key:Enter"])
    }

    @Test func vanishedPaneIsTerminalGone() async throws {
        tmux.paneTarget = .absent
        let outcome = await makeActuator().actuate(row)
        #expect(outcome == .terminalGone)
        #expect(tmux.sends.isEmpty)
    }

    @Test func deadPaneIsTerminalGone() async throws {
        // The case tmux reports as success: `send-keys` into a remain-on-exit
        // pane exits 0, so only the consultation can catch it.
        tmux.paneTarget = .dead(terminalID: terminalID.uuidString)
        let outcome = await makeActuator().actuate(row)
        #expect(outcome == .terminalGone)
        #expect(tmux.sends.isEmpty)
    }

    /// `.terminalGone` CANCELS the scheduled resume, permanently. Doing that
    /// because no tmux server answered would throw away a pending resume for a
    /// session that is very likely still running, so an unreachable server
    /// fails the attempt (retryable) instead of cancelling the row.
    @Test func unreachableServerDoesNotCancelTheResume() async throws {
        tmux.paneTarget = .unreachable
        let outcome = await makeActuator().actuate(row)
        guard case .failed(let message) = outcome else {
            Issue.record("expected .failed, got \(outcome) — an unreachable server must not cancel")
            return
        }
        #expect(message.contains("could not reach tmux server"))
        #expect(outcome != .terminalGone)
        #expect(tmux.sends.isEmpty)
    }

    @Test func unrunnableConsultationTypesNothing() async throws {
        tmux.paneTargetError = FakeTmuxSendError()
        let outcome = await makeActuator().actuate(row)
        guard case .failed(let message) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(message.contains("could not verify the target pane"))
        #expect(tmux.sends.isEmpty)
    }

    @Test func newerTranscriptRecordCancels() async throws {
        // Record timestamped AFTER the limit was detected (createdAt is 1h ago).
        let line = #"{"type":"user","timestamp":"2099-01-01T00:00:00.000Z"}"#
        let outcome = await makeActuator(transcript: Data((line + "\n").utf8)).actuate(row)
        #expect(outcome == .userAlreadyContinued)
        #expect(tmux.sends.isEmpty)
    }

    @Test func copyModeReschedules() async throws {
        tmux.inMode = true
        let outcome = await makeActuator().actuate(row)
        #expect(outcome == .paneInCopyMode)
        #expect(tmux.sends.isEmpty)
    }

    @Test func claudeNotForegroundFails() async throws {
        let outcome = await makeActuator(inspector: FakeInspector(claudePID: nil)).actuate(row)
        if case .failed = outcome {} else { Issue.record("expected .failed, got \(outcome)") }
        #expect(tmux.sends.isEmpty)   // never type into a bare shell
    }

    @Test func happyPathSendsEscapeContinueEnterAndVerifiesViaActivity() async throws {
        // Activity hook already reports working → first verify poll succeeds.
        try await db.terminals.setActivityState(id: terminalID, activityState: .working, source: .derived)
        let outcome = await makeActuator().actuate(row)
        #expect(outcome == .sent)
        #expect(tmux.sends == ["key:Escape", "text:continue", "key:Enter"])
    }

    @Test func verifyTimeoutRetriesOnceThenFails() async throws {
        // Activity never becomes working and transcript never grows.
        try await db.terminals.setActivityState(id: terminalID, activityState: .idle, source: .derived)
        let outcome = await makeActuator().actuate(row)
        if case .failed = outcome {} else { Issue.record("expected .failed, got \(outcome)") }
        // Sequence sent twice: initial + one retry (spec §Actuation 6).
        #expect(tmux.sends == ["key:Escape", "text:continue", "key:Enter",
                               "key:Escape", "text:continue", "key:Enter"])
    }

    @Test func transcriptGrowthCountsAsVerification() async throws {
        try await db.terminals.setActivityState(id: terminalID, activityState: .idle, source: .derived)
        // Transcript grows between pre-send snapshot and verify polls.
        let counter = OSAllocatedUnfairLock(initialState: 0)
        let growing: @Sendable (String) -> Data? = { _ in
            let n = counter.withLock { $0 += 1; return $0 }
            return Data(repeating: 0x7b, count: n <= 1 ? 10 : 500)  // grows after first read
        }
        let actuator = LimitResumeActuator(
            db: db, tmux: tmux, inspector: FakeInspector(claudePID: 4242),
            readTranscript: growing,
            transcriptModifiedAt: { _ in nil }, waiter: { _ in }, actuationLog: makeTestActuationLog())
        let outcome = await actuator.actuate(row)
        #expect(outcome == .sent)
    }

    // MARK: - Retry re-runs eligibility (spec §Actuation "one retry of steps 1-5")

    @Test func copyModeEnteredBetweenAttemptsReschedulesAfterOneSend() async throws {
        // Attempt 1's eligibility pass sees no copy-mode and sends; attempt
        // 1's verify window times out (idle, flat transcript); attempt 2's
        // eligibility RE-CHECK sees copy-mode now set and reschedules
        // instead of blind-Escaping the user's scrollback.
        try await db.terminals.setActivityState(id: terminalID, activityState: .idle, source: .derived)
        tmux.inModeSequence = [false, true]
        let outcome = await makeActuator().actuate(row)
        #expect(outcome == .paneInCopyMode)
        #expect(tmux.sends == ["key:Escape", "text:continue", "key:Enter"])
    }

    @Test func userContinuedBetweenAttemptsCancelsAfterOneSend() async throws {
        // Attempt 1's eligibility pass reads a transcript with no newer
        // record and sends; attempt 1's verify window times out; attempt
        // 2's eligibility RE-CHECK reads a transcript that now has a record
        // newer than the limit (user typed manually in the window) and
        // cancels instead of sending again.
        try await db.terminals.setActivityState(id: terminalID, activityState: .idle, source: .derived)
        let counter = OSAllocatedUnfairLock(initialState: 0)
        // Padding is deliberately LARGER than the newer-record line so the
        // growth check during attempt 1's verify polls (which only compares
        // byte counts, not content) never mistakes the later reads for
        // growth.
        let padding = Data(repeating: 0x20, count: 200)
        let newerRecordLine = Data(
            (#"{"type":"user","timestamp":"2099-01-01T00:00:00.000Z"}"# + "\n").utf8)
        let flipping: @Sendable (String) -> Data? = { _ in
            let n = counter.withLock { $0 += 1; return $0 }
            return n == 1 ? padding : newerRecordLine
        }
        let actuator = LimitResumeActuator(
            db: db, tmux: tmux, inspector: FakeInspector(claudePID: 4242),
            readTranscript: flipping,
            transcriptModifiedAt: { _ in nil }, waiter: { _ in }, actuationLog: makeTestActuationLog())
        let outcome = await actuator.actuate(row)
        #expect(outcome == .userAlreadyContinued)
        #expect(tmux.sends == ["key:Escape", "text:continue", "key:Enter"])
    }

    @Test func toggleFlippedOffBetweenAttemptsCancelsAfterOneSend() async throws {
        // Attempt 1's eligibility pass sees the toggle on and sends; attempt
        // 1's verify window times out (idle, flat transcript, exactly like
        // `verifyTimeoutRetriesOnceThenFails`). The injected `waiter` — the
        // same seam `sendContinueSequence`/`verifyResumed` already await on
        // — flips the toggle off as a side effect of its FIRST call (the
        // interKeyPause after attempt 1's Escape), so by the time attempt
        // 2's eligibility RE-CHECK (step 0a) runs, the gate is off and it
        // cancels instead of sending again.
        try await db.terminals.setActivityState(id: terminalID, activityState: .idle, source: .derived)
        let counter = OSAllocatedUnfairLock(initialState: 0)
        let flippingWaiter: @Sendable (Duration) async -> Void = { _ in
            let n = counter.withLock { $0 += 1; return $0 }
            if n == 1 {
                try? await self.db.config.setAutoResumeOnLimitReset(false)
            }
        }
        let actuator = LimitResumeActuator(
            db: db, tmux: tmux, inspector: FakeInspector(claudePID: 4242),
            readTranscript: { _ in Data("{}\n".utf8) },
            transcriptModifiedAt: { _ in nil },
            waiter: flippingWaiter, actuationLog: makeTestActuationLog())
        let outcome = await actuator.actuate(row)
        #expect(outcome == .cancelledExternally)
        // Only attempt 1's 3 sends — attempt 2 never fires.
        #expect(tmux.sends == ["key:Escape", "text:continue", "key:Enter"])
    }

    // MARK: - Eligibility 0a: limitType-aware gate (spec 2026-07-08 §Gating)

    /// `row` (limitType "session") occupies the terminal's latch, so these
    /// api_error-row tests clear it first and insert their own pending row
    /// for the same terminal — mirrors how `scheduler.scheduleTransient`
    /// always inserts before `actuate` ever sees a row.
    private func insertApiErrorRow() async throws -> ScheduledResume {
        _ = try await db.scheduledResumes.cancelPending(terminalID: terminalID)
        let apiErrorRow = ScheduledResume(
            terminalID: terminalID, worktreeID: worktreeID, claudeSessionID: "sess",
            resetsAt: row.resetsAt, fireAt: row.fireAt,
            limitType: ScheduledResume.apiErrorLimitType, rawMessage: "m", createdAt: row.createdAt)
        guard let inserted = try await db.scheduledResumes.insertPending(apiErrorRow) else {
            Issue.record("expected latch to accept row after cancelPending")
            return apiErrorRow
        }
        return inserted
    }

    @Test func apiErrorRowCancelledExternallyWhenApiErrorToggleOffEvenIfLimitResetOn() async throws {
        try await db.config.setAutoResumeOnLimitReset(true)
        try await db.config.setAutoResumeOnApiError(false)
        let apiErrorRow = try await insertApiErrorRow()
        let outcome = await makeActuator().actuate(apiErrorRow)
        #expect(outcome == .cancelledExternally)
        #expect(tmux.sends.isEmpty)
    }

    @Test func apiErrorRowProceedsPastEligibility0aWhenApiErrorToggleOnEvenIfLimitResetOff() async throws {
        try await db.config.setAutoResumeOnLimitReset(false)
        try await db.config.setAutoResumeOnApiError(true)
        try await db.terminals.setActivityState(id: terminalID, activityState: .working, source: .derived)
        let apiErrorRow = try await insertApiErrorRow()
        let outcome = await makeActuator().actuate(apiErrorRow)
        // Falls through past 0a and runs the full send sequence (happy path).
        #expect(outcome == .sent)
        #expect(tmux.sends == ["key:Escape", "text:continue", "key:Enter"])
    }

    @Test func sessionRowUnaffectedByApiErrorToggle() async throws {
        try await db.config.setAutoResumeOnLimitReset(true)
        try await db.config.setAutoResumeOnApiError(false)
        try await db.terminals.setActivityState(id: terminalID, activityState: .working, source: .derived)
        let outcome = await makeActuator().actuate(row)
        #expect(outcome == .sent)
        #expect(tmux.sends == ["key:Escape", "text:continue", "key:Enter"])
    }

    @Test func sessionRowCancelledExternallyWhenLimitResetOffEvenIfApiErrorOn() async throws {
        try await db.config.setAutoResumeOnLimitReset(false)
        try await db.config.setAutoResumeOnApiError(true)
        let outcome = await makeActuator().actuate(row)
        #expect(outcome == .cancelledExternally)
        #expect(tmux.sends.isEmpty)
    }

    @Test func rowCancelledBetweenAttemptsCancelsAfterOneSend() async throws {
        // Same timeout setup as above, but instead of the global toggle,
        // the ROW is cancelled between attempts (mirrors
        // `LimitResumeSchedulerTests.copyModeRescheduleDropsRowNoLongerPending`'s
        // `CancellingActuator`, except here the test body — not a fake
        // actuator — does the cancelling, via the same waiter-side-effect
        // seam as the toggle test above). Attempt 2's eligibility RE-CHECK
        // (step 1b) sees the row is no longer `.pending` and cancels
        // instead of sending again.
        try await db.terminals.setActivityState(id: terminalID, activityState: .idle, source: .derived)
        let counter = OSAllocatedUnfairLock(initialState: 0)
        let cancellingWaiter: @Sendable (Duration) async -> Void = { _ in
            let n = counter.withLock { $0 += 1; return $0 }
            if n == 1 {
                _ = try? await self.db.scheduledResumes.cancelPending(terminalID: self.terminalID)
            }
        }
        let actuator = LimitResumeActuator(
            db: db, tmux: tmux, inspector: FakeInspector(claudePID: 4242),
            readTranscript: { _ in Data("{}\n".utf8) },
            transcriptModifiedAt: { _ in nil },
            waiter: cancellingWaiter, actuationLog: makeTestActuationLog())
        let outcome = await actuator.actuate(row)
        #expect(outcome == .cancelledExternally)
        // Only attempt 1's 3 sends — attempt 2 never fires.
        #expect(tmux.sends == ["key:Escape", "text:continue", "key:Enter"])
        // The row stays cancelled — not resurrected by a stray write.
        let stored = try await db.scheduledResumes.get(id: row.id)
        #expect(stored?.status == .cancelled)
    }

    // MARK: - Early-cancel probe (`userAlreadyContinued`)

    @Test func earlyProbeTrueWhenTranscriptHasRecordNewerThanDetection() async throws {
        // Same predicate as fire-time step 2: createdAt is 1h ago, the
        // record is timestamped 2099.
        let line = #"{"type":"user","timestamp":"2099-01-01T00:00:00.000Z"}"#
        let actuator = makeActuator(
            transcript: Data((line + "\n").utf8),
            transcriptMtime: row.createdAt.addingTimeInterval(1))
        let continued = await actuator.userAlreadyContinued(row)
        #expect(continued)
        #expect(tmux.sends.isEmpty)   // read-only probe: never touches tmux
    }

    @Test func earlyProbeFalseWhenTranscriptHasNoNewerRecord() async throws {
        let actuator = makeActuator(
            transcript: Data("{}\n".utf8),
            transcriptMtime: row.createdAt.addingTimeInterval(1))
        let continued = await actuator.userAlreadyContinued(row)
        #expect(continued == false)
    }

    @Test func earlyProbeFalseWhenTerminalIsGone() async throws {
        let orphan = ScheduledResume(
            terminalID: UUID(), worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: row.resetsAt, fireAt: row.fireAt,
            limitType: "session", rawMessage: "m")
        let continued = await makeActuator().userAlreadyContinued(orphan)
        #expect(continued == false)   // cancelling for THAT is fire time's job
    }

    // MARK: - mtime pre-filter

    /// The probe runs every `earlyCheckInterval` per pending row and a long
    /// session's JSONL is tens of MB, so an mtime at or before the detection
    /// instant must skip the whole-file read entirely. The injected content
    /// WOULD trip the predicate, so `false` can only come from a skipped read.
    @Test func earlyProbeSkipsReadWhenTranscriptUnmodifiedSinceDetection() async throws {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let newerRecord = Data(
            (#"{"type":"user","timestamp":"2099-01-01T00:00:00.000Z"}"# + "\n").utf8)
        let staleMtime = row.createdAt.addingTimeInterval(-1)
        let actuator = LimitResumeActuator(
            db: db, tmux: tmux, inspector: FakeInspector(claudePID: 4242),
            readTranscript: { _ in
                reads.withLock { $0 += 1 }
                return newerRecord
            },
            transcriptModifiedAt: { _ in staleMtime }, waiter: { _ in }, actuationLog: makeTestActuationLog())
        let continued = await actuator.userAlreadyContinued(row)
        #expect(continued == false)
        #expect(reads.withLock { $0 } == 0)
    }

    @Test func earlyProbeReadsWhenTranscriptModifiedAfterDetection() async throws {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let newerRecord = Data(
            (#"{"type":"user","timestamp":"2099-01-01T00:00:00.000Z"}"# + "\n").utf8)
        let freshMtime = row.createdAt.addingTimeInterval(1)
        let actuator = LimitResumeActuator(
            db: db, tmux: tmux, inspector: FakeInspector(claudePID: 4242),
            readTranscript: { _ in
                reads.withLock { $0 += 1 }
                return newerRecord
            },
            transcriptModifiedAt: { _ in freshMtime }, waiter: { _ in }, actuationLog: makeTestActuationLog())
        let continued = await actuator.userAlreadyContinued(row)
        #expect(continued)
        #expect(reads.withLock { $0 } == 1)
    }

    /// An unreadable mtime is NOT "unmodified" — fall through to the read
    /// rather than silently answering false forever.
    @Test func earlyProbeReadsWhenMtimeUnavailable() async throws {
        let line = #"{"type":"user","timestamp":"2099-01-01T00:00:00.000Z"}"#
        let actuator = makeActuator(
            transcript: Data((line + "\n").utf8), transcriptMtime: nil)
        let continued = await actuator.userAlreadyContinued(row)
        #expect(continued)
    }

    /// Fire-time eligibility must NEVER be mtime-gated: its transcript read
    /// doubles as `verifyResumed`'s pre-send growth baseline, and skipping it
    /// would leave `preSize == 0` so any later read looks like growth.
    @Test func fireTimeEligibilityIsNotMtimeGated() async throws {
        let line = #"{"type":"user","timestamp":"2099-01-01T00:00:00.000Z"}"#
        let outcome = await makeActuator(
            transcript: Data((line + "\n").utf8),
            transcriptMtime: row.createdAt.addingTimeInterval(-1)   // would skip the early read
        ).actuate(row)
        #expect(outcome == .userAlreadyContinued)
        #expect(tmux.sends.isEmpty)
    }

    // MARK: - Thrown send retries instead of instant .failed

    @Test func throwingSendOnFirstAttemptRetriesAndSucceeds() async throws {
        try await db.terminals.setActivityState(id: terminalID, activityState: .working, source: .derived)
        tmux.throwOnEscapeAttempts = [1]
        let outcome = await makeActuator().actuate(row)
        #expect(outcome == .sent)
        // Attempt 1 threw before recording anything; attempt 2 sent in full.
        #expect(tmux.sends == ["key:Escape", "text:continue", "key:Enter"])
    }

    @Test func throwingSendOnBothAttemptsFails() async throws {
        try await db.terminals.setActivityState(id: terminalID, activityState: .idle, source: .derived)
        tmux.throwOnEscapeAttempts = [1, 2]
        let outcome = await makeActuator().actuate(row)
        if case .failed = outcome {} else { Issue.record("expected .failed, got \(outcome)") }
        #expect(tmux.sends.isEmpty)
    }
}

// MARK: - ProductionPaneProcessInspector

@Suite struct ProductionPaneProcessInspectorTests {
    @Test func paneChildWithForegroundClaudeIsFound() {
        let signaller = FakeProcessSignaller()
        signaller.childrenByServer[100] = [200]
        signaller.cmdlines[200] = "/opt/homebrew/bin/claude"
        signaller.stats[200] = "S+"
        let inspector = ProductionPaneProcessInspector(signaller: signaller)
        #expect(inspector.foregroundClaudePID(panePID: 100) == 200)
    }

    @Test func childWithoutForegroundFlagIsNotFound() {
        let signaller = FakeProcessSignaller()
        signaller.childrenByServer[100] = [200]
        signaller.cmdlines[200] = "claude"
        signaller.stats[200] = "Ss"   // no trailing "+"
        let inspector = ProductionPaneProcessInspector(signaller: signaller)
        #expect(inspector.foregroundClaudePID(panePID: 100) == nil)
    }

    @Test func grandchildWithForegroundClaudeIsFound() {
        let signaller = FakeProcessSignaller()
        signaller.childrenByServer[100] = [200]     // pane -> wrapper shell
        signaller.childrenByServer[200] = [300]     // wrapper shell -> claude
        signaller.cmdlines[300] = "claude"
        signaller.stats[300] = "S+"
        let inspector = ProductionPaneProcessInspector(signaller: signaller)
        #expect(inspector.foregroundClaudePID(panePID: 100) == 300)
    }
}
