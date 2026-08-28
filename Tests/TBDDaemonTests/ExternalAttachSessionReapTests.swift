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
///
/// The fixture is a small *stateful* fake tmux server rather than a canned
/// listing, because the clock this pass reads lives on the session itself: a
/// stamp written by one sweep has to be visible to the next one, and a session
/// killed by one sweep has to be gone from the next listing. A canned listing
/// would let a stamp round-trip that never happens pass as if it had.
@Suite("External attach session reclamation")
struct ExternalAttachSessionReapTests {

    // MARK: - Fixture

    /// A fake tmux server: it answers `list-sessions`, applies the
    /// `set-option` writes the pass makes, and honors the conditional kill.
    private final class FakeTmuxServer: @unchecked Sendable {
        private let lock = NSLock()
        private var sessions: [TmuxSessionInfo]
        private var killed: [String] = []
        private var sparedOnKill: Set<String> = []
        private var commands: [[String]] = []

        init(_ sessions: [TmuxSessionInfo] = []) {
            self.sessions = sessions
        }

        func set(_ sessions: [TmuxSessionInfo]) {
            lock.withLock { self.sessions = sessions }
        }

        /// Make the next conditional kill of `session` come back spared, as it
        /// does when a client attaches between the listing and the kill.
        func spareOnKill(_ session: String) {
            lock.withLock { _ = sparedOnKill.insert(session) }
        }

        var listHook: @Sendable (String) -> [TmuxSessionInfo] {
            { [self] _ in lock.withLock { sessions } }
        }

        var sparedHook: @Sendable (String, String) -> Bool {
            { [self] _, session in lock.withLock { sparedOnKill.contains(session) } }
        }

        /// Applies what the pass asked tmux to do, so the next sweep observes
        /// the consequences rather than the fixture's original answer.
        var recorderHook: @Sendable ([String]) -> Void {
            { [self] command in
                lock.withLock {
                    commands.append(command)
                    guard let targetIndex = command.firstIndex(of: "-t"),
                          command.index(after: targetIndex) < command.endIndex
                    else { return }
                    let target = command[command.index(after: targetIndex)]
                    if command.contains("if-shell") {
                        guard !sparedOnKill.contains(target) else { return }
                        killed.append(target)
                        sessions.removeAll { $0.name == target }
                    } else if command.contains("kill-session") {
                        // An UNCONDITIONAL kill: tmux does not spare an
                        // attached session, so the fake must not either. This
                        // is what makes the TOCTOU test fail — rather than pass
                        // vacuously — if the reap ever stops being conditional.
                        killed.append(target)
                        sessions.removeAll { $0.name == target }
                    } else if command.contains("set-option") {
                        let clearing = command.contains("-u")
                        let stamp = clearing
                            ? nil
                            : command.last.flatMap(TimeInterval.init)
                                .map { Date(timeIntervalSince1970: $0) }
                        sessions = sessions.map { session in
                            guard session.name == target else { return session }
                            return TmuxSessionInfo(
                                name: session.name,
                                attachedClients: session.attachedClients,
                                created: session.created,
                                lastAttached: session.lastAttached,
                                clientlessSince: stamp)
                        }
                    }
                }
            }
        }

        /// The session names this run actually killed — spared conditional
        /// kills are excluded, which is the whole point of the TOCTOU test.
        func killedSessions() -> [String] { lock.withLock { killed } }

        func recordedCommands() -> [[String]] { lock.withLock { commands } }

        /// What the fake currently reports for one session, so a test can
        /// assert on a stamp having been written or cleared.
        func session(_ name: String) -> TmuxSessionInfo? {
            lock.withLock { sessions.first { $0.name == name } }
        }
    }

    private let server = "tbd-acme"

    /// Composed, never hardcoded: the sweep matches on
    /// `ExternalAttachCommand.sessionPrefix`, so a fixture that spelled the
    /// name out by hand would keep passing if the prefix or the id width
    /// changed underneath it.
    private static let terminalID = UUID(uuidString: "abcd1234-0000-4000-8000-00000000feed")!
    private var externalSession: String {
        ExternalAttachCommand.sessionName(for: Self.terminalID)
    }

