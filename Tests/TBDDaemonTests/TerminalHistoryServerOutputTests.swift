import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Terminal history: dev server last output")
struct TerminalHistoryServerOutputTests {
    private struct Fixture {
        let db: TBDDatabase
        let historyDir: String
        let worktreeID: UUID
        func cleanup() { try? FileManager.default.removeItem(atPath: historyDir) }
        func serverTab(_ name: String = "web") async throws -> Terminal {
            try await db.terminals.create(
                worktreeID: worktreeID, tmuxWindowID: "", tmuxPaneID: "", label: name,
                kind: .shell, transport: .holder, serverName: name)
        }
    }

    private func makeFixture() async throws -> Fixture {
        let historyDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("tbd-srv-history-\(UUID().uuidString)")
        let db = try TBDDatabase(inMemory: true, terminalHistoryDir: historyDir)
        let wt = try await db.worktrees.createScratch(
            name: "wt", displayName: "wt",
            path: "/tmp/tbd-nonexistent-\(UUID().uuidString)", tmuxServer: "tbd-srv-history")
        return Fixture(db: db, historyDir: historyDir, worktreeID: wt.id)
    }

    @Test func recordServerExitSavesTheScreenAndStampsTheEntry() async throws {
        let f = try await makeFixture(); defer { f.cleanup() }
        let tab = try await f.serverTab()
        await f.db.terminalHistory.recordServerExit(
            terminal: tab, serverName: "web", capture: "BOOM\n", exitCode: 3)
        let latest = try await f.db.terminalHistory.latestServerOutputs(worktreeID: f.worktreeID)
        #expect(latest["web"]?.id == tab.id)
        #expect(latest["web"]?.exitCode == 3)
        let path = f.db.terminalHistory.contentPath(worktreeID: f.worktreeID, terminalID: tab.id)
        #expect(try String(contentsOfFile: path, encoding: .utf8).contains("BOOM"))
    }

    @Test func anUnobservedStatusStampsTheServerWithNoCode() async throws {
        let f = try await makeFixture(); defer { f.cleanup() }
        let tab = try await f.serverTab()
        await f.db.terminalHistory.recordServerExit(
            terminal: tab, serverName: "web", capture: nil, exitCode: nil)
        let entry = try #require(try await f.db.terminalHistory.latestServerOutputs(worktreeID: f.worktreeID)["web"])
        #expect(entry.exitCode == nil)
        #expect(entry.serverName == "web")
    }

    /// Review Focus 6: a stop deletes the row before it detaches, so an exit
    /// the stop caused, saved after that, must not re-attach anything.
    @Test func anExitWhoseTabIsGoneRecordsNoServerState() async throws {
        let f = try await makeFixture(); defer { f.cleanup() }
        let tab = try await f.serverTab()
        try await f.db.terminals.delete(id: tab.id)
        await f.db.terminalHistory.recordServerExit(
            terminal: tab, serverName: "web", capture: "killed\n", exitCode: 143)
        #expect(try await f.db.terminalHistory.latestServerOutputs(worktreeID: f.worktreeID).isEmpty)
        // The output itself is still kept as an ordinary Closed Terminals entry.
        #expect(try await f.db.terminalHistory.list(worktreeID: f.worktreeID).map(\.id) == [tab.id])
    }

    /// A later close of the same tab (stop, restart, archive) re-saves the
    /// entry through `persist`; that must not wipe the server fields.
    @Test func aLaterCloseKeepsTheServerFields() async throws {
        let f = try await makeFixture(); defer { f.cleanup() }
        let tab = try await f.serverTab()
        await f.db.terminalHistory.recordServerExit(
            terminal: tab, serverName: "web", capture: "first\n", exitCode: 3)
        await f.db.terminalHistory.recordOnClose(terminal: tab, capture: "second\n")
        let entry = try #require(try await f.db.terminalHistory.list(worktreeID: f.worktreeID).first)
        #expect(entry.serverName == "web")
        #expect(entry.exitCode == 3)
    }

    @Test func latestServerOutputsPicksTheNewestPerServer() async throws {
        let f = try await makeFixture(); defer { f.cleanup() }
        let older = try await f.serverTab(), newer = try await f.serverTab(), api = try await f.serverTab("api")
        for (tab, code) in [(older, Int32(1)), (newer, 2), (api, 7)] {
            await f.db.terminalHistory.recordServerExit(
                terminal: tab, serverName: tab.serverName!, capture: "x\n", exitCode: code)
        }
        let latest = try await f.db.terminalHistory.latestServerOutputs(worktreeID: f.worktreeID)
        #expect(latest["web"]?.id == newer.id)
        #expect(latest["api"]?.id == api.id)
    }

    @Test func detachClearsOnlyThatServerAndKeepsTheEntries() async throws {
        let f = try await makeFixture(); defer { f.cleanup() }
        let web = try await f.serverTab(), api = try await f.serverTab("api")
        await f.db.terminalHistory.recordServerExit(terminal: web, serverName: "web", capture: "w\n", exitCode: 1)
        await f.db.terminalHistory.recordServerExit(terminal: api, serverName: "api", capture: "a\n", exitCode: 2)
        await f.db.terminalHistory.detachServerOutput(worktreeID: f.worktreeID, serverName: "web")
        let latest = try await f.db.terminalHistory.latestServerOutputs(worktreeID: f.worktreeID)
        #expect(latest.keys.sorted() == ["api"])
        #expect(try await f.db.terminalHistory.list(worktreeID: f.worktreeID).count == 2)
    }
}
