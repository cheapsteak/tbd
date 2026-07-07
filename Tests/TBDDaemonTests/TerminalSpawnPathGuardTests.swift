import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

/// terminal.create / terminal.recreateWindow must fail loudly when the
/// worktree's directory is missing on disk — tmux's `-c` would otherwise
/// silently fall back to $HOME. One test per branch of the new guards.
extension RPCRouterTests {

    private func makeExistingDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-spawn-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func terminalCreateFailsWhenWorktreePathMissing() async throws {
        let missingPath = "/tmp/tbd-missing-\(UUID().uuidString)"
        let wt = try await db.worktrees.createScratch(
            name: "gone", displayName: "gone", path: missingPath, tmuxServer: "tbd-test")

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id)))

        #expect(!resp.success)
        #expect(resp.error?.contains(missingPath) == true)
        #expect(try await db.terminals.list(worktreeID: wt.id).isEmpty)
    }

    @Test func terminalCreateSucceedsWhenWorktreePathExists() async throws {
        let dir = try makeExistingDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wt = try await db.worktrees.createScratch(
            name: "here", displayName: "here", path: dir.path, tmuxServer: "tbd-test")

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id)))

        #expect(resp.success)
        #expect(try await db.terminals.list(worktreeID: wt.id).count == 1)
    }

    @Test func recreateWindowFailsWhenWorktreePathMissing() async throws {
        let missingPath = "/tmp/tbd-missing-\(UUID().uuidString)"
        let wt = try await db.worktrees.createScratch(
            name: "gone", displayName: "gone", path: missingPath, tmuxServer: "tbd-test")
        // Shell terminal: reaches the spawn path (Claude-resumable terminals
        // take the non-spawning park branch instead).
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "shell", kind: .shell)

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: terminal.id)))

        #expect(!resp.success)
        #expect(resp.error?.contains(missingPath) == true)
    }

    @Test func recreateWindowSucceedsWhenWorktreePathExists() async throws {
        let dir = try makeExistingDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wt = try await db.worktrees.createScratch(
            name: "here", displayName: "here", path: dir.path, tmuxServer: "tbd-test")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "shell", kind: .shell)

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: terminal.id)))

        #expect(resp.success)
    }
}
