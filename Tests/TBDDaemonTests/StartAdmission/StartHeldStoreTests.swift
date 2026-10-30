import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// `TerminalStore.setStartHeld` writes only onto the row the caller looked at.
@Suite("StartHeldStore")
struct StartHeldStoreTests {

    private func makeParkedClaude() async throws -> (TBDDatabase, Terminal) {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "acme-wt", branch: "main",
            path: FileManager.default.temporaryDirectory.path, tmuxServer: "tbd-acme")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.claudeCode, claudeSessionID: "session-1", kind: .claude)
        try await db.terminals.setHibernated(id: terminal.id, sessionID: "session-1")
        let parked = try #require(try await db.terminals.get(id: terminal.id))
        return (db, parked)
    }

    @Test("a row still parked under the observed incarnation gets the hold")
    func writesOntoTheObservedRow() async throws {
        let (db, parked) = try await makeParkedClaude()
        let wrote = try await db.terminals.setStartHeld(
            id: parked.id, reason: "busy", expectedIncarnationID: parked.sessionIncarnationID)
        #expect(wrote)
        let after = try #require(try await db.terminals.get(id: parked.id))
        #expect(after.startHeldReason == "busy")
        #expect(after.startHeldAt != nil)
    }

    @Test("a row woken while the command ran gets no hold")
    func wokenRowGetsNoHold() async throws {
        let (db, parked) = try await makeParkedClaude()
        try await db.terminals.clearHibernated(id: parked.id)
        let wrote = try await db.terminals.setStartHeld(
            id: parked.id, reason: "busy", expectedIncarnationID: parked.sessionIncarnationID)
        #expect(!wrote)
        let after = try #require(try await db.terminals.get(id: parked.id))
        #expect(after.startHeldReason == nil)
        #expect(after.startHeldAt == nil)
    }

    @Test("a row parked again under a new incarnation gets no hold")
    func reparkedRowGetsNoHold() async throws {
        let (db, parked) = try await makeParkedClaude()
        try await db.terminals.clearHibernated(id: parked.id)
        try await db.terminals.setHibernated(id: parked.id, sessionID: "session-1")
        let wrote = try await db.terminals.setStartHeld(
            id: parked.id, reason: "busy", expectedIncarnationID: parked.sessionIncarnationID)
        #expect(!wrote)
        let after = try #require(try await db.terminals.get(id: parked.id))
        #expect(after.startHeldReason == nil)
    }

    @Test("a session started by hand in an exited pane clears the hold")
    func handStartedSessionClearsTheHold() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "acme-wt", branch: "main",
            path: FileManager.default.temporaryDirectory.path, tmuxServer: "tbd-acme")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.claudeCode, claudeSessionID: "session-1", kind: .claude)
        #expect(try await db.terminals.stampSessionExited(
            id: terminal.id, reportedIncarnationID: terminal.sessionIncarnationID))
        #expect(try await db.terminals.setStartHeld(
            id: terminal.id, reason: "busy", expectedIncarnationID: terminal.sessionIncarnationID))

        #expect(try await db.terminals.clearSessionExitStamp(id: terminal.id))

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(after.hibernatedAt == nil)
        #expect(after.startHeldReason == nil)
        #expect(after.startHeldAt == nil)
    }

    @Test("recreating the window as a shell clears the hold")
    func recreatedShellClearsTheHold() async throws {
        let (db, parked) = try await makeParkedClaude()
        #expect(try await db.terminals.setStartHeld(
            id: parked.id, reason: "busy", expectedIncarnationID: parked.sessionIncarnationID))

        try await db.terminals.clearRecreated(id: parked.id)

        let after = try #require(try await db.terminals.get(id: parked.id))
        #expect(after.hibernatedAt == nil)
        #expect(after.startHeldReason == nil)
        #expect(after.startHeldAt == nil)
    }
}
