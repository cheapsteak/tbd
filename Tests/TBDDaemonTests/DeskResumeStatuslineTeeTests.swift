import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// The statusline tee across a **wake from hibernation** — the gap phase 3 left
/// open, and the two resume paths where it stays open.
///
/// A wake reuses the same terminal row, so it reuses the same statusline
/// capture path. A desk woken without the tee would therefore keep reading a
/// capture whose mtime predates the resume: a stale denominator wearing a fresh
/// session's clothes.
///
/// Two independent things close that, and they are tested separately because
/// only one of them always holds. The wake site reads the row's own
/// `watch_desk_role`, which the desk spawn path stamps at create and the lease
/// store maintains — so a desk is recognizable from its first instant, lease or
/// no lease. But `release`/`revoke` NULL that column for the whole worktree, and
/// a hibernated desk is exactly what makes `DeskSessionManager` revoke, so the
/// role is not durable in every direction. The staleness is closed regardless:
/// resolving an overlay **without** a tee deletes the session's capture, so a
/// session that is not (re)installing one has nothing left to misread.
///
/// Nested under `TBDHomeSerialized`: the per-session overlay and the capture
/// path resolve through the process-global `TBD_HOME`.
extension TBDHomeSerialized {
@Suite struct DeskResumeStatuslineTeeTests {

    private struct Scratch {
        let home: URL
        let prior: String?
        init() {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("tbd-desk-resume-\(UUID().uuidString)", isDirectory: true)
            prior = setTBDHome(home.path)
        }
        func cleanUp() {
            restoreTBDHome(prior)
            try? FileManager.default.removeItem(at: home)
        }
    }

    private func isolatedConfigDirManager() -> ClaudeProfileConfigDirManager {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-desk-resume-claude-\(UUID().uuidString)", isDirectory: true)
        return ClaudeProfileConfigDirManager(
            baseDirectory: home.appendingPathComponent("profiles", isDirectory: true),
            hostBaseDirectory: home.appendingPathComponent("claude-host", isDirectory: true))
    }

    /// How a desk terminal came to be marked as one.
    private enum DeskMarking {
        /// Not a desk at all.
        case none
        /// Stamped by the spawn path at row creation, with no lease ever taken.
        /// This is the state a freshly-spawned desk is in for its whole life
        /// until `DeskSessionManager` first resolves a judge.
        case stampedAtCreate
        /// Written by the lease store, the way an acquired judge lease writes it.
        case byLease
    }

    /// A parked Claude terminal in a worktree whose path exists on disk (wake
    /// refuses to respawn into a missing directory).
    private func parkedTerminal(
        db: TBDDatabase, repoPath: String, desk: DeskMarking
    ) async throws -> Terminal {
        let repo = try await db.repos.create(
            path: repoPath, displayName: "repo", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main", path: repoPath,
            tmuxServer: "tbd-desk-resume")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", claudeSessionID: "sess-desk", kind: .claude,
            watchDeskRole: desk == .stampedAtCreate ? .readOnlyCoordinator : nil)
        if desk == .byLease {
            _ = try await db.watchDeskLeases.acquire(
                worktreeID: worktree.id, terminalID: terminal.id)
        }
        try await db.terminals.setHibernated(
            id: terminal.id, sessionID: "sess-desk", reason: .auto)
        return try #require(try await db.terminals.get(id: terminal.id))
    }

    private func statusLine(inOverlayFor sessionKey: String) -> [String: Any]? {
        let path = ClaudeHookOverlay.perSessionOverlayPath(sessionKey: sessionKey)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parsed["statusLine"] as? [String: Any]
    }

