import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 1 — dry-run tmux and a virtual date source. Nothing here sleeps: the
/// grace period is crossed by moving the injected `now` seam, which is what
/// makes "inside the grace period" an exact assertion rather than a race
/// against a loaded runner.
///
/// Covers reconcile's reclamation of the `tbd-ext-*` sessions
/// `tbd terminal attach` mints. The 60-second grace period is the behavior
/// under test, not an implementation detail: reaping a client-less session
/// immediately would take it during a momentary detach or inside the
/// create-to-attach gap and silently truncate a measurement run. See
/// `docs/specs/2026-08-27-external-tmux-attach-shortcut-design.md`,
/// "Reclamation".
@Suite("External attach session reclamation")
struct ExternalAttachSessionReapTests {

    // MARK: - Fixture

    /// What `list-sessions` answers on the fake server, mutable between sweeps
    /// so a test can detach and reattach a client.
    private final class SessionTable: @unchecked Sendable {
        private let lock = NSLock()
        private var sessions: [(name: String, attachedClients: Int)]

        init(_ sessions: [(name: String, attachedClients: Int)]) {
            self.sessions = sessions
        }

        func set(_ sessions: [(name: String, attachedClients: Int)]) {
            lock.withLock { self.sessions = sessions }
        }

        var hook: @Sendable (String) -> [(name: String, attachedClients: Int)] {
            { [self] _ in lock.withLock { sessions } }
        }
    }

    /// Every argv the dry-run tmux was asked to run.
    private final class CommandRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [[String]] = []

        var hook: @Sendable ([String]) -> Void {
            { [self] command in lock.withLock { commands.append(command) } }
        }

