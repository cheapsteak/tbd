import Foundation
import DaemonTestSupport
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// Tier 3 (docs/specs/2026-07-24-test-hardening-design.md §3): the reconcile
// test below runs the `tmux` on PATH to start an actual tmux server on a unique
// socket, as an earlier build of TBD did. That external process is what makes
// it tier 3 — the rest of `WorktreeLifecycleTests` stays in `TBDDaemonTests`
// because it injects the leftover-tmux probe and touches nothing outside the
// process.

/// Runs one `tmux -L <server>` command through `/usr/bin/env`, so the binary
/// comes from PATH, and returns its stdout. Throws on a non-zero exit.
private func tmux(_ server: String, _ arguments: [String]) async throws -> String {
    let outcome = try await runBoundedProcess(
        executable: "/usr/bin/env",
        arguments: ["tmux", "-L", server] + arguments,
        currentDirectory: nil,
        timeout: .seconds(15))
    guard case .completed(let status, let stdout, _) = outcome, status == 0 else {
        throw TmuxCommandFailed(arguments: arguments, outcome: "\(outcome)")
    }
    return String(decoding: stdout, as: UTF8.self)
}

/// Whether a tmux server answers on `server`'s socket.
private func tmuxServerIsRunning(_ server: String) async -> Bool {
    (try? await tmux(server, ["has-session"])) != nil
}

/// Parses `#{window_id} #{pane_id}` output into the IDs an earlier build
/// recorded on a terminal row.
private func tmuxWindow(fromFormatOutput output: String) throws -> (windowID: String, paneID: String) {
    let fields = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
    guard fields.count == 2 else { throw TmuxCommandFailed(arguments: [], outcome: output) }
    return (String(fields[0]), String(fields[1]))
}

private struct TmuxCommandFailed: Error, CustomStringConvertible {
    let arguments: [String]
    let outcome: String
    var description: String { "tmux \(arguments) failed: \(outcome)" }
}

/// A tmux server an earlier build started, judged end to end through
/// `reconcile(repoID:)` and the production socket probe
/// (`LeftoverTmuxServerProbe`), against a real tmux server's real socket.
///
/// While the server runs, reconcile leaves its rows live: TBD can neither
/// reach nor stop those sessions. Once the server is gone (a reboot, or
/// `tmux kill-server`), the rows are PARKED (resumable Claude) or deleted
/// (plain shell) — never recreated, and the dead server stays dead (#284).
///
/// This is the one test that proves the probe's socket path is where tmux
/// really puts its socket: the daemon and the tmux client share an
/// environment, so both resolve `TMUX_TMPDIR` the same way.
@Test func testReconcileRebootParksClaudeAndDeletesShell() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    // The production probe, as the daemon builds it.
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(), hooks: HookResolver(),
        leftoverTmuxProbe: .production()
    )

    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "acme", defaultBranch: "main"
    )
    let serverName = TmuxServerName.forRepoPath(repo.path)

    // A worktree whose path == the repo path is reported by `git worktree
    // list`, so reconcile will not archive it as missing.
    let wt = try await db.worktrees.create(
        repoID: repo.id, name: "wt", branch: "main",
        path: repoDir.path, tmuxServer: serverName
    )

    // Start a real server + two real windows, recording their actual IDs so the
    // terminal rows look exactly like a session an earlier build left running.
    let format = "#{window_id} #{pane_id}"
    let sessionOutput = try await tmux(serverName, [
        "new-session", "-d", "-s", "main", "-c", repoDir.path, "-P", "-F", format, "sleep 60",
    ])
    let claudeWindow: (windowID: String, paneID: String)
    let shellWindow: (windowID: String, paneID: String)
    do {
        claudeWindow = try tmuxWindow(fromFormatOutput: sessionOutput)
        let windowOutput = try await tmux(serverName, [
            "new-window", "-t", "main", "-c", repoDir.path, "-P", "-F", format, "sleep 60",
        ])
        shellWindow = try tmuxWindow(fromFormatOutput: windowOutput)
    } catch {
        _ = try? await tmux(serverName, ["kill-server"])
        throw error
    }

    let sessionID = UUID().uuidString
    let claudeTerminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: claudeWindow.windowID, tmuxPaneID: claudeWindow.paneID,
        label: "claude", claudeSessionID: sessionID, kind: .claude
    )
    let shellTerminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: shellWindow.windowID, tmuxPaneID: shellWindow.paneID
    )

    // The server is running: both rows stay live and untouched.
    do {
        try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog())
    } catch {
        _ = try? await tmux(serverName, ["kill-server"])
        throw error
    }
    let claudeWhileRunning = try await db.terminals.get(id: claudeTerminal.id)
    let shellWhileRunning = try await db.terminals.get(id: shellTerminal.id)
    #expect(claudeWhileRunning?.isParked == false,
            "a session whose tmux server is running must not be parked")
    #expect(shellWhileRunning != nil,
            "a shell whose tmux server is running must not be deleted")

    // Simulate the reboot: the whole server is gone. tmux leaves its socket
    // file behind, so the probe reads a refused connect, not a missing path.
    _ = try await tmux(serverName, ["kill-server"])
    let aliveAfterKill = await tmuxServerIsRunning(serverName)
    #expect(!aliveAfterKill, "precondition: server must be gone to model a reboot")

    do {
        try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog())
    } catch {
        _ = try? await tmux(serverName, ["kill-server"])
        throw error
    }

    let claudeAfter = try await db.terminals.get(id: claudeTerminal.id)
    let shellAfter = try await db.terminals.get(id: shellTerminal.id)
    // Was the dead server resurrected by an eager recreate? (The bug.)
    let serverAliveAfter = await tmuxServerIsRunning(serverName)
    _ = try? await tmux(serverName, ["kill-server"])

    // Resumable Claude session: parked, not recreated, not deleted.
    #expect(claudeAfter != nil, "claude terminal must NOT be deleted on reboot")
    #expect(claudeAfter?.isParked == true, "claude terminal must be parked (resumable via wake)")
    #expect(claudeAfter?.hibernateReason == .recovery)
    #expect(claudeAfter?.claudeSessionID == sessionID, "session ID must be preserved for on-demand resume")
    #expect(claudeAfter?.tmuxWindowID == claudeWindow.windowID,
            "reboot must not recreate the claude window (no eager `claude --resume`)")

    // Plain shell: nothing resumable, deleted.
    #expect(shellAfter == nil, "shell terminal with no session must be deleted on reboot")

    // CRUCIAL #284 invariant: reconcile must not have bootstrapped the dead
    // server to recreate windows. No mass `claude --resume` storm on reboot.
    #expect(!serverAliveAfter,
            "reconcile must leave the dead server dead — no eager mass-recreate (#284)")
}
