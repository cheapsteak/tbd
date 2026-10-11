import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct TerminalStoreTransportTests {
    private func makeTmuxRow() async throws -> (TBDDatabase, Terminal) {
        let database = try TBDDatabase(inMemory: true)
        let repo = try await database.repos.create(
            path: "/tmp/transport-repo-\(UUID().uuidString)",
            displayName: "Transport", defaultBranch: "main")
        let worktree = try await database.worktrees.create(
            repoID: repo.id, name: "transport", branch: "transport",
            path: "/tmp/transport-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-transport")
        let terminal = try await database.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: "@7",
            tmuxPaneID: "%12",
            label: "claude",
            kind: .claude)
        return (database, terminal)
    }

    @Test func theWriteIsRejectedWhenTheRowMovedUnderTheCaller() async throws {
        let (database, terminal) = try await makeTmuxRow()
        let stale = TerminalReplacementSnapshot(terminal: terminal)
        // Someone else wins: the row is parked after the snapshot was taken.
        try await database.terminals.setHibernated(
            id: terminal.id, sessionID: "session-1", at: Date())

        let result = try await database.terminals.setParkedTransport(
            id: terminal.id, expectedState: stale, transport: .holder)

        #expect(result == nil)
        let reread = try await database.terminals.get(id: terminal.id)
        #expect(reread?.transport == .tmux)
        #expect(reread?.tmuxPaneID == "%12")
    }

    @Test func migratingBlanksTheTmuxCoordinates() async throws {
        let (database, terminal) = try await makeTmuxRow()

        let updated = try await database.terminals.setParkedTransport(
            id: terminal.id,
            expectedState: TerminalReplacementSnapshot(terminal: terminal),
            transport: .holder)

        #expect(updated?.transport == .holder)
        #expect(updated?.tmuxWindowID == "")
        #expect(updated?.tmuxPaneID == "")
        let reread = try await database.terminals.get(id: terminal.id)
        #expect(reread?.transport == .holder)
        #expect(reread?.tmuxPaneID == "")
    }
}
