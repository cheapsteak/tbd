import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// The two narrow writers behind the exit stamp. They are deliberately NOT
/// `setHibernated` / `clearHibernated`: those mint a session incarnation, cancel
/// scheduled resumes and clear `suspendedAt`, all of which belong to a park TBD
/// performed. A hook reporting that Claude left performed no park and must move
/// exactly two columns.
@Suite("TerminalStore exit stamp")
struct TerminalExitStampStoreTests {
    private let stamp = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeTerminal(_ db: TBDDatabase) async throws -> Terminal {
        let worktree = try await db.worktrees.createScratch(
            name: "wt", displayName: "wt",
            path: "/tmp/tbd-nonexistent-\(UUID().uuidString)", tmuxServer: "tbd-test")
        return try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "sess-1", kind: .claude)
    }

    @Test func stampParksTheRowWithTheExitedReason() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeTerminal(db)

        let changed = try await db.terminals.stampSessionExited(
            id: terminal.id, reportedIncarnationID: nil, at: stamp)

        #expect(changed)
        let row = try #require(try await db.terminals.get(id: terminal.id))
        #expect(row.hibernatedAt == stamp)
        #expect(row.hibernateReason == .exited)
        #expect(row.isExitStamped)
        // Untouched: the session is still the one to resume.
        #expect(row.claudeSessionID == "sess-1")
    }

    /// The load-bearing negative. A row TBD deliberately parked already carries
    /// its own reason, and a late `SessionEnd` from the process TBD killed must
    /// not rewrite it — the record of who parked a session is what
    /// wake-on-focus reads.
    @Test func stampLeavesAnAlreadyParkedRowAlone() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeTerminal(db)
        try await db.terminals.setHibernated(
            id: terminal.id, sessionID: "sess-1", reason: .manual,
            at: Date(timeIntervalSince1970: 1_700_000_000))

        let changed = try await db.terminals.stampSessionExited(
            id: terminal.id, reportedIncarnationID: nil, at: stamp)

        #expect(!changed)
        let row = try #require(try await db.terminals.get(id: terminal.id))
        #expect(row.hibernateReason == .manual)
        #expect(row.hibernatedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// A hook from a process TBD has already replaced names the OLD incarnation.
    /// Stamping on it would park a live successor.
    @Test func stampDeclinesAMismatchedIncarnation() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeTerminal(db)
        let changed = try await db.terminals.stampSessionExited(
            id: terminal.id, reportedIncarnationID: UUID(), at: stamp)

        #expect(!changed)
        let row = try #require(try await db.terminals.get(id: terminal.id))
        #expect(row.hibernatedAt == nil)
    }

    /// A holder-backed row is never stamped. The holder's whole job is the
    /// Claude process, so there is no shell for a send to mis-execute, and the
    /// coordinator's wake respawns into a tmux window it cannot use — a park
    /// here is one nothing could reclaim.
    @Test func stampLeavesAHolderBackedRowAlone() async throws {
        let db = try TBDDatabase(inMemory: true)
        let worktree = try await db.worktrees.createScratch(
            name: "wt", displayName: "wt",
            path: "/tmp/tbd-nonexistent-\(UUID().uuidString)", tmuxServer: "tbd-test")
        // `childPID: 0` deliberately: it is the one pid no disposal signals, so
        // the fixture cannot name a process this shared box is really running.
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            label: "claude", claudeSessionID: "sess-1", kind: .claude,
            transport: .holder, holderPID: 9101, childPID: 0)

        let changed = try await db.terminals.stampSessionExited(
            id: terminal.id, reportedIncarnationID: nil, at: stamp)

        #expect(!changed)
        let row = try #require(try await db.terminals.get(id: terminal.id))
        #expect(row.hibernatedAt == nil)
        #expect(row.hibernateReason == nil)
    }

    @Test func clearRetractsOnlyAnExitStamp() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeTerminal(db)
        try await db.terminals.stampSessionExited(
            id: terminal.id, reportedIncarnationID: nil, at: stamp)

        #expect(try await db.terminals.clearSessionExitStamp(id: terminal.id))
        let row = try #require(try await db.terminals.get(id: terminal.id))
        #expect(row.hibernatedAt == nil)
        #expect(row.hibernateReason == nil)
    }

    /// The mirror negative: a deliberate park survives a SessionStart. Claude
    /// Code fires SessionStart on `/clear` inside a live process too, and a
    /// blanket un-park there would silently undo the operator's own gesture.
    @Test func clearLeavesADeliberateParkAlone() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeTerminal(db)
        try await db.terminals.setHibernated(
            id: terminal.id, sessionID: "sess-1", reason: .manual, at: stamp)

        #expect(try await db.terminals.clearSessionExitStamp(id: terminal.id) == false)
        let row = try #require(try await db.terminals.get(id: terminal.id))
        #expect(row.hibernatedAt == stamp)
        #expect(row.hibernateReason == .manual)
    }
}
