import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Dev server final output recorder")
struct DevServerFinalOutputRecorderTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func makeDB() async throws -> (TBDDatabase, UUID, String) {
        let historyDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("tbd-srv-recorder-\(UUID().uuidString)")
        let db = try TBDDatabase(inMemory: true, terminalHistoryDir: historyDir)
        let wt = try await db.worktrees.createScratch(
            name: "wt", displayName: "wt",
            path: "/tmp/tbd-nonexistent-\(UUID().uuidString)", tmuxServer: "tbd-srv-recorder")
        return (db, wt.id, historyDir)
    }

    @Test func aServerTabsExitSavesItsScreenAndCode() async throws {
        let (db, worktreeID, dir) = try await makeDB()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let tab = try await db.terminals.create(
            worktreeID: worktreeID, tmuxWindowID: "", tmuxPaneID: "", label: "Web app",
            kind: .shell, transport: .holder, serverName: "web")
        await DevServerFinalOutputRecorder(db: db, resolver: nil)
            .sessionEnded(terminalID: tab.id, status: .exited(code: 3)) { "BOOM\n" }
        let entry = try #require(try await db.terminalHistory.latestServerOutputs(worktreeID: worktreeID)["web"])
        #expect(entry.id == tab.id)
        #expect(entry.exitCode == 3)
    }

    @Test func anUnknownStatusSavesNoCode() async throws {
        let (db, worktreeID, dir) = try await makeDB()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let tab = try await db.terminals.create(
            worktreeID: worktreeID, tmuxWindowID: "", tmuxPaneID: "", kind: .shell,
            transport: .holder, serverName: "web")
        await DevServerFinalOutputRecorder(db: db, resolver: nil)
            .sessionEnded(terminalID: tab.id, status: .exitedStatusUnknown) { "x\n" }
        let entry = try #require(try await db.terminalHistory.latestServerOutputs(worktreeID: worktreeID)["web"])
        #expect(entry.exitCode == nil)
    }

    /// Ordinary tabs keep today's behavior: no entry at exit, and the screen
    /// is not even rendered.
    @Test func anOrdinaryTabsExitSavesNothing() async throws {
        let (db, worktreeID, dir) = try await makeDB()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let tab = try await db.terminals.create(
            worktreeID: worktreeID, tmuxWindowID: "", tmuxPaneID: "", kind: .shell, transport: .holder)
        let captures = Calls()
        await DevServerFinalOutputRecorder(db: db, resolver: nil)
            .sessionEnded(terminalID: tab.id, status: .exited(code: 0)) { captures.bump(); return "x\n" }
        #expect(captures.count == 0)
        #expect(try await db.terminalHistory.list(worktreeID: worktreeID).isEmpty)
    }

    @Test func aSessionWithNoRowSavesNothing() async throws {
        let (db, worktreeID, dir) = try await makeDB()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let captures = Calls()
        await DevServerFinalOutputRecorder(db: db, resolver: nil)
            .sessionEnded(terminalID: UUID(), status: .exited(code: 1)) { captures.bump(); return "x\n" }
        #expect(captures.count == 0)
        #expect(try await db.terminalHistory.list(worktreeID: worktreeID).isEmpty)
    }
}
