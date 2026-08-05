import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

extension TBDHomeSerialized {

    /// Tier 2 — dry-run tmux, a real (temp-directory) actuation log, and a real
    /// `TBD_HOME` because a desk session is a scratch worktree.
    ///
    /// The Watch Desk rail acts on sessions with nobody having asked, and two of
    /// those acts reach no logged lifecycle of their own: `spawnDeskTerminal`
    /// opens the judge session, and `closeDeskSession` kills its tmux windows
    /// directly. Both write their own worktree-named row on the
    /// `nightwatch-desk` rail with no `method`, and both skip their act when the
    /// record is unwritable.
    @Suite("Actuation log desk spawn/close wiring")
    struct ActuationLogDeskCloseWiringTests {

        // MARK: - Fixture

        private func makeLogPath() throws -> String {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "tbd-actuation-desk-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent("actuations.jsonl").path
        }

        /// A path that can never be opened: its parent is a regular file.
        private func makeUnwritablePath() throws -> String {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "tbd-actuation-blocked-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let blocker = directory.appendingPathComponent("blocker")
            try Data("not a directory".utf8).write(to: blocker)
            return blocker.appendingPathComponent("actuations.jsonl").path
        }

        private func rows(at path: String) throws -> [[String: Any]] {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                return []
            }
            return try contents
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { line in
                    try #require(
                        try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                }
        }

        /// Temp `TBD_HOME` + in-memory DB + a desk manager writing to `logPath`.
        /// Caller owns cleanup of `home` and restoring `priorTBDHome`.
        private func makeFixture(logPath: String) throws -> (
            db: TBDDatabase, manager: DeskSessionManager, home: URL, priorTBDHome: String?
        ) {
            let home = FileManager.default.temporaryDirectory
                .appendingPathComponent("tbd-desk-close-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let priorTBDHome = setTBDHome(home.path)

            let db = try TBDDatabase(inMemory: true)
            let manager = DeskSessionManager(
                db: db,
                lifecycle: WorktreeLifecycle(
                    db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
                    hooks: HookResolver()),
                tmux: TmuxManager(dryRun: true),
                skillDir: home.appendingPathComponent("skills/nightwatch").path,
                actuationLog: ActuationLog(path: logPath))
            return (db, manager, home, priorTBDHome)
        }

        // MARK: - The rail's own spawn row

        @Test("opening the desk session writes one spawn row on the nightwatch-desk rail")
        func spawnWritesSpawnRow() async throws {
            let logPath = try makeLogPath()
            let fixture = try makeFixture(logPath: logPath)
            defer {
                restoreTBDHome(fixture.priorTBDHome)
                try? FileManager.default.removeItem(at: fixture.home)
            }

            let desk = try await fixture.manager.ensureDeskSession(mode: .daywatch)

            let written = try rows(at: logPath)
            let spawns = written.filter { $0["kind"] as? String == "spawn" }
            #expect(spawns.count == 1)
            let request = try #require(spawns.first)
            #expect(request["method"] == nil)
            let actor = try #require(request["actor"] as? [String: Any])
            #expect(actor["kind"] as? String == "daemon")
            #expect(actor["rail"] as? String == "nightwatch-desk")
            let target = try #require(request["target"] as? [String: Any])
            #expect(target["worktree"] as? String == desk.id.uuidString)
            // The terminals mint inside `spawnPrimaryTerminals`, so there is
            // none to name at request time — as with `worktree.revive`.
            #expect(target["terminal"] == nil)

            let outcome = try #require(written.first {
                $0["confirms"] as? String == request["id"] as? String
            })
            #expect(outcome["result"] as? String == "dispatched")
            #expect(try await fixture.db.terminals.list(worktreeID: desk.id).isEmpty == false)
        }

        @Test("an unwritable record skips the desk spawn — the desk opens with no session")
        func unwritableRecordSkipsDeskSpawn() async throws {
            let fixture = try makeFixture(logPath: try makeUnwritablePath())
            defer {
                restoreTBDHome(fixture.priorTBDHome)
                try? FileManager.default.removeItem(at: fixture.home)
            }

            // The worktree still gets created — a failed desk spawn has always
            // been best-effort — but nothing was spawned into it.
            let desk = try await fixture.manager.ensureDeskSession(mode: .daywatch)
            #expect(try await fixture.db.terminals.list(worktreeID: desk.id).isEmpty)
        }

        // MARK: - The rail's own dispose row

        @Test("closing the desk writes one dispose row on the nightwatch-desk rail")
        func closeWritesDisposeRow() async throws {
            let logPath = try makeLogPath()
            let fixture = try makeFixture(logPath: logPath)
            defer {
                restoreTBDHome(fixture.priorTBDHome)
                try? FileManager.default.removeItem(at: fixture.home)
            }

            let desk = try await fixture.manager.ensureDeskSession(mode: .daywatch)
            await fixture.manager.closeDeskSession()

            let written = try rows(at: logPath)
            let disposes = written.filter { $0["kind"] as? String == "dispose" }
            #expect(disposes.count == 1)
            let request = try #require(disposes.first)
            // Daemon-internal: no RPC carried this, so no method.
            #expect(request["method"] == nil)
            let actor = try #require(request["actor"] as? [String: Any])
            #expect(actor["kind"] as? String == "daemon")
            #expect(actor["rail"] as? String == "nightwatch-desk")
            let target = try #require(request["target"] as? [String: Any])
            #expect(target["worktree"] as? String == desk.id.uuidString)
            // One row for the whole desk, as `worktree.archive` records it — the
            // per-terminal kills are how the close carries that out.
            #expect(target["terminal"] == nil)

            let outcome = try #require(written.first {
                $0["confirms"] as? String == request["id"] as? String
            })
            #expect(outcome["result"] as? String == "dispatched")
            #expect(try await fixture.db.worktrees.get(id: desk.id)?.status == .archived)
        }

        @Test("an unwritable record skips the close — the desk stays live")
        func unwritableRecordSkipsClose() async throws {
            let fixture = try makeFixture(logPath: try makeUnwritablePath())
            defer {
                restoreTBDHome(fixture.priorTBDHome)
                try? FileManager.default.removeItem(at: fixture.home)
            }

            let desk = try await fixture.manager.ensureDeskSession(mode: .daywatch)
            // The same unwritable record already refused the spawn, so seed the
            // terminal row the close would otherwise tear down.
            _ = try await fixture.db.terminals.create(
                worktreeID: desk.id, tmuxWindowID: "@1", tmuxPaneID: "%1")

            await fixture.manager.closeDeskSession()

            // Nothing was torn down: the worktree is still active and still owns
            // its terminal rows.
            #expect(try await fixture.db.worktrees.get(id: desk.id)?.status == .active)
            #expect(try await fixture.db.terminals.list(worktreeID: desk.id).count == 1)
        }

        /// A close that had gone through would archive the desk, and the recovery
        /// path deliberately excludes archived desks — so the next `ensure` would
        /// mint a second one. Getting the same id back is how the refusal shows.
        @Test("a skipped close leaves the same desk addressable")
        func skippedCloseKeepsDeskIdentity() async throws {
            let fixture = try makeFixture(logPath: try makeUnwritablePath())
            defer {
                restoreTBDHome(fixture.priorTBDHome)
                try? FileManager.default.removeItem(at: fixture.home)
            }

            let desk = try await fixture.manager.ensureDeskSession(mode: .daywatch)
            await fixture.manager.closeDeskSession()

            let again = try await fixture.manager.ensureDeskSession(mode: .daywatch)
            #expect(again.id == desk.id)
        }
    }
}