    private func makeLifecycle(
        tmuxServer fake: FakeTmuxServer, date: TestDateSource
    ) throws -> WorktreeLifecycle {
        WorktreeLifecycle(
            db: try TBDDatabase(inMemory: true),
            git: GitManager(),
            tmux: TmuxManager(
                dryRun: true,
                dryRunRecorder: fake.recorderHook,
                dryRunListSessions: fake.listHook,
                dryRunSessionSpared: fake.sparedHook
            ),
            hooks: HookResolver(),
            now: date.provider
        )
    }

    /// A session tmux has never seen a client attach to — the create-to-attach
    /// gap orphan, and the case reclamation exists for.
    private func neverAttached(
        _ name: String, createdAgo: TimeInterval, now: Date
    ) -> TmuxSessionInfo {
        TmuxSessionInfo(
            name: name, attachedClients: 0, created: now - createdAgo, lastAttached: nil)
    }

    // MARK: - The grace period

    @Test("a tbd-ext session client-less past the grace period is killed")
    func pastGraceSessionIsKilled() async throws {
        let date = TestDateSource()
        let fake = FakeTmuxServer()
        let lifecycle = try makeLifecycle(tmuxServer: fake, date: date)
        fake.set([neverAttached(externalSession, createdAgo: 0, now: date.now)])

        // Freshly minted: inside the grace period, so this sweep must not take
        // it — that is the create-to-attach gap.
        await lifecycle.reapExternalAttachSessions(server: server)
        #expect(fake.killedSessions().isEmpty)

        date.advance(by: 61)
        await lifecycle.reapExternalAttachSessions(server: server)
        #expect(fake.killedSessions() == [externalSession])
    }

    /// tmux dates a never-attached session exactly — it has been client-less
    /// since it was created — so reclaiming one needs no second sweep and no
    /// daemon-side memory. This is what keeps the worst-case reclaim time at
    /// roughly the hourly cadence instead of twice it.
    @Test("a never-attached session past the grace period is reaped on the first observation")
    func neverAttachedSessionIsReapedOnOneObservation() async throws {
        let date = TestDateSource()
        let fake = FakeTmuxServer()
        let lifecycle = try makeLifecycle(tmuxServer: fake, date: date)
        fake.set([neverAttached(externalSession, createdAgo: 3_600, now: date.now)])

        await lifecycle.reapExternalAttachSessions(server: server)
        #expect(fake.killedSessions() == [externalSession])
    }

    /// The test that fails if the grace period is removed. Deleting it — or
    /// zeroing `ExternalAttachReclamation.gracePeriod` — makes this sweep reap
    /// a session that has been client-less for 30 seconds, which is exactly the
    /// create-to-attach case the period exists to protect.
    @Test("a tbd-ext session still inside the grace period is left alone")
    func insideGraceSessionIsLeftAlone() async throws {
        let date = TestDateSource()
        let fake = FakeTmuxServer()
        let lifecycle = try makeLifecycle(tmuxServer: fake, date: date)
        fake.set([neverAttached(externalSession, createdAgo: 0, now: date.now)])

        await lifecycle.reapExternalAttachSessions(server: server)
        date.advance(by: 30)
        await lifecycle.reapExternalAttachSessions(server: server)

        #expect(fake.killedSessions().isEmpty)
    }

    @Test("a tbd-ext session with an attached client is never killed")
    func attachedSessionIsLeftAlone() async throws {
        let date = TestDateSource()
        let fake = FakeTmuxServer()
        let lifecycle = try makeLifecycle(tmuxServer: fake, date: date)
        fake.set([TmuxSessionInfo(
            name: externalSession, attachedClients: 1,
            created: date.now - 3_600, lastAttached: date.now - 3_500)])

        await lifecycle.reapExternalAttachSessions(server: server)
        date.advance(by: 3_600)
        await lifecycle.reapExternalAttachSessions(server: server)

        #expect(fake.killedSessions().isEmpty)
    }

