import Foundation
import os
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import DaemonTestSupport
import TestSupport

/// The text the rail types, spelled out rather than read from the actuator:
/// the actuator's constant is what these tests pin.
private let expectedResumeText =
    "[Automatic: TBD's auto-resume typed this, not a person. "
    + "It answers no question and approves nothing.] continue"

/// Every write the holder input seam was handed, read back as the key or text
/// it carried: a lone ESC is `key:Escape`, a lone CR `key:Enter`, anything
/// else `text:` and its bytes. Answers every write as delivered.
final class RecordedResumeWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var sends: [String] { lock.withLock { recorded } }

    var send: @Sendable (UUID, Data) async -> Bool {
        { [self] _, bytes in
            let entry: String
            switch bytes {
            case Data([0x1B]): entry = "key:Escape"
            case Data([0x0D]): entry = "key:Enter"
            default: entry = "text:" + String(decoding: bytes, as: UTF8.self)
            }
            lock.withLock { recorded.append(entry) }
            return true
        }
    }
}

/// The rail on a holder-backed row, the one transport TBD types into. How the
/// holder arm frames and paces its writes, and how it fails when a write is
/// refused, is `HolderTmuxAssumptionGateTests`' subject; these pin the
/// eligibility, verification and retry rules every resume runs through.
@Suite struct LimitResumeActuatorTests {
    let db: TBDDatabase
    let holder = RecordedResumeWrites()
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
            worktreeID: wt.id, tmuxWindowID: "", tmuxPaneID: "",
            transport: .holder, childPID: 4242)
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
        transcript: Data? = Data("{}\n".utf8),
        transcriptMtime: Date? = nil
    ) -> LimitResumeActuator {
        LimitResumeActuator(
            db: db,
            readTranscript: { _ in transcript },
            transcriptModifiedAt: { _ in transcriptMtime },
            waiter: { _ in }, actuationLog: makeTestActuationLog(),   // no real sleeping in unit tests
            holderSend: holder.send)
    }

    @Test func missingTerminalIsTerminalGone() async throws {
        let orphan = ScheduledResume(
            terminalID: UUID(), worktreeID: worktreeID, claudeSessionID: nil,
            resetsAt: row.resetsAt, fireAt: row.fireAt,
            limitType: "session", rawMessage: "m")
        let outcome = await makeActuator().actuate(orphan)
        #expect(outcome == .terminalGone)
        #expect(holder.sends.isEmpty)
    }

    @Test func suspendedTerminalIsTerminalGone() async throws {
        try await db.terminals.setSuspended(id: terminalID, sessionID: "sess", snapshot: nil)
        let outcome = await makeActuator().actuate(row)
        #expect(outcome == .terminalGone)
        #expect(holder.sends.isEmpty)
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
        #expect(holder.sends.isEmpty)
    }

    @Test func newerTranscriptRecordCancels() async throws {
        // Record timestamped AFTER the limit was detected (createdAt is 1h ago).
        let line = #"{"type":"user","timestamp":"2099-01-01T00:00:00.000Z"}"#
        let outcome = await makeActuator(transcript: Data((line + "\n").utf8)).actuate(row)
        #expect(outcome == .userAlreadyContinued)
        #expect(holder.sends.isEmpty)
    }

    @Test func happyPathSendsEscapeContinueEnterAndVerifiesViaActivity() async throws {
        // Activity hook already reports working → first verify poll succeeds.
        try await db.terminals.setActivityState(id: terminalID, activityState: .working, source: .derived)
        let outcome = await makeActuator().actuate(row)
        #expect(outcome == .sent)
        #expect(holder.sends == ["key:Escape", "text:" + expectedResumeText, "key:Enter"])
    }

    @Test func verifyTimeoutRetriesOnceThenFails() async throws {
        // Activity never becomes working and transcript never grows.
        try await db.terminals.setActivityState(id: terminalID, activityState: .idle, source: .derived)
        let outcome = await makeActuator().actuate(row)
        if case .failed = outcome {} else { Issue.record("expected .failed, got \(outcome)") }
        // Sequence sent twice: initial + one retry (spec §Actuation 6).
        #expect(holder.sends == ["key:Escape", "text:" + expectedResumeText, "key:Enter",
                               "key:Escape", "text:" + expectedResumeText, "key:Enter"])
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
            db: db,
            readTranscript: growing,
            transcriptModifiedAt: { _ in nil }, waiter: { _ in }, actuationLog: makeTestActuationLog(),
            holderSend: holder.send)
        let outcome = await actuator.actuate(row)
        #expect(outcome == .sent)
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
            db: db,
            readTranscript: flipping,
            transcriptModifiedAt: { _ in nil }, waiter: { _ in }, actuationLog: makeTestActuationLog(),
            holderSend: holder.send)
        let outcome = await actuator.actuate(row)
        #expect(outcome == .userAlreadyContinued)
        #expect(holder.sends == ["key:Escape", "text:" + expectedResumeText, "key:Enter"])
    }

    @Test func toggleFlippedOffBetweenAttemptsCancelsAfterOneSend() async throws {
        // Attempt 1's eligibility pass sees the toggle on and sends; attempt
        // 1's verify window times out (idle, flat transcript, exactly like
        // `verifyTimeoutRetriesOnceThenFails`). The injected `waiter` — the
        // same seam the send's pauses and `verifyResumed` already await on
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
            db: db,
            readTranscript: { _ in Data("{}\n".utf8) },
            transcriptModifiedAt: { _ in nil },
            waiter: flippingWaiter, actuationLog: makeTestActuationLog(),
            holderSend: holder.send)
        let outcome = await actuator.actuate(row)
        #expect(outcome == .cancelledExternally)
        // Only attempt 1's 3 sends — attempt 2 never fires.
        #expect(holder.sends == ["key:Escape", "text:" + expectedResumeText, "key:Enter"])
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
        #expect(holder.sends.isEmpty)
    }

    @Test func apiErrorRowProceedsPastEligibility0aWhenApiErrorToggleOnEvenIfLimitResetOff() async throws {
        try await db.config.setAutoResumeOnLimitReset(false)
        try await db.config.setAutoResumeOnApiError(true)
        try await db.terminals.setActivityState(id: terminalID, activityState: .working, source: .derived)
        let apiErrorRow = try await insertApiErrorRow()
        let outcome = await makeActuator().actuate(apiErrorRow)
        // Falls through past 0a and runs the full send sequence (happy path).
        #expect(outcome == .sent)
        #expect(holder.sends == ["key:Escape", "text:" + expectedResumeText, "key:Enter"])
    }

    @Test func sessionRowUnaffectedByApiErrorToggle() async throws {
        try await db.config.setAutoResumeOnLimitReset(true)
        try await db.config.setAutoResumeOnApiError(false)
        try await db.terminals.setActivityState(id: terminalID, activityState: .working, source: .derived)
        let outcome = await makeActuator().actuate(row)
        #expect(outcome == .sent)
        #expect(holder.sends == ["key:Escape", "text:" + expectedResumeText, "key:Enter"])
    }

    @Test func sessionRowCancelledExternallyWhenLimitResetOffEvenIfApiErrorOn() async throws {
        try await db.config.setAutoResumeOnLimitReset(false)
        try await db.config.setAutoResumeOnApiError(true)
        let outcome = await makeActuator().actuate(row)
        #expect(outcome == .cancelledExternally)
        #expect(holder.sends.isEmpty)
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
            db: db,
            readTranscript: { _ in Data("{}\n".utf8) },
            transcriptModifiedAt: { _ in nil },
            waiter: cancellingWaiter, actuationLog: makeTestActuationLog(),
            holderSend: holder.send)
        let outcome = await actuator.actuate(row)
        #expect(outcome == .cancelledExternally)
        // Only attempt 1's 3 sends — attempt 2 never fires.
        #expect(holder.sends == ["key:Escape", "text:" + expectedResumeText, "key:Enter"])
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
        #expect(holder.sends.isEmpty)   // read-only probe: never writes
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
            db: db,
            readTranscript: { _ in
                reads.withLock { $0 += 1 }
                return newerRecord
            },
            transcriptModifiedAt: { _ in staleMtime }, waiter: { _ in }, actuationLog: makeTestActuationLog(),
            holderSend: holder.send)
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
            db: db,
            readTranscript: { _ in
                reads.withLock { $0 += 1 }
                return newerRecord
            },
            transcriptModifiedAt: { _ in freshMtime }, waiter: { _ in }, actuationLog: makeTestActuationLog(),
            holderSend: holder.send)
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
        #expect(holder.sends.isEmpty)
    }

    /// TBD no longer types into tmux. An armed resume on a live tmux row fails
    /// by name, which notifies the person, rather than cancelling in silence or
    /// typing anything.
    @Test func liveTmuxRowIsNotTyped() async throws {
        let tmuxRow = try await db.terminals.create(
            worktreeID: worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1")
        try await db.terminals.updateSession(
            id: tmuxRow.id, sessionID: "sess-tmux", transcriptPath: "/tmp/act-transcript.jsonl")
        try await db.terminals.setActivityState(
            id: tmuxRow.id, activityState: .working, source: .derived)
        let resume = ScheduledResume(
            terminalID: tmuxRow.id, worktreeID: worktreeID, claudeSessionID: "sess-tmux",
            resetsAt: row.resetsAt, fireAt: row.fireAt,
            limitType: "session", rawMessage: "m", createdAt: row.createdAt)
        _ = try await db.scheduledResumes.insertPending(resume)

        let outcome = await makeActuator().actuate(resume)
        #expect(outcome == .failed(LimitResumeActuator.tmuxSessionNotTyped))
        #expect(holder.sends.isEmpty)
    }
}