        /// The session names this run asked tmux to kill.
        func killedSessions() -> [String] {
            lock.withLock {
                commands.compactMap { command in
                    guard command.contains("kill-session"),
                          let targetIndex = command.firstIndex(of: "-t"),
                          command.index(after: targetIndex) < command.endIndex
                    else { return nil }
                    return command[command.index(after: targetIndex)]
                }
            }
        }
    }

    private let server = "tbd-acme"

    private func makeLifecycle(
        sessions: SessionTable, recorder: CommandRecorder, date: TestDateSource
    ) throws -> WorktreeLifecycle {
        WorktreeLifecycle(
            db: try TBDDatabase(inMemory: true),
            git: GitManager(),
            tmux: TmuxManager(
                dryRun: true,
                dryRunRecorder: recorder.hook,
                dryRunListSessions: sessions.hook
            ),
            hooks: HookResolver(),
            now: date.provider
        )
    }

    // MARK: - The grace period

    @Test("a tbd-ext session client-less past the grace period is killed")
    func pastGraceSessionIsKilled() async throws {
        let sessions = SessionTable([("tbd-ext-abcd1234", 0)])
        let recorder = CommandRecorder()
        let date = TestDateSource()
        let lifecycle = try makeLifecycle(sessions: sessions, recorder: recorder, date: date)

        // First sweep only records the observation — there is no earlier one
        // to measure against.
        await lifecycle.reapExternalAttachSessions(server: server)
        #expect(recorder.killedSessions().isEmpty)

        date.advance(by: 61)
        await lifecycle.reapExternalAttachSessions(server: server)
        #expect(recorder.killedSessions() == ["tbd-ext-abcd1234"])
    }

    /// The test that fails if the grace period is removed. Deleting it — or
    /// zeroing `ExternalAttachSessionTracker.gracePeriod` — makes the second
    /// sweep reap a session that has been client-less for 30 seconds, which is
    /// exactly the momentary-detach case the period exists to protect.
    @Test("a tbd-ext session still inside the grace period is left alone")
    func insideGraceSessionIsLeftAlone() async throws {
        let sessions = SessionTable([("tbd-ext-abcd1234", 0)])
        let recorder = CommandRecorder()
        let date = TestDateSource()
        let lifecycle = try makeLifecycle(sessions: sessions, recorder: recorder, date: date)

        await lifecycle.reapExternalAttachSessions(server: server)
        date.advance(by: 30)
        await lifecycle.reapExternalAttachSessions(server: server)

        #expect(recorder.killedSessions().isEmpty)
    }

    @Test("a tbd-ext session with an attached client is never killed")
    func attachedSessionIsLeftAlone() async throws {
        let sessions = SessionTable([("tbd-ext-abcd1234", 1)])
        let recorder = CommandRecorder()
        let date = TestDateSource()
        let lifecycle = try makeLifecycle(sessions: sessions, recorder: recorder, date: date)

        await lifecycle.reapExternalAttachSessions(server: server)
        date.advance(by: 3_600)
        await lifecycle.reapExternalAttachSessions(server: server)

        #expect(recorder.killedSessions().isEmpty)
    }

    @Test("reattaching restarts the grace period rather than carrying a stale deadline")
    func reattachingClearsTheTimer() async throws {
        let sessions = SessionTable([("tbd-ext-abcd1234", 0)])
        let recorder = CommandRecorder()
        let date = TestDateSource()
        let lifecycle = try makeLifecycle(sessions: sessions, recorder: recorder, date: date)

        // Observed client-less…
        await lifecycle.reapExternalAttachSessions(server: server)

        // …then somebody attaches again, well inside the grace period.
        date.advance(by: 30)
        sessions.set([("tbd-ext-abcd1234", 1)])
        await lifecycle.reapExternalAttachSessions(server: server)

        // …and detaches. This observation is 70s after the first client-less
        // one, so a stale deadline would fire here.
        date.advance(by: 40)
        sessions.set([("tbd-ext-abcd1234", 0)])
        await lifecycle.reapExternalAttachSessions(server: server)
        #expect(recorder.killedSessions().isEmpty)

        // 50s past the *second* client-less observation: still inside the
        // restarted period.
        date.advance(by: 50)
        await lifecycle.reapExternalAttachSessions(server: server)
        #expect(recorder.killedSessions().isEmpty)

        // 61s past it: the restarted clock fires.
        date.advance(by: 11)
        await lifecycle.reapExternalAttachSessions(server: server)
        #expect(recorder.killedSessions() == ["tbd-ext-abcd1234"])
    }

    // MARK: - Scope

    @Test("tbd-view sessions and main are never touched, however long they sit client-less")
    func viewerSessionsAndMainAreNeverKilled() async throws {
        let sessions = SessionTable([
            ("main", 0),
            ("tbd-view-deadbeef", 0),
            ("tbd-extra-not-ours", 0),
        ])
        let recorder = CommandRecorder()
        let date = TestDateSource()
        let lifecycle = try makeLifecycle(sessions: sessions, recorder: recorder, date: date)

        await lifecycle.reapExternalAttachSessions(server: server)
        date.advance(by: 3_600)
        await lifecycle.reapExternalAttachSessions(server: server)

        #expect(recorder.killedSessions().isEmpty)
    }

    // MARK: - The record a reap leaves

    /// `os.Logger` output cannot be read back in-process, so the assertion is
    /// on the composed line the reap logs — the spec requires a reap to be
    /// detectable afterwards, so a line that stopped naming its session (or
    /// its grace period) would defeat that silently.
    @Test("a reap emits a log line naming the session, its server, and the grace period")
    func reapEmitsItsLogLine() async throws {
        let sessions = SessionTable([("tbd-ext-abcd1234", 0)])
        let recorder = CommandRecorder()
        let date = TestDateSource()
        let lifecycle = try makeLifecycle(sessions: sessions, recorder: recorder, date: date)

        await lifecycle.reapExternalAttachSessions(server: server)
        date.advance(by: 61)
        await lifecycle.reapExternalAttachSessions(server: server)
        // The line is only meaningful as the record of an actual reap.
        #expect(recorder.killedSessions() == ["tbd-ext-abcd1234"])

        #expect(
            WorktreeLifecycle.externalAttachReapLogLine(
                server: server, session: "tbd-ext-abcd1234")
            == "reconcile: killed external attach session tbd-ext-abcd1234 on tmux server tbd-acme — no client had been attached to it for at least 60s")
    }

    // MARK: - Wiring

    /// Without this, every test above could pass while the pass is called from
    /// nowhere. Two sweeps with the clock moved between them, through the real
    /// `reconcile` entry point.
    @Test("reconcile runs the external-attach reclamation pass")
    func reconcileRunsThePass() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessions = SessionTable([("tbd-ext-abcd1234", 0)])
        let recorder = CommandRecorder()
        let date = TestDateSource()
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(
                dryRun: true,
                dryRunRecorder: recorder.hook,
                dryRunListSessions: sessions.hook
            ),
            hooks: HookResolver(),
            now: date.provider
        )
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "acme", defaultBranch: "main")

        try await lifecycle.reconcile(
            repoID: repo.id, actuationLog: makeTestActuationLog(),
            reapSharedScratchTmuxResources: true)
        #expect(recorder.killedSessions().isEmpty)

        date.advance(by: 61)
        try await lifecycle.reconcile(
            repoID: repo.id, actuationLog: makeTestActuationLog(),
            reapSharedScratchTmuxResources: true)
        #expect(recorder.killedSessions() == ["tbd-ext-abcd1234"])
    }
}