    /// A session that HAS been attached cannot be dated from tmux alone —
    /// `session_last_attached` records the last attach and does not move on
    /// detach — so the first sweep stamps it and only a later one may act.
    @Test("a detached session is stamped first and reaped only a grace period later")
    func detachedSessionIsStampedThenReaped() async throws {
        let date = TestDateSource()
        let fake = FakeTmuxServer()
        let lifecycle = try makeLifecycle(tmuxServer: fake, date: date)
        fake.set([TmuxSessionInfo(
            name: externalSession, attachedClients: 0,
            created: date.now - 3_600, lastAttached: date.now - 3_000)])

        await lifecycle.reapExternalAttachSessions(server: server)
        #expect(fake.killedSessions().isEmpty)
        // The clock is on the session, not in the daemon.
        #expect(fake.session(externalSession)?.clientlessSince == date.now)

        date.advance(by: 30)
        await lifecycle.reapExternalAttachSessions(server: server)
        #expect(fake.killedSessions().isEmpty)

        date.advance(by: 31)
        await lifecycle.reapExternalAttachSessions(server: server)
        #expect(fake.killedSessions() == [externalSession])
    }

    @Test("reattaching clears the stamp rather than carrying a stale deadline")
    func reattachingClearsTheStamp() async throws {
        let date = TestDateSource()
        let fake = FakeTmuxServer()
        let lifecycle = try makeLifecycle(tmuxServer: fake, date: date)
        fake.set([TmuxSessionInfo(
            name: externalSession, attachedClients: 0,
            created: date.now - 3_600, lastAttached: date.now - 3_000)])

        // Observed client-less: stamped.
        await lifecycle.reapExternalAttachSessions(server: server)
        let stamp = try #require(fake.session(externalSession)?.clientlessSince)

        // …then somebody attaches again, well inside the grace period.
        date.advance(by: 30)
        fake.set([TmuxSessionInfo(
            name: externalSession, attachedClients: 1,
            created: date.now - 3_630, lastAttached: date.now,
            clientlessSince: stamp)])
        await lifecycle.reapExternalAttachSessions(server: server)
        #expect(fake.session(externalSession)?.clientlessSince == nil)

        // …and detaches. This observation is 70s after the first client-less
        // one, so a stale deadline would fire here.
        date.advance(by: 40)
        let reattachedAt = date.now - 40
        fake.set([TmuxSessionInfo(
            name: externalSession, attachedClients: 0,
            created: date.now - 3_670, lastAttached: reattachedAt)])
        await lifecycle.reapExternalAttachSessions(server: server)
        #expect(fake.killedSessions().isEmpty)

        // 50s past the *second* client-less observation: still inside the
        // restarted period.
        date.advance(by: 50)
        await lifecycle.reapExternalAttachSessions(server: server)
        #expect(fake.killedSessions().isEmpty)

        // 61s past it: the restarted clock fires.
        date.advance(by: 11)
        await lifecycle.reapExternalAttachSessions(server: server)
        #expect(fake.killedSessions() == [externalSession])
    }

    /// A stamp only stays evidence while nobody has attached since it was
    /// written. Between two hourly sweeps a user can attach and detach without
    /// being observed at all; `session_last_attached` moving past the stamp is
    /// what tells the next sweep the stamp is spent.
    @Test("an attach that happened between sweeps invalidates the stamp")
    func attachBetweenSweepsInvalidatesTheStamp() async throws {
        let date = TestDateSource()
        let fake = FakeTmuxServer()
        let lifecycle = try makeLifecycle(tmuxServer: fake, date: date)
        fake.set([TmuxSessionInfo(
            name: externalSession, attachedClients: 0,
            created: date.now - 3_600, lastAttached: date.now - 3_000)])

        await lifecycle.reapExternalAttachSessions(server: server)
        let stamp = try #require(fake.session(externalSession)?.clientlessSince)

        // A whole hour later, well past the grace period — but tmux says a
        // client attached ten seconds ago and has since gone.
        date.advance(by: 3_600)
        fake.set([TmuxSessionInfo(
            name: externalSession, attachedClients: 0,
            created: date.now - 7_200, lastAttached: date.now - 10,
            clientlessSince: stamp)])
        await lifecycle.reapExternalAttachSessions(server: server)
        #expect(fake.killedSessions().isEmpty)
        #expect(fake.session(externalSession)?.clientlessSince == date.now)
    }

