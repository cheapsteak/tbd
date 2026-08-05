import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 3 — a real tmux server, real panes, and the real `terminal.send`
/// handler.
///
/// The dry-run suite proves the classification; this proves the facts the
/// classification rests on, against the tmux actually installed here:
///
///  - `send-keys` into a `remain-on-exit` dead pane exits **0**, so tmux's own
///    status can never be the signal — the send must consult the pane. This is
///    asserted directly, so the day tmux changes that behavior the test says so.
///  - `list-panes -t %missing` exits non-zero, which is how a vanished
///    coordinate becomes an answer rather than a hang.
///  - `createWindow` stamps `@tbd_terminal_id`, and `respawn-window -k` leaves a
///    `#{pane_start_command}` that still carries the planted `TBD_TERMINAL_ID` —
///    the fallback the unstamped panes of today depend on.
@Suite("terminal.send target check (live tmux)", .serialized)
struct TerminalSendTargetCheckLiveTests {

    // MARK: - tmux helpers

    @discardableResult
    private func tmux(_ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux"] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    private func tmuxCapture(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux"] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// Bounded wait for a pane to report `pane_dead=1`.
    private func awaitPaneDead(server: String, paneID: String) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if tmuxCapture(["-L", server, "list-panes", "-t", paneID, "-F", "#{pane_dead}"]) == "1" {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        struct NeverDied: Error, CustomStringConvertible {
            let description: String
        }
        throw NeverDied(description: """
            pane \(paneID) never reached pane_dead=1 within 15s — observed \
            \(tmuxCapture(["-L", server, "list-panes", "-t", paneID, "-F", "#{pane_dead}"]) ?? "no answer")
            """)
    }

    // MARK: - Router fixture

    private struct Fixture {
        let router: RPCRouter
        let db: TBDDatabase
        let logPath: String
        let worktree: Worktree
    }

    private func makeFixture(server: String) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-send-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logPath = directory.appendingPathComponent("actuations.jsonl").path