    private func makeRepoDir(_ scratch: Scratch) throws -> String {
        let path = scratch.home.appendingPathComponent("repo", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    // MARK: - Closed: hibernation wake

    @Test func wakingADeskReinstallsTheStatuslineTee() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await parkedTerminal(
            db: db, repoPath: try makeRepoDir(scratch), desk: .byLease)

        let coordinator = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            configDirManager: isolatedConfigDirManager(), actuationLog: makeTestActuationLog())
        _ = await coordinator.wake(terminalID: terminal.id)

        let entry = try #require(statusLine(inOverlayFor: terminal.id.uuidString),
                                 "a woken desk got no statusLine in its overlay")
        let command = try #require(entry["command"] as? String)
        #expect(command.contains(StatuslineTee.scriptPath))
        // The capture path is keyed by the terminal, which is exactly why the
        // stale-mtime problem existed: the woken desk reads the same file.
        #expect(command.contains(StatuslineTee.capturePath(sessionKey: terminal.id.uuidString)))
    }

    /// The role a desk actually has for most of its life.
    ///
    /// `DeskSessionManager` spawns a desk and only later resolves a judge, so a
    /// desk that has never held a lease is the ordinary case, not an edge one —
    /// and before the spawn path stamped the row, `watch_desk_role` was written
    /// by nothing but the lease store, so such a desk woke with no tee at all.
    @Test func wakingADeskThatNeverHeldALeaseReinstallsTheStatuslineTee() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await parkedTerminal(
            db: db, repoPath: try makeRepoDir(scratch), desk: .stampedAtCreate)
        #expect(try await db.watchDeskLeases.status(worktreeID: terminal.worktreeID) == nil,
                "the point of this test is a desk with no lease on record")

        let coordinator = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            configDirManager: isolatedConfigDirManager(), actuationLog: makeTestActuationLog())
        _ = await coordinator.wake(terminalID: terminal.id)

        let entry = try #require(statusLine(inOverlayFor: terminal.id.uuidString),
                                 "a woken desk got no statusLine in its overlay")
        #expect(try #require(entry["command"] as? String).contains(StatuslineTee.scriptPath))
    }

    @Test func wakingAnOrdinaryTerminalInstallsNoStatusline() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await parkedTerminal(
            db: db, repoPath: try makeRepoDir(scratch), desk: .none)

        let coordinator = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            configDirManager: isolatedConfigDirManager(), actuationLog: makeTestActuationLog())
        _ = await coordinator.wake(terminalID: terminal.id)

        // TBD's per-session `--settings` outranks the operator's `statusLine`
        // in every scope they can write, so a leak here would take over a slot
        // they own in every session they wake.
        #expect(statusLine(inOverlayFor: terminal.id.uuidString) == nil)
    }

    /// The row is where the desk fact has to land, because the wake path has
    /// nothing else to read. `WatchDeskLeaseStore.setRoles` is the only thing
    /// that used to write `watch_desk_role`, so a desk lived its whole
    /// pre-lease life — which is every desk, until `DeskSessionManager` first
    /// resolves a judge — with a nil role on its row.
    @Test func theDeskSpawnPathStampsTheRoleOnTheRowItCreates() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let db = try TBDDatabase(inMemory: true)
        let repoPath = try makeRepoDir(scratch)
        let repo = try await db.repos.create(
            path: repoPath, displayName: "repo", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main", path: repoPath,
            tmuxServer: "tbd-desk-spawn")
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
            hooks: HookResolver(), configDirManager: isolatedConfigDirManager())

        _ = try await lifecycle.spawnPrimaryTerminals(
            worktree: worktree, repo: repo, skipClaude: false,
            preSessionTerminalID: nil, watchDeskRole: .readOnlyCoordinator)

        let terminals = try await db.terminals.list(worktreeID: worktree.id)
        let primary = try #require(terminals.first { $0.kind == .claude })
        #expect(primary.watchDeskRole == .readOnlyCoordinator,
                "the desk spawn path did not write its role to the row it created")

        // And an ordinary spawn in the same shape leaves the column alone —
        // otherwise every session in the fleet would install the tee.
        let plainPath = scratch.home.appendingPathComponent("plain", isDirectory: true).path
        try FileManager.default.createDirectory(
            atPath: plainPath, withIntermediateDirectories: true)
        let plainWorktree = try await db.worktrees.create(
            repoID: repo.id, name: "plain", branch: "plain", path: plainPath,
            tmuxServer: "tbd-desk-spawn")
        _ = try await lifecycle.spawnPrimaryTerminals(
            worktree: plainWorktree, repo: repo, skipClaude: false, preSessionTerminalID: nil)
        let plain = try await db.terminals.list(worktreeID: plainWorktree.id)
        #expect(plain.allSatisfy { $0.watchDeskRole == nil })
    }

    // MARK: - The invariant that does not depend on the tee coming back

    /// The more important half of the fix, and the one that holds even when the
    /// role does not survive: a session resolving an overlay **without** a tee
    /// cannot read a capture published in a previous life.
    ///
    /// A wake reuses the terminal row and therefore the capture path, so
    /// without this the reader would find a months-old payload, take its
    /// `context_window_size`, and report the window as `.observed` with
    /// `isPairedReading == true` — a stale denominator wearing a fresh
    /// session's clothes.
    @Test func aSpawnWithNoTeeDeletesTheCaptureFromThePreviousLife() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let sessionKey = UUID().uuidString
        let capturePath = StatuslineTee.capturePath(sessionKey: sessionKey)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: capturePath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let payload = #"{"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":150000}}}"#
        try Data(payload.utf8).write(to: URL(fileURLWithPath: capturePath))

        // A reader would happily believe it, which is why it must not be there.
        let stale = ContextLoadReader().read(
            capturePath: capturePath, transcriptPath: nil, tee: .notADesk)
        #expect(stale.isPairedReading)

        _ = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil, sessionKey: sessionKey, watchDeskRole: nil, worktreePath: nil)

        #expect(!FileManager.default.fileExists(atPath: capturePath))
        let load = ContextLoadReader().read(
            capturePath: capturePath, transcriptPath: nil, tee: .notADesk)
        guard case .unknown = load.window else {
            Issue.record("a session with no tee read a capture from a previous life: \(load.window)")
            return
        }
        #expect(!load.isPairedReading)
    }

    @Test func aSpawnThatInstallsTheTeeKeepsTheSessionsCapture() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let sessionKey = UUID().uuidString
        let capturePath = StatuslineTee.capturePath(sessionKey: sessionKey)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: capturePath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(#"{"context_window":{"context_window_size":200000}}"#.utf8)
            .write(to: URL(fileURLWithPath: capturePath))

        _ = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil, sessionKey: sessionKey,
            watchDeskRole: .readOnlyCoordinator, worktreePath: nil)

        // The tee is about to republish over it, and until it does the desk's
        // own previous reading is the best anyone has.
        #expect(FileManager.default.fileExists(atPath: capturePath))
    }

    // MARK: - Known limitation, pinned rather than papered over

    /// `terminal.swapProfile` in `.fork` mode and `terminalHistory.revive` mint
    /// a **new** terminal ID, so a desk cannot be identified at those sites from
    /// a durable fact: `watch_desk_role` belongs to the row the lease store
    /// wrote, and the new row has none until a lease is acquired against it.
    /// (An `.inPlace` swap is the other case entirely — it keeps the row, so the
    /// role is right there to read; see
    /// `SwapProfileStatuslineTeeTests`.)
    ///
    /// This is left as it is deliberately. Carrying the old row's role onto a
    /// new one would be inventing a desk-marking mechanism parallel to the
    /// lease — the one thing this slice was told not to do — and it would
    /// change what "this terminal is the desk" means without the lease store
    /// agreeing. The consequence is bounded and is the opposite of the
    /// hibernation bug: a new terminal ID means a new capture path, so the
    /// session reads **no** capture rather than a stale one, and the
    /// denominator is honestly unknown until a lease is acquired and the
    /// session respawns.
    ///
    /// The test pins that current behavior so a future change to it is a
    /// deliberate edit rather than a silent drift.
    @Test func aFreshTerminalIDHasNoDeskRoleAndSoReadsNoStaleCapture() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let db = try TBDDatabase(inMemory: true)
        let desk = try await parkedTerminal(
            db: db, repoPath: try makeRepoDir(scratch), desk: .byLease)
        #expect(desk.watchDeskRole != nil)

        // The role lives on the row, not on the worktree: a second terminal in
        // the same worktree is not a desk.
        let successor = try await db.terminals.create(
            worktreeID: desk.worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "sess-desk", kind: .claude)
        #expect(successor.watchDeskRole == nil)

        // So a resume keyed on the successor writes no tee and, having a
        // different capture path, cannot read the desk's stale capture.
        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil,
            sessionKey: successor.id.uuidString,
            watchDeskRole: successor.watchDeskRole,
            worktreePath: nil)
        #expect(path == ClaudeHookOverlay.overlayPath)
        #expect(StatuslineTee.capturePath(sessionKey: successor.id.uuidString)
                != StatuslineTee.capturePath(sessionKey: desk.id.uuidString))
    }
}
}
