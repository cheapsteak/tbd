import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct ScheduledResumeStoreTests {
    let db: TBDDatabase
    let terminalID: UUID
    let worktreeID: UUID

    init() async throws {
        db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/srs-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/srs-wt-\(UUID().uuidString)", tmuxServer: "tbd-srs")
        worktreeID = wt.id
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1")
        terminalID = terminal.id
    }

    private func makeResume(
        fireAt: Date = Date().addingTimeInterval(90),
        limitType: String = "session",
        createdAt: Date = Date(),
        status: ScheduledResumeStatus = .pending,
        terminalID overrideTerminalID: UUID? = nil
    ) -> ScheduledResume {
        ScheduledResume(
            terminalID: overrideTerminalID ?? terminalID, worktreeID: worktreeID,
            claudeSessionID: "sess-1",
            resetsAt: Date().addingTimeInterval(60), fireAt: fireAt,
            limitType: limitType,
            rawMessage: "You've hit your session limit · resets 3pm (UTC)",
            createdAt: createdAt,
            status: status)
    }

    @Test func insertPendingSetsTerminalBadgeAndRoundTrips() async throws {
        let resume = makeResume()
        let inserted = try await db.scheduledResumes.insertPending(resume)
        #expect(inserted == resume)
        let fetched = try await db.scheduledResumes.get(id: resume.id)
        #expect(fetched?.id == resume.id)
        #expect(fetched?.terminalID == resume.terminalID)
        #expect(fetched?.worktreeID == resume.worktreeID)
        #expect(fetched?.claudeSessionID == resume.claudeSessionID)
        // Dates lose subsecond precision in SQLite (millisecond precision), so allow 0.01s tolerance
        #expect(abs(fetched!.fireAt.timeIntervalSince(resume.fireAt)) < 0.01)
        #expect(abs(fetched!.resetsAt.timeIntervalSince(resume.resetsAt)) < 0.01)
        #expect(abs(fetched!.createdAt.timeIntervalSince(resume.createdAt)) < 0.01)
        #expect(fetched?.limitType == resume.limitType)
        #expect(fetched?.rawMessage == resume.rawMessage)
        #expect(fetched?.status == .pending)
        #expect(fetched?.attemptCount == 0)
        let terminal = try await db.terminals.get(id: terminalID)
        #expect(terminal?.pendingResumeAt != nil)
    }

    @Test func latchRejectsSecondPendingForSameTerminal() async throws {
        _ = try await db.scheduledResumes.insertPending(makeResume())
        let second = try await db.scheduledResumes.insertPending(makeResume())
        #expect(second == nil)
        let rows = try await db.scheduledResumes.pending()
        #expect(rows.count == 1)
    }

    @Test func dbLevelPartialUniqueIndexEnforcesOnePerTerminal() async throws {
        let resume = makeResume()
        _ = try await db.scheduledResumes.insertPending(resume)

        // Try to insert a second pending row for the same terminal via direct SQL,
        // bypassing the store's guard. The partial unique index should reject it.
        do {
            try await db.writerForTests.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO scheduled_resumes
                    (id, terminalID, worktreeID, claudeSessionID, resetsAt, fireAt,
                     limitType, rawMessage, createdAt, status, attemptCount)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        UUID().uuidString, terminalID.uuidString, worktreeID.uuidString,
                        "sess-2", Date().addingTimeInterval(60), Date().addingTimeInterval(120),
                        "session", "msg", Date(), ScheduledResumeStatus.pending.rawValue, 0
                    ])
            }
            // If we reach here, the constraint was not enforced — fail the test.
            #expect(Bool(false), "DB unique index did not reject second pending row")
        } catch {
            // Expected: constraint violation when trying to insert second pending row.
            // Verify it's a constraint error (result code 19 for SQLITE_CONSTRAINT).
            #expect((error as? DatabaseError)?.resultCode == .SQLITE_CONSTRAINT)
        }
    }

    @Test func insertAuditNeverSetsBadgeOrLatch() async throws {
        var audit = makeResume()
        audit.status = .cancelled
        try await db.scheduledResumes.insertAudit(audit)
        #expect(try await db.scheduledResumes.pending().isEmpty)
        let terminal = try await db.terminals.get(id: terminalID)
        #expect(terminal?.pendingResumeAt == nil)
        // A real pending insert still succeeds afterwards (audit row ≠ latch).
        #expect(try await db.scheduledResumes.insertPending(makeResume()) != nil)
    }

    @Test func setStatusLeavingPendingClearsBadge() async throws {
        let resume = makeResume()
        _ = try await db.scheduledResumes.insertPending(resume)
        try await db.scheduledResumes.setStatus(id: resume.id, status: .sent)
        #expect(try await db.scheduledResumes.get(id: resume.id)?.status == .sent)
        #expect(try await db.terminals.get(id: terminalID)?.pendingResumeAt == nil)
        #expect(try await db.scheduledResumes.pending().isEmpty)
    }

    @Test func rescheduleMovesFireAtAndBadge() async throws {
        let resume = makeResume()
        _ = try await db.scheduledResumes.insertPending(resume)
        let newFireAt = resume.fireAt.addingTimeInterval(120)
        let rescheduled = try await db.scheduledResumes.reschedule(id: resume.id, fireAt: newFireAt, attemptCount: 3)
        #expect(rescheduled)
        let row = try await db.scheduledResumes.get(id: resume.id)
        #expect(abs(row!.fireAt.timeIntervalSince(newFireAt)) < 0.01)
        #expect(row?.attemptCount == 3)
        let terminal = try await db.terminals.get(id: terminalID)
        #expect(abs(terminal!.pendingResumeAt!.timeIntervalSince(newFireAt)) < 0.01)
    }

    /// Parking cancels the scheduled auto-resume atomically with the park
    /// write: `TerminalStore.setHibernated` is the choke point EVERY park site
    /// flows through (performHibernate, the reconcile recovery park, the
    /// recreate-window dead-window park), and it runs the same
    /// `cancelPendingInTransaction` routine as an explicit user cancel. Wake
    /// (`clearHibernated`) must NOT resurrect the cancelled row.
    @Test func setHibernatedCancelsPendingAndWakeDoesNotResurrect() async throws {
        let resume = makeResume()
        _ = try await db.scheduledResumes.insertPending(resume)
        #expect(try await db.terminals.get(id: terminalID)?.pendingResumeAt != nil)

        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")

        #expect(try await db.scheduledResumes.get(id: resume.id)?.status == .cancelled,
                "parking must cancel the pending row — the Claude process is dead")
        #expect(try await db.scheduledResumes.pending(terminalID: terminalID) == nil)
        #expect(try await db.terminals.get(id: terminalID)?.pendingResumeAt == nil,
                "the pendingResumeAt mirror must clear in the same write")

        try await db.terminals.clearHibernated(id: terminalID)
        #expect(try await db.scheduledResumes.get(id: resume.id)?.status == .cancelled,
                "wake must not resurrect the cancelled resume")
        #expect(try await db.terminals.get(id: terminalID)?.pendingResumeAt == nil)
    }

    /// The other branch of the park-time cancel: a terminal with NO pending
    /// resume parks cleanly (the in-transaction cancel is a no-op, not an
    /// error) and stays parked.
    @Test func setHibernatedWithoutPendingResumeStillParks() async throws {
        try await db.terminals.setHibernated(id: terminalID, sessionID: "sess-1")
        let terminal = try await db.terminals.get(id: terminalID)
        #expect(terminal?.hibernatedAt != nil)
        #expect(terminal?.pendingResumeAt == nil)
        #expect(try await db.scheduledResumes.all(terminalID: terminalID).isEmpty)
    }

    @Test func cancelPendingByTerminal() async throws {
        let resume = makeResume()
        _ = try await db.scheduledResumes.insertPending(resume)
        #expect(try await db.scheduledResumes.cancelPending(terminalID: terminalID))
        #expect(try await db.scheduledResumes.get(id: resume.id)?.status == .cancelled)
        #expect(try await db.terminals.get(id: terminalID)?.pendingResumeAt == nil)
        // Second cancel is a no-op.
        #expect(try await db.scheduledResumes.cancelPending(terminalID: terminalID) == false)
    }

    @Test func cancelAllPending() async throws {
        _ = try await db.scheduledResumes.insertPending(makeResume())
        let terminal2 = try await db.terminals.create(
            worktreeID: worktreeID, tmuxWindowID: "@2", tmuxPaneID: "%2")
        _ = try await db.scheduledResumes.insertPending(ScheduledResume(
            terminalID: terminal2.id, worktreeID: worktreeID,
            resetsAt: Date(), fireAt: Date().addingTimeInterval(60),
            limitType: "weekly", rawMessage: "m"))
        let count = try await db.scheduledResumes.cancelAllPending()
        #expect(count == 2)
        #expect(try await db.scheduledResumes.pending().isEmpty)
        #expect(try await db.terminals.get(id: terminal2.id)?.pendingResumeAt == nil)
    }

    @Test func countRecentApiErrorAttemptsFiltersTerminalTypeStatusAndWindow() async throws {
        let now = Date()
        let since = now.addingTimeInterval(-30 * 60)

        // Right terminal, api_error, sent, within window -> counts.
        try await db.scheduledResumes.insertAudit(makeResume(
            limitType: ScheduledResume.apiErrorLimitType,
            createdAt: now.addingTimeInterval(-5 * 60), status: .sent))
        // Right terminal, api_error, failed, within window -> counts.
        try await db.scheduledResumes.insertAudit(makeResume(
            limitType: ScheduledResume.apiErrorLimitType,
            createdAt: now.addingTimeInterval(-10 * 60), status: .failed))
        // Right terminal, api_error, sent, but outside the window -> excluded.
        try await db.scheduledResumes.insertAudit(makeResume(
            limitType: ScheduledResume.apiErrorLimitType,
            createdAt: now.addingTimeInterval(-45 * 60), status: .sent))
        // Right terminal, api_error, cancelled, within window -> not a failed attempt, excluded.
        try await db.scheduledResumes.insertAudit(makeResume(
            limitType: ScheduledResume.apiErrorLimitType,
            createdAt: now.addingTimeInterval(-2 * 60), status: .cancelled))
        // Wrong terminal, api_error, pending -> excluded.
        let terminal2 = try await db.terminals.create(
            worktreeID: worktreeID, tmuxWindowID: "@2", tmuxPaneID: "%2")
        _ = try await db.scheduledResumes.insertPending(makeResume(
            limitType: ScheduledResume.apiErrorLimitType,
            createdAt: now, terminalID: terminal2.id))
        // Right terminal, sent, within window, but wrong limitType -> excluded.
        try await db.scheduledResumes.insertAudit(makeResume(
            limitType: "session",
            createdAt: now.addingTimeInterval(-1 * 60), status: .sent))

        let count = try await db.scheduledResumes.countRecentApiErrorAttempts(
            terminalID: terminalID, since: since)
        #expect(count == 2)
    }

    @Test func cancelAllPendingScopedToApiErrorOnly() async throws {
        let resumeA = makeResume(limitType: ScheduledResume.apiErrorLimitType)
        _ = try await db.scheduledResumes.insertPending(resumeA)
        let terminalB = try await db.terminals.create(
            worktreeID: worktreeID, tmuxWindowID: "@2", tmuxPaneID: "%2")
        let resumeB = makeResume(limitType: "session", terminalID: terminalB.id)
        _ = try await db.scheduledResumes.insertPending(resumeB)

        let count = try await db.scheduledResumes.cancelAllPending(scope: .apiErrorOnly)
        #expect(count == 1)
        #expect(try await db.scheduledResumes.get(id: resumeA.id)?.status == .cancelled)
        #expect(try await db.terminals.get(id: terminalID)?.pendingResumeAt == nil)
        #expect(try await db.scheduledResumes.get(id: resumeB.id)?.status == .pending)
        #expect(try await db.terminals.get(id: terminalB.id)?.pendingResumeAt != nil)
    }

    @Test func cancelAllPendingScopedToLimitOnly() async throws {
        let resumeA = makeResume(limitType: ScheduledResume.apiErrorLimitType)
        _ = try await db.scheduledResumes.insertPending(resumeA)
        let terminalB = try await db.terminals.create(
            worktreeID: worktreeID, tmuxWindowID: "@2", tmuxPaneID: "%2")
        let resumeB = makeResume(limitType: "session", terminalID: terminalB.id)
        _ = try await db.scheduledResumes.insertPending(resumeB)

        let count = try await db.scheduledResumes.cancelAllPending(scope: .limitOnly)
        #expect(count == 1)
        #expect(try await db.scheduledResumes.get(id: resumeB.id)?.status == .cancelled)
        #expect(try await db.terminals.get(id: terminalB.id)?.pendingResumeAt == nil)
        #expect(try await db.scheduledResumes.get(id: resumeA.id)?.status == .pending)
        #expect(try await db.terminals.get(id: terminalID)?.pendingResumeAt != nil)
    }

    @Test func cancelAllPendingDefaultScopeCancelsBothScopes() async throws {
        let resumeA = makeResume(limitType: ScheduledResume.apiErrorLimitType)
        _ = try await db.scheduledResumes.insertPending(resumeA)
        let terminalB = try await db.terminals.create(
            worktreeID: worktreeID, tmuxWindowID: "@2", tmuxPaneID: "%2")
        let resumeB = makeResume(limitType: "session", terminalID: terminalB.id)
        _ = try await db.scheduledResumes.insertPending(resumeB)

        let count = try await db.scheduledResumes.cancelAllPending(scope: .all)
        #expect(count == 2)
        #expect(try await db.scheduledResumes.pending().isEmpty)
    }

    @Test func pendingOrderedByFireAt() async throws {
        let terminal2 = try await db.terminals.create(
            worktreeID: worktreeID, tmuxWindowID: "@2", tmuxPaneID: "%2")
        let later = makeResume(fireAt: Date().addingTimeInterval(500))
        _ = try await db.scheduledResumes.insertPending(later)
        let sooner = ScheduledResume(
            terminalID: terminal2.id, worktreeID: worktreeID,
            resetsAt: Date(), fireAt: Date().addingTimeInterval(100),
            limitType: "session", rawMessage: "m")
        _ = try await db.scheduledResumes.insertPending(sooner)
        let rows = try await db.scheduledResumes.pending()
        #expect(rows.map(\.id) == [sooner.id, later.id])
    }

    @Test func pendingByTerminalIDReturnsOnlyRequestedTerminal() async throws {
        let terminal2 = try await db.terminals.create(
            worktreeID: worktreeID, tmuxWindowID: "@2", tmuxPaneID: "%2")
        let resume1 = makeResume()
        let resume2 = ScheduledResume(
            terminalID: terminal2.id, worktreeID: worktreeID,
            resetsAt: Date(), fireAt: Date().addingTimeInterval(100),
            limitType: "session", rawMessage: "m2")
        _ = try await db.scheduledResumes.insertPending(resume1)
        _ = try await db.scheduledResumes.insertPending(resume2)

        let forTerminal1 = try await db.scheduledResumes.pending(terminalID: terminalID)
        #expect(forTerminal1?.id == resume1.id)
        let forTerminal2 = try await db.scheduledResumes.pending(terminalID: terminal2.id)
        #expect(forTerminal2?.id == resume2.id)
        let forUnknown = try await db.scheduledResumes.pending(terminalID: UUID())
        #expect(forUnknown == nil)
    }

    @Test func rescheduleReturnsFailsForNonPendingAndMissingRows() async throws {
        let resume = makeResume()
        _ = try await db.scheduledResumes.insertPending(resume)

        // Cancel the pending row, making it non-pending
        _ = try await db.scheduledResumes.cancelPending(terminalID: terminalID)
        let row = try await db.scheduledResumes.get(id: resume.id)
        #expect(row?.status == .cancelled)

        // Reschedule on the now-cancelled row should return false and not touch the mirror
        let rescheduled = try await db.scheduledResumes.reschedule(
            id: resume.id, fireAt: Date(), attemptCount: 5)
        #expect(rescheduled == false)
        let terminal = try await db.terminals.get(id: terminalID)
        #expect(terminal?.pendingResumeAt == nil)

        // Reschedule on a non-existent row should return false
        let rescheduleUnknown = try await db.scheduledResumes.reschedule(
            id: UUID(), fireAt: Date(), attemptCount: 1)
        #expect(rescheduleUnknown == false)
    }
}