    // MARK: - A recreated session does not inherit a dead session's deadline

    /// F7. Session names are deterministic per terminal, so the name alone
    /// cannot tell one session from its successor. The stamp therefore lives on
    /// the session object: a session that vanished any way other than by being
    /// reaped — `destroy-unattached` firing, a hand-typed `kill-session`, the
    /// server dying — takes its stamp with it, and the next session minted
    /// under the same name starts unstamped.
    ///
    /// With a daemon-side map keyed by name, this test kills a session that has
    /// existed for zero seconds, inside the create-to-attach gap.
    @Test("a session recreated under the same name is not reaped on its first observation")
    func recreatedSessionDoesNotInheritTheDeadline() async throws {
        let date = TestDateSource()
        let fake = FakeTmuxServer()
        let lifecycle = try makeLifecycle(tmuxServer: fake, date: date)
        fake.set([TmuxSessionInfo(
            name: externalSession, attachedClients: 0,
            created: date.now - 3_600, lastAttached: date.now - 3_000)])

        // Stamped, well before the grace period could elapse.
        await lifecycle.reapExternalAttachSessions(server: server)
        #expect(fake.session(externalSession)?.clientlessSince == date.now)

        // The session goes away on its own, and the user attaches again for the
        // same terminal. The sweep below lands in the create-to-attach gap: a
        // brand-new session, same name, no client yet.
        date.advance(by: 70)
        fake.set([neverAttached(externalSession, createdAgo: 0, now: date.now)])
        await lifecycle.reapExternalAttachSessions(server: server)
        #expect(fake.killedSessions().isEmpty)

        // And it is still spared a moment later — the clock genuinely restarted
        // rather than being merely deferred by one sweep.
        date.advance(by: 30)
        await lifecycle.reapExternalAttachSessions(server: server)
        #expect(fake.killedSessions().isEmpty)
    }

    // MARK: - A client that arrives after the listing wins

    /// F8. `list-sessions` is a snapshot and `kill-session` does not spare an
    /// attached session, so a plain kill would forcibly disconnect somebody who
    /// attached in the meantime — mid-measurement, which is the failure this
    /// whole feature exists to avoid manufacturing. The condition and the kill
    /// are therefore one queued tmux unit.
    @Test("a session that gained a client between the listing and the kill is not killed")
    func sessionThatGainedAClientIsSpared() async throws {
        let date = TestDateSource()
        let fake = FakeTmuxServer()
        let lifecycle = try makeLifecycle(tmuxServer: fake, date: date)
        fake.set([neverAttached(externalSession, createdAgo: 3_600, now: date.now)])
        fake.spareOnKill(externalSession)

        await lifecycle.reapExternalAttachSessions(server: server)

        #expect(fake.killedSessions().isEmpty)
        #expect(fake.session(externalSession) != nil)
    }

