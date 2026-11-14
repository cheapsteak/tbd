import Foundation
import GRDB
import DaemonTestSupport
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

    @Test func configFlagDefaultsOnAndRoundtrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().autoCloseSetupEnabled == true,
                "auto_close_setup_enabled must default ON")
        try await db.config.setAutoCloseSetup(enabled: false)
        #expect(try await db.config.get().autoCloseSetupEnabled == false)
        try await db.config.setAutoCloseSetup(enabled: true)
        #expect(try await db.config.get().autoCloseSetupEnabled == true)
    }

    // MARK: - Flag OFF: the plain setup command, no marker, no watcher

    @Test func flagOffSpawnsPlainShellWrappedSetupAndNoWatcher() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAutoCloseSetup(enabled: false)
        let holder = FakeHolderLaunch()
        let lifecycle = makeLifecycle(db: db, holder: holder)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installHook(named: "setup", repoDir: repoDir)

        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        let setup = try #require(terminals.first { $0.label == TerminalLabel.setup })

        // The setup tab runs the plain shellWrapped hook — no marker
        // machinery in the command.
        let setupBody = try #require(holder.launch(for: setup.id)?.commandLine)
        #expect(setupBody.contains(".worktree-hooks/setup"))
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

    // MARK: - Never chosen: the shipped default arms the wrapper

    /// Nobody touched the toggle, so `auto_close_setup_enabled` is NULL and
    /// the shipped default (on) decides: the setup window runs the
    /// marker-writing wrapper and a watcher is armed. A failed exit is written
    /// so the watcher finishes inside the test.
    @Test func neverChosenSpawnsTheAutoCloseWrapper() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let holder = FakeHolderLaunch()
        let lifecycle = makeLifecycle(db: db, timeout: 5, holder: holder)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installHook(named: "setup", repoDir: repoDir)

        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        let setup = try #require(terminals.first { $0.label == TerminalLabel.setup })

        let setupBody = try #require(holder.launch(for: setup.id)?.commandLine)
        #expect(setupBody.contains(".worktree-hooks/setup"))
        #expect(setupBody.contains("runtime/setup"),
                "a never-chosen flag must arm the marker-writing wrapper")
        #expect(setupBody.contains("if [ $__tbd_rc -ne 0 ]"))

        try writeSetupMarker(worktreeID: wt.id, exitCode: 3)
        let markerPath = WorktreeLifecycle.setupMarkerPath(worktreeID: wt.id)
        try await waitFor("setup marker consumed") {
            !FileManager.default.fileExists(atPath: markerPath)
        }
        #expect(try await db.terminals.get(id: setup.id) != nil,
                "a nonzero exit must keep the setup tab open")
    }

    // MARK: - Flag ON: clean exit closes the tab, failure keeps it

    @Test func flagOnCleanExitClosesSetupTab() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAutoCloseSetup(enabled: true)
        let holder = FakeHolderLaunch()
        let lifecycle = makeLifecycle(db: db, timeout: 5, holder: holder)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installHook(named: "setup", repoDir: repoDir)

        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        #expect(terminals.count == 2)
        let setup = try #require(terminals.first { $0.label == TerminalLabel.setup })
        let primary = try #require(terminals.first { $0.id != setup.id })

        // The setup tab runs the marker-writing wrapper.
        let setupBody = try #require(holder.launch(for: setup.id)?.commandLine)
        #expect(setupBody.contains(".worktree-hooks/setup"))
        #expect(setupBody.contains("runtime/setup"))
        #expect(setupBody.contains("if [ $__tbd_rc -ne 0 ]"))

        // The spawn double never runs the hook — stand in for its clean exit.
        // (The spawn deleted any stale marker, so write AFTER create returns.)
        try writeSetupMarker(worktreeID: wt.id, exitCode: 0)
        // Wait on the LAST write of the teardown, not the first. The watcher's
        // `closeHookTerminal`
        // (Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+PreSession.swift:468-474)
        // deletes the terminal row, then the tab row, and only THEN reads and
        // rewrites the persisted tab order — three separate awaits with
        // suspension points between them. A wait whose condition is "the row is
        // gone" can therefore return while the stored order still contains the
        // setup tab, which is exactly what the assertion below checks; that
        // intermediate state is what turned this test red in CI in 0.5 s. The
        // condition below is the conjunction, so the wait cannot outrun the
        // prune.
        try await waitFor("setup tab pruned from the stored tab order") {
            guard let order = try? await db.worktrees.getTabOrder(worktreeID: wt.id)
            else { return false }
            let rowGone = (try? await db.terminals.get(id: setup.id)) == nil
            return rowGone && !order.contains(setup.id)
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
        // The closed tab's holder and job were handed to the registry's
        // teardown, not left running behind a deleted row.
        let abandoned = holder.abandonments.map(\.terminalID)
        #expect(abandoned.contains(setup.id))
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
        // processed the failure outcome — and here it is also the watcher's
        // LAST write: `finishAutoCloseSetup`
        // (Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+SetupAutoClose.swift:58-70)
        // removes the marker before the switch and the nonzero-exit branch only
        // logs, so no later write can invalidate the assertions below. (Contrast
        // `flagOnCleanExitClosesSetupTab`, whose branch writes three more times.)
        try await waitFor("setup marker consumed") {
            !FileManager.default.fileExists(atPath: markerPath)
        }

        #expect(try await db.terminals.get(id: setup.id) != nil,
                "a nonzero exit must keep the setup tab open")
        #expect(try await db.worktrees.getTabOrder(worktreeID: wt.id) == orderBefore,
                "a failed hook must leave the tab order untouched")
    }

    @Test func flagOnWithoutHookSpawnsNoSetupTab() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAutoCloseSetup(enabled: true)
        let holder = FakeHolderLaunch()
        let lifecycle = makeLifecycle(db: db, holder: holder)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
        // No hook resolves → no "Setup" tab opens even with the flag on, so
        // nothing runs the marker machinery and no watcher is armed.
        let commandLines = holder.launches.compactMap(\.commandLine)
        #expect(!commandLines.isEmpty, "the primary spawned through the double")
        #expect(!commandLines.contains { $0.contains("runtime/setup") })
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        #expect(!terminals.contains { $0.label == TerminalLabel.setup })
    }
}
}