        let db = try TBDDatabase(inMemory: true)
        let tmux = TmuxManager()
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            startTime: Date(),
            actuationLog: ActuationLog(path: logPath))
        let repo = try await db.repos.create(
            path: directory.appendingPathComponent("repo").path,
            displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "acme-wt", branch: "main",
            path: directory.path, tmuxServer: server)
        return Fixture(router: router, db: db, logPath: logPath, worktree: worktree)
    }

    private func send(_ fixture: Fixture, terminalID: UUID) async throws -> RPCResponse {
        await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(terminalID: terminalID, text: "hello", submit: true)))
    }

    private func lastOutcome(at path: String) throws -> [String: Any] {
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        let line = try #require(contents.split(separator: "\n").last)
        return try #require(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    // MARK: - Tests

    @Test("a dead remain-on-exit pane errors, though raw send-keys into it exits 0")
    func deadPaneErrors() async throws {
        guard await TmuxVersion.detect() != nil else { return }
        let server = "tbd-test-send-dead-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }

        // rc-free bootstrap: the pane command IS the whole session.
        #expect(tmux(["-L", server, "new-session", "-d", "-s", "main",
                      "-x", "80", "-y", "24", "/bin/sh", "-c", "sleep 300"]) == 0)
        #expect(tmux(["-L", server, "set-option", "-g", "remain-on-exit", "on"]) == 0)
        let created = try #require(
            tmuxCapture(["-L", server, "new-window", "-t", "main", "-PF", "#{pane_id}",
                         "/bin/sh", "-c", "exit 0"]),
            "could not create the short-lived window")
        try await awaitPaneDead(server: server, paneID: created)

        // The lie this whole slice exists to stop believing.
        #expect(tmux(["-L", server, "send-keys", "-t", created, "typed", "Enter"]) == 0)

        let fixture = try await makeFixture(server: server)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: created)

        let response = try await send(fixture, terminalID: terminal.id)
        #expect(!response.success)
        #expect(response.error?.contains("dead") == true)
        let outcome = try lastOutcome(at: fixture.logPath)
        #expect(outcome["result"] as? String == "refused")
        #expect(outcome["reason"] as? String == "not-eligible")
    }

    @Test("a pane coordinate tmux cannot resolve is refused as not-found")
    func missingPaneRefused() async throws {
        guard await TmuxVersion.detect() != nil else { return }
        let server = "tbd-test-send-gone-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }
        #expect(tmux(["-L", server, "new-session", "-d", "-s", "main",
                      "-x", "80", "-y", "24", "/bin/sh", "-c", "sleep 300"]) == 0)

        // The property the classification rests on: list-panes FAILS here,
        // where `display-message -p` would have printed an empty line and
        // exited 0.
        #expect(tmux(["-L", server, "list-panes", "-t", "%999", "-F", "#{pane_dead}"]) != 0)

        let fixture = try await makeFixture(server: server)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@9", tmuxPaneID: "%999")

        let response = try await send(fixture, terminalID: terminal.id)
        #expect(!response.success)
        let outcome = try lastOutcome(at: fixture.logPath)
        #expect(outcome["result"] as? String == "refused")
        #expect(outcome["reason"] as? String == "not-found")
    }

    @Test("a live pane belonging to another terminal is refused, naming both ids")
    func mismatchedPaneRefused() async throws {
        guard await TmuxVersion.detect() != nil else { return }
        let server = "tbd-test-send-mismatch-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }
        #expect(tmux(["-L", server, "new-session", "-d", "-s", "main",
                      "-x", "80", "-y", "24", "/bin/sh", "-c", "sleep 300"]) == 0)

        let stranger = UUID()
        let created = try #require(
            tmuxCapture(["-L", server, "new-window", "-t", "main", "-PF", "#{pane_id}",
                         "/bin/sh", "-c", "sleep 300"]))
        #expect(tmux(TmuxManager.setPaneTerminalIDCommand(
            server: server, target: created, terminalID: stranger.uuidString)) == 0)

        let fixture = try await makeFixture(server: server)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: created)

        let response = try await send(fixture, terminalID: terminal.id)
        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.contains(stranger.uuidString))
        #expect(error.contains(terminal.id.uuidString))
        let outcome = try lastOutcome(at: fixture.logPath)
        #expect(outcome["result"] as? String == "refused")
        #expect(outcome["reason"] as? String == "target-mismatch")
    }

    @Test("a live pane carrying no identity still sends")
    func unresolvablePaneSends() async throws {
        guard await TmuxVersion.detect() != nil else { return }
        let server = "tbd-test-send-anon-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }
        #expect(tmux(["-L", server, "new-session", "-d", "-s", "main",
                      "-x", "80", "-y", "24", "/bin/sh", "-c", "sleep 300"]) == 0)

        // Spawned outside TBD: no pane option, no planted TBD_TERMINAL_ID.
        let created = try #require(
            tmuxCapture(["-L", server, "new-window", "-t", "main", "-PF", "#{pane_id}",
                         "/bin/sh", "-c", "sleep 300"]))

        let fixture = try await makeFixture(server: server)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: created)

        let response = try await send(fixture, terminalID: terminal.id)
        #expect(response.success)
        #expect(try lastOutcome(at: fixture.logPath)["result"] as? String == "dispatched")
    }

    /// `list-panes -t %N` lists every pane in `%N`'s **window** — `%N` only
    /// selects the window. So a user who splits a TBD window by hand makes the
    /// consultation return two lines, and reading the first one would answer
    /// with a stranger's identity and refuse a perfectly healthy send. This is
    /// asserted against real tmux because the multi-line shape is tmux's
    /// behavior, not TBD's, and a dry-run fixture cannot witness it.
    @Test("a hand-split window does not make the send read the wrong pane")
    func splitWindowDoesNotConfuseTheTarget() async throws {
        guard await TmuxVersion.detect() != nil else { return }
        let server = "tbd-test-send-split-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }

        let manager = TmuxManager()
        let cwd = FileManager.default.temporaryDirectory.path
        try await manager.ensureServer(server: server, session: "main", cwd: cwd)
        let terminalID = UUID()
        let window = try await manager.createWindow(
            server: server, session: "main", cwd: cwd, shellCommand: "sleep 300",
            env: ["TBD_TERMINAL_ID": terminalID.uuidString])

        // The user splits the tab. The new pane is not TBD's and carries no id.
        let sibling = try #require(
            tmuxCapture(["-L", server, "split-window", "-t", window.windowID, "-d",
                         "-P", "-F", "#{pane_id}", "/bin/sh", "-c", "sleep 300"]))
        #expect(sibling != window.paneID)
        // Both panes really are in the answer — otherwise this proves nothing.
        let listed = try #require(
            tmuxCapture(["-L", server, "list-panes", "-t", window.paneID, "-F", "#{pane_id}"]))
        #expect(listed.split(separator: "\n").count == 2)

        // TBD's pane still answers for itself, and the stranger answers for its.
        #expect(try await manager.paneSendTarget(server: server, paneID: window.paneID)
            == .live(terminalID: terminalID.uuidString))
        #expect(try await manager.paneSendTarget(server: server, paneID: sibling)
            == .live(terminalID: nil))

        let fixture = try await makeFixture(server: server)
        let terminal = try await fixture.db.terminals.create(
            id: terminalID, worktreeID: fixture.worktree.id,
            tmuxWindowID: window.windowID, tmuxPaneID: window.paneID)
        #expect(try await send(fixture, terminalID: terminal.id).success)
        #expect(try lastOutcome(at: fixture.logPath)["result"] as? String == "dispatched")
    }

    @Test("createWindow stamps the pane, and the stamped pane accepts its own sends")
    func createWindowStampsAndSends() async throws {
        guard await TmuxVersion.detect() != nil else { return }
        let server = "tbd-test-send-stamp-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }

        let manager = TmuxManager()
        let cwd = FileManager.default.temporaryDirectory.path
        try await manager.ensureServer(server: server, session: "main", cwd: cwd)
        let terminalID = UUID()
        let window = try await manager.createWindow(
            server: server, session: "main", cwd: cwd, shellCommand: "sleep 300",
            env: ["TBD_TERMINAL_ID": terminalID.uuidString])

        #expect(tmuxCapture(["-L", server, "list-panes", "-t", window.paneID,
                             "-F", "#{@tbd_terminal_id}"]) == terminalID.uuidString)

        let target = try await manager.paneSendTarget(server: server, paneID: window.paneID)
        #expect(target == .live(terminalID: terminalID.uuidString))
    }

    /// The fallback's coverage of the in-place profile swap depends on this:
    /// `respawn-window -k` must leave a start command carrying the NEW env, or a
    /// swapped pane would answer with a stale identity.
    @Test("respawn-window leaves a start command carrying the planted terminal id")
    func respawnRefreshesStartCommand() async throws {
        guard await TmuxVersion.detect() != nil else { return }
        let server = "tbd-test-send-respawn-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }

        let manager = TmuxManager()
        let cwd = FileManager.default.temporaryDirectory.path
        try await manager.ensureServer(server: server, session: "main", cwd: cwd)
        let window = try await manager.createWindow(
            server: server, session: "main", cwd: cwd, shellCommand: "sleep 300")

        // Nothing planted at spawn: the pane starts anonymous.
        #expect(try await manager.paneSendTarget(server: server, paneID: window.paneID)
            == .live(terminalID: nil))

        let terminalID = UUID()
        try await manager.respawnWindow(
            server: server, windowID: window.windowID, cwd: cwd, shellCommand: "sleep 300",
            env: ["TBD_TERMINAL_ID": terminalID.uuidString])

        let startCommand = try #require(
            tmuxCapture(["-L", server, "list-panes", "-t", window.paneID,
                         "-F", "#{pane_start_command}"]))
        #expect(startCommand.contains("TBD_TERMINAL_ID='\(terminalID.uuidString)'"))
        #expect(TmuxManager.resolvePaneTerminalID(paneOption: "", startCommand: startCommand)
            == terminalID.uuidString)
        // And the stamp is refreshed too, so both sources agree.
        #expect(try await manager.paneSendTarget(server: server, paneID: window.paneID)
            == .live(terminalID: terminalID.uuidString))
    }
}
