import Foundation
import GRDB
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// Nested under TBDHomeSerialized: these tests mutate the process-global
// `TBD_HOME` env var (via `isolateTBDHome` from PreSessionTestSupport.swift)
// to isolate hook resolution and the runtime/setup marker directory from the
// developer's real ~/tbd. See TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {
@Suite("Setup-tab auto-close")
struct AutoCloseSetupTests {

    /// Writes the completion marker the wrapped setup-hook command would write.
    private func writeSetupMarker(worktreeID: UUID, exitCode: Int) throws {
        let path = WorktreeLifecycle.setupMarkerPath(worktreeID: worktreeID)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try "\(exitCode)\n".write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Command wrapper + marker path

    @Test func setupMarkerPathRespectsTBDHome() {
        let (home, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let id = UUID()
        let path = WorktreeLifecycle.setupMarkerPath(worktreeID: id)
        #expect(path.hasPrefix(home.path))
        #expect(path.contains("runtime/setup"))
        #expect(path.hasSuffix(id.uuidString))
    }

    @Test func setupAutoCloseCommandEscapesAndExecsShellOnlyOnFailure() {
        let cmd = WorktreeLifecycle.setupAutoCloseCommand(
            hookPath: "/tmp/it's here/setup",
            runtimeDir: "/r/dir",
            markerPath: "/r/dir/marker",
            shell: "/bin/zsh"
        )
        // Quoting matches preSessionCommand's escaping.
        #expect(cmd.contains("'/tmp/it'\\''s here/setup'"))
        #expect(cmd.contains("__tbd_rc=$?"))
        #expect(cmd.contains("/bin/mkdir -p '/r/dir'"))
        #expect(cmd.contains("/bin/echo $__tbd_rc > '/r/dir/marker'"))
        // Failure path execs the interactive shell for debugging …
        #expect(cmd.hasSuffix("if [ $__tbd_rc -ne 0 ]; then exec /bin/zsh; fi"))
        // … but success must let the pane exit: no unconditional exec.
        #expect(!cmd.contains("fi; exec"))
    }

    // MARK: - Config flag plumbing

    @Test func configFlagDefaultsOffAndRoundtrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().autoCloseSetupEnabled == false,
                "auto_close_setup_enabled must default OFF")
        try await db.config.setAutoCloseSetup(enabled: true)
        #expect(try await db.config.get().autoCloseSetupEnabled == true)
        try await db.config.setAutoCloseSetup(enabled: false)
        #expect(try await db.config.get().autoCloseSetupEnabled == false)
    }

    // MARK: - Flag OFF (default): behavior byte-for-byte unchanged

    @Test func flagOffSpawnsPlainShellWrappedSetupAndNoWatcher() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let recorder = PreSessionRecordedCommands()
        let lifecycle = makeLifecycle(db: db, recorder: recorder)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installHook(named: "setup", repoDir: repoDir)

        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        let setup = try #require(terminals.first { $0.label == TerminalLabel.setup })

        // The setup window runs the plain shellWrapped hook — no marker
        // machinery in the command.
        let windowCalls = recorder.snapshot().filter { $0.contains("new-window") }
        let setupBody = try #require(
            windowCalls.compactMap(\.last).first { $0.contains(".worktree-hooks/setup") }
        )
        #expect(!setupBody.contains("runtime/setup"),
                "flag off must not wire the marker file into the setup command")
        #expect(!setupBody.contains("__tbd_rc"),
                "flag off must keep the pre-existing shellWrapped command")
        #expect(setupBody.contains("exec "))

        // No watcher was armed: a marker written by hand is never consumed
        // and the setup terminal stays.
        try writeSetupMarker(worktreeID: wt.id, exitCode: 0)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(try await db.terminals.get(id: setup.id) != nil,
                "flag off must never auto-close the setup tab")
        let markerPath = WorktreeLifecycle.setupMarkerPath(worktreeID: wt.id)
        #expect(FileManager.default.fileExists(atPath: markerPath),
                "flag off must not consume the marker (no watcher running)")
        try? FileManager.default.removeItem(atPath: markerPath)
    }

    // MARK: - Flag ON: clean exit closes the tab, failure keeps it

    @Test func flagOnCleanExitClosesSetupTab() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAutoCloseSetup(enabled: true)
        let recorder = PreSessionRecordedCommands()
        let lifecycle = makeLifecycle(db: db, recorder: recorder, timeout: 5)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installHook(named: "setup", repoDir: repoDir)

        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        #expect(terminals.count == 2)
        let setup = try #require(terminals.first { $0.label == TerminalLabel.setup })
        let primary = try #require(terminals.first { $0.id != setup.id })

        // The setup window runs the marker-writing wrapper.
        let windowCalls = recorder.snapshot().filter { $0.contains("new-window") }
        let setupBody = try #require(
            windowCalls.compactMap(\.last).first { $0.contains(".worktree-hooks/setup") }
        )
        #expect(setupBody.contains("runtime/setup"))
        #expect(setupBody.contains("if [ $__tbd_rc -ne 0 ]"))

        // dryRun tmux never runs the hook — stand in for its clean exit.
        // (The spawn deleted any stale marker, so write AFTER create returns.)
        try writeSetupMarker(worktreeID: wt.id, exitCode: 0)
        try await waitFor("setup terminal auto-close") {
            (try? await db.terminals.get(id: setup.id)) == nil
        }

        #expect(try await db.terminals.get(id: setup.id) == nil,
                "exit 0 must delete the setup terminal row")
        let order = try await db.worktrees.getTabOrder(worktreeID: wt.id)
        #expect(!order.contains(setup.id),
                "the closed setup tab must be pruned from the stored tab order")
        #expect(order.first == primary.id)
        #expect(try await db.worktrees.getActiveTabID(worktreeID: wt.id) == primary.id)
        let markerPath = WorktreeLifecycle.setupMarkerPath(worktreeID: wt.id)
        #expect(!FileManager.default.fileExists(atPath: markerPath), "marker must be consumed")
    }

    @Test func flagOnFailureKeepsSetupTab() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAutoCloseSetup(enabled: true)
        let lifecycle = makeLifecycle(db: db, timeout: 5)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installHook(named: "setup", repoDir: repoDir)

        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        let setup = try #require(terminals.first { $0.label == TerminalLabel.setup })
        let orderBefore = try await db.worktrees.getTabOrder(worktreeID: wt.id)

        try writeSetupMarker(worktreeID: wt.id, exitCode: 3)
        let markerPath = WorktreeLifecycle.setupMarkerPath(worktreeID: wt.id)
        // Marker consumption is the observable signal that the watcher
        // processed the failure outcome.
        try await waitFor("setup marker consumed") {
            !FileManager.default.fileExists(atPath: markerPath)
        }

        #expect(try await db.terminals.get(id: setup.id) != nil,
                "a nonzero exit must keep the setup tab open")
        #expect(try await db.worktrees.getTabOrder(worktreeID: wt.id) == orderBefore,
                "a failed hook must leave the tab order untouched")
    }

    @Test func flagOnWithoutHookSpawnsPlainShell() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAutoCloseSetup(enabled: true)
        let recorder = PreSessionRecordedCommands()
        let lifecycle = makeLifecycle(db: db, recorder: recorder)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
        // No hook resolves → hook-less "Setup" tab stays a plain shell even
        // with the flag on; no marker machinery, no watcher.
        let windowCalls = recorder.snapshot().filter { $0.contains("new-window") }
        #expect(!windowCalls.contains { ($0.last ?? "").contains("runtime/setup") })
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        #expect(terminals.contains { $0.label == TerminalLabel.setup })
    }
}
}
