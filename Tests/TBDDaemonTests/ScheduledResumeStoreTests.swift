import Foundation
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

    private func makeResume(fireAt: Date = Date().addingTimeInterval(90)) -> ScheduledResume {
        ScheduledResume(
            terminalID: terminalID, worktreeID: worktreeID,
            claudeSessionID: "sess-1",
            resetsAt: Date().addingTimeInterval(60), fireAt: fireAt,
            limitType: "session",
            rawMessage: "You've hit your session limit · resets 3pm (UTC)")
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
        // Dates lose subsecond precision in SQLite, so allow 1-second tolerance
        #expect(abs(fetched!.fireAt.timeIntervalSince(resume.fireAt)) < 1)
        #expect(abs(fetched!.resetsAt.timeIntervalSince(resume.resetsAt)) < 1)
        #expect(abs(fetched!.createdAt.timeIntervalSince(resume.createdAt)) < 1)
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
            #expect(error != nil)
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
        try await db.scheduledResumes.reschedule(id: resume.id, fireAt: newFireAt, attemptCount: 3)
        let row = try await db.scheduledResumes.get(id: resume.id)
        #expect(abs(row!.fireAt.timeIntervalSince(newFireAt)) < 1)
        #expect(row?.attemptCount == 3)
        let terminal = try await db.terminals.get(id: terminalID)
        #expect(abs(terminal!.pendingResumeAt!.timeIntervalSince(newFireAt)) < 1)
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
}