    /// The sparing above is only real if the daemon never issues an
    /// unconditional `kill-session`: a re-check followed by a plain kill would
    /// narrow the window, not close it.
    @Test("the reap is issued as one conditional tmux command, never a bare kill-session")
    func reapIsConditional() async throws {
        let date = TestDateSource()
        let fake = FakeTmuxServer()
        let lifecycle = try makeLifecycle(tmuxServer: fake, date: date)
        fake.set([neverAttached(externalSession, createdAgo: 3_600, now: date.now)])

        await lifecycle.reapExternalAttachSessions(server: server)

        let commands = fake.recordedCommands()
        #expect(commands.contains(TmuxManager.killSessionIfClientlessCommand(
            server: server, session: externalSession)))
        #expect(!commands.contains(TmuxManager.killSessionCommand(
            server: server, session: externalSession)))
    }

    // MARK: - Scope

    @Test("tbd-view sessions and main are never touched, however long they sit client-less")
    func viewerSessionsAndMainAreNeverKilled() async throws {
        let date = TestDateSource()
        let fake = FakeTmuxServer()
        let lifecycle = try makeLifecycle(tmuxServer: fake, date: date)
        fake.set([
            neverAttached("main", createdAgo: 3_600, now: date.now),
            neverAttached("tbd-view-deadbeef", createdAgo: 3_600, now: date.now),
            neverAttached("tbd-extra-not-ours", createdAgo: 3_600, now: date.now),
        ])

        await lifecycle.reapExternalAttachSessions(server: server)
        date.advance(by: 3_600)
        await lifecycle.reapExternalAttachSessions(server: server)

        #expect(fake.killedSessions().isEmpty)
        #expect(fake.recordedCommands().isEmpty)
    }

    // MARK: - The record a reap leaves

    /// `os.Logger` output cannot be read back in-process, so the assertion is
    /// on the composed line the reap logs — the spec requires a reap to be
    /// detectable afterwards, so a line that stopped naming its session (or
    /// its grace period) would defeat that silently.
    @Test("a reap emits a log line naming the session, its server, and the grace period")
    func reapEmitsItsLogLine() async throws {
        let date = TestDateSource()
        let fake = FakeTmuxServer()
        let lifecycle = try makeLifecycle(tmuxServer: fake, date: date)
        fake.set([neverAttached(externalSession, createdAgo: 3_600, now: date.now)])

        await lifecycle.reapExternalAttachSessions(server: server)
        // The line is only meaningful as the record of an actual reap.
        #expect(fake.killedSessions() == [externalSession])

        #expect(
            WorktreeLifecycle.externalAttachReapLogLine(
                server: server, session: externalSession)
            == "reconcile: killed external attach session \(externalSession) on tmux server tbd-acme — no client had been attached to it for at least 60s")
    }

    // MARK: - Reading tmux's answer

    /// Pins the tmux facts the whole design rests on, measured against tmux
    /// 3.6a: `#{session_created}` is epoch seconds and always present, while
    /// `#{session_last_attached}` and an unset user option both come back as
    /// **empty fields** — which must parse as "absent", not as epoch 0. A
    /// never-attached session read as "attached at 1970" would be reaped
    /// through the stamping path instead of dated exactly.
    @Test("an empty last-attached or stamp field parses as absent, not as epoch zero")
    func emptyTimeFieldsParseAsAbsent() {
        let never = "0\t1787890538\t\t\ttbd-ext-abcd1234"
        let parsed = try? #require(TmuxManager.parseSessions(never).first)
        #expect(parsed?.name == "tbd-ext-abcd1234")
        #expect(parsed?.attachedClients == 0)
        #expect(parsed?.created == Date(timeIntervalSince1970: 1_787_890_538))
        #expect(parsed?.lastAttached == nil)
        #expect(parsed?.clientlessSince == nil)
    }

    @Test("a stamped, previously-attached session parses all three timestamps")
    func populatedTimeFieldsParse() {
        let line = "1\t1787890538\t1787890563\t1787890600\ttbd-ext-abcd1234"
        let parsed = try? #require(TmuxManager.parseSessions(line).first)
        #expect(parsed?.attachedClients == 1)
        #expect(parsed?.lastAttached == Date(timeIntervalSince1970: 1_787_890_563))
        #expect(parsed?.clientlessSince == Date(timeIntervalSince1970: 1_787_890_600))
    }

    /// The name comes last and the fields are tab-separated because a tmux
    /// session name may contain a space.
    @Test("a session name containing a space survives parsing whole")
    func spacedSessionNameParses() {
        let line = "0\t1787890538\t\t\tmy session"
        #expect(TmuxManager.parseSessions(line).first?.name == "my session")
    }

    // MARK: - Wiring

    /// Without this, every test above could pass while the pass is called from
    /// nowhere on the reconcile path.
    @Test("reconcile runs the external-attach reclamation pass")
    func reconcileRunsThePass() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let date = TestDateSource()
        let fake = FakeTmuxServer()
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(
                dryRun: true,
                dryRunRecorder: fake.recorderHook,
                dryRunListSessions: fake.listHook,
                dryRunSessionSpared: fake.sparedHook
            ),
            hooks: HookResolver(),
            now: date.provider
        )
        fake.set([neverAttached(externalSession, createdAgo: 0, now: date.now)])
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "acme", defaultBranch: "main")

        try await lifecycle.reconcile(
            repoID: repo.id, actuationLog: makeTestActuationLog(),
            reapSharedScratchTmuxResources: true)
        #expect(fake.killedSessions().isEmpty)

        date.advance(by: 61)
        try await lifecycle.reconcile(
            repoID: repo.id, actuationLog: makeTestActuationLog(),
            reapSharedScratchTmuxResources: true)
        #expect(fake.killedSessions() == [externalSession])
    }

    /// F1. Wiring is not cadence. Every reconcile entry point into this pass —
    /// daemon startup, `repo.add`, the `cleanup` RPC — is one-shot, so a test
    /// that only calls `reconcile` by hand proves the pass is reachable while
    /// leaving it reachable from nothing that recurs. This drives the actual
    /// hourly timer body instead.
    @Test("the hourly orphan-maintenance cadence reaches external-attach reclamation")
    func orphanMaintenanceReclaimsExternalAttachSessions() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let date = TestDateSource()
        let fake = FakeTmuxServer()
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(
                dryRun: true,
                dryRunRecorder: fake.recorderHook,
                dryRunListSessions: fake.listHook,
                dryRunSessionSpared: fake.sparedHook
            ),
            hooks: HookResolver(),
            now: date.provider
        )
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "acme", defaultBranch: "main")
        _ = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main", path: repoDir.path,
            tmuxServer: server)
        // Abandoned an hour ago by an attach that never landed — the exact
        // orphan the fast path (`destroy-unattached on`) cannot reclaim,
        // because the option only ever gets set by a client that arrives.
        fake.set([neverAttached(externalSession, createdAgo: 3_600, now: date.now)])
        try await db.config.setGCEnabled(true)

        await Daemon.performOrphanMaintenance(
            orphanGC: OrphanGC(
                db: db, git: GitManager(), broadcast: { _ in }, lsofProvider: { [] }),
            lifecycle: lifecycle,
            configStore: db.config,
            actuationLog: makeTestActuationLog())

        #expect(fake.killedSessions() == [externalSession])
    }

    /// The other branch of the gate the cadence sits behind: the whole hourly
    /// pass answers to the GC master switch, so turning GC off must turn this
    /// off too rather than leaving one killer running unsupervised.
    @Test("orphan maintenance reclaims nothing when GC is disabled")
    func orphanMaintenanceSkipsReclamationWhenGCDisabled() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let date = TestDateSource()
        let fake = FakeTmuxServer()
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(
                dryRun: true,
                dryRunRecorder: fake.recorderHook,
                dryRunListSessions: fake.listHook,
                dryRunSessionSpared: fake.sparedHook
            ),
            hooks: HookResolver(),
            now: date.provider
        )
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "acme", defaultBranch: "main")
        _ = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main", path: repoDir.path,
            tmuxServer: server)
        fake.set([neverAttached(externalSession, createdAgo: 3_600, now: date.now)])
        try await db.config.setGCEnabled(false)

        await Daemon.performOrphanMaintenance(
            orphanGC: OrphanGC(
                db: db, git: GitManager(), broadcast: { _ in }, lsofProvider: { [] }),
            lifecycle: lifecycle,
            configStore: db.config,
            actuationLog: makeTestActuationLog())

        #expect(fake.killedSessions().isEmpty)
    }
}
