import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Every argv the dry-run `TmuxManager` was handed. "Nothing was recorded" is
/// the assertion that a guard sat ahead of the whole tmux mechanic, not merely
/// ahead of the DB write at the end of it.
/// Not `private`: the same teardown gate is asserted in `ScratchDeleteRPCTests`
/// and `DeskSessionManagerTests`, whose fixtures need `TBD_HOME` and so cannot
/// live in this suite. One recorder rather than three copies.
final class RecordedTmuxArgs: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []

    func append(_ args: [String]) {
        lock.lock(); defer { lock.unlock() }
        calls.append(args)
    }

    func snapshot() -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
}

/// Every payload a rail handed the holder input seam, every pause it took
/// between them, and the answer the seam gave back — in one ordered log,
/// because on this transport the ORDER of "Escape, pause, text" is the
/// property under test and two separate recorders could not express it.
///
/// `send` is shaped exactly like the closure `Daemon.start` builds over
/// `HolderInjectionCourier.deliver` — bytes in, delivered-or-not out — so a
/// test asserts on the bytes production would put on a pty rather than on a
/// mock of the courier's internals. `waiter` is the actuator's own sleep seam,
/// recording instead of sleeping (the same trick
/// `LimitResumeActuatorTests.toggleFlippedOffBetweenAttemptsCancelsAfterOneSend`
/// uses to act between an actuation's steps).
private final class RecordedHolderWrites: @unchecked Sendable {
    enum Event: Equatable {
        case write(terminalID: UUID, bytes: Data)
        case pause(Duration)
    }

    private let lock = NSLock()
    private var events: [Event] = []
    private var writeCount = 0
    /// How many writes the seam answers `true` to before it starts answering
    /// `false` — a courier that found no route at all. Default: every one.
    /// `0` refuses the first write, `1` the second, which is how the two
    /// halves of the holder arm's send are failed independently.
    private let acceptedWrites: Int

    init(acceptedWrites: Int = .max) { self.acceptedWrites = acceptedWrites }

    /// Writes and pauses interleaved, in the order they happened.
    func snapshot() -> [Event] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    /// Just the writes, for the tests whose whole assertion is that there were
    /// none.
    func writes() -> [Event] {
        snapshot().filter { if case .write = $0 { return true } else { return false } }
    }

    private func recordWrite(terminalID: UUID, bytes: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        events.append(.write(terminalID: terminalID, bytes: bytes))
        writeCount += 1
        return writeCount <= acceptedWrites
    }

    private func recordPause(_ duration: Duration) {
        lock.lock()
        defer { lock.unlock() }
        events.append(.pause(duration))
    }

    var send: @Sendable (UUID, Data) async -> Bool {
        { [self] terminalID, bytes in
            recordWrite(terminalID: terminalID, bytes: bytes)
        }
    }

    var waiter: @Sendable (Duration) async -> Void {
        { [self] duration in
            recordPause(duration)
        }
    }
}

/// The subsystems that assumed every terminal has a live tmux window, and what
/// each of them now does with a holder-backed row instead.
///
/// The shared defect: a holder row carries `tmuxWindowID == ""` and
/// `tmuxPaneID == ""` by construction, and `TmuxManager.windowExists` swallows
/// its errors and answers `false`. So the empty coordinate does not fail — it
/// reads as a window that is definitely gone, and every mechanic built on that
/// reading fires against a session that is perfectly alive.
///
/// Milestone A does not teach recreate, park or in-place swap the holder
/// transport; it refuses them, because an action the user has to take another
/// way is recoverable and a row that lies about a live process is not. Each
/// test therefore asserts on the ROW after the call, not only on the returned
/// value: a refusal that still parked or re-identified the row would be the
/// very bug these gates exist to remove, and the return value alone cannot see
/// it.
///
/// **`terminal.delete` is the exception, and the reason this suite is not
/// simply a list of refusals.** Its row is going away either way, so refusing
/// would leak the holder process, the job it forked and its rendezvous files
/// rather than protect anything. It does the holder work instead — the shape of
/// the fix follows from what the path is for, not from the family it belongs
/// to.
///
/// Each gate carries both legs. The tmux leg is not ceremony — every one of
/// these branches is a `transport == .holder` comparison that an inverted one
/// would satisfy just as well while disabling the mechanic for the transport
/// that still needs it.
@Suite("Holder rows and the tmux-window assumption")
struct HolderTmuxAssumptionGateTests {

    // MARK: - Fixtures

    /// Temp profile/host dirs, so `wake()`'s transcript-sync ambient fallback
    /// lists a sandbox rather than the developer's real `~/.claude/projects`.
    private func isolatedConfigDirManager() -> ClaudeProfileConfigDirManager {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-holdergate-\(UUID().uuidString)", isDirectory: true)
        return ClaudeProfileConfigDirManager(
            baseDirectory: home.appendingPathComponent("profiles", isDirectory: true),
            hostBaseDirectory: home.appendingPathComponent("claude-host", isDirectory: true))
    }

    /// In-memory DB plus a worktree whose path exists on disk — both the wake
    /// and the recreate paths refuse to respawn into a missing directory, and
    /// that refusal would mask the one under test.
    private func seedWorktree(_ db: TBDDatabase) async throws -> (Worktree, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-holdergate-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let repo = try await db.repos.create(
            path: dir.path, displayName: "acme", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main", path: dir.path,
            tmuxServer: "tbd-holdergate")
        return (wt, dir)
    }

    /// An idle, resumable Claude row. `transport` is the only thing that varies
    /// between the two legs of every test below — with `.holder` it also takes
    /// the empty tmux coordinates and the holder/child pids the create path
    /// writes, because those are what the unguarded code would act on.
    ///
    /// `childPID` is overridable for one reason: the delete gate is the only
    /// test here that reaches code which would `kill()` it, and no fixture on a
    /// shared box may name a pid that could really exist. See
    /// `deleteDisposesHolderInsteadOfKillingAWindow`.
    ///
    /// `holderChildStartedAt` is the identity anchor `ProcessIdentityCheck`
    /// measures a live pid's start time against. Left nil by default, which is
    /// what a row that never recorded one carries; the wake tests that script a
    /// living child set it, because a verdict of `.same` needs both halves.
    private func seedClaudeTerminal(
        _ db: TBDDatabase, worktreeID: UUID, transport: TerminalTransport,
        childPID: Int32 = 9102, holderChildStartedAt: Date? = nil
    ) async throws -> Terminal {
        let holder = transport == .holder
        let terminal = try await db.terminals.create(
            worktreeID: worktreeID,
            tmuxWindowID: holder ? "" : "@7",
            tmuxPaneID: holder ? "" : "%7",
            label: TerminalLabel.claudeCode,
            claudeSessionID: "sess-holdergate",
            kind: .claude,
            transport: transport,
            holderPID: holder ? 9101 : nil,
            childPID: holder ? childPID : nil,
            holderChildStartedAt: holder ? holderChildStartedAt : nil)
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .idle, source: .derived)
        return try #require(try await db.terminals.get(id: terminal.id))
    }

    /// A registry whose rendezvous paths come from an explicit environment, so
    /// nothing here can reach the developer's real `~/tbd` even for an instant
    /// — and a short one, because a holder socket path has to fit `sun_path`.
    ///
    /// Nothing is ever created under it. Both callers below only *derive* the
    /// path and then fail to connect to it, which is exactly the state a
    /// session whose holder has already gone is in.
    private func holderRegistry(listing terminals: [Terminal]) -> HolderRegistry {
        HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: ["TBD_HOME": "/tmp/tbd-hg-\(UUID().uuidString.prefix(8))"],
            listTerminals: { terminals })
    }

    /// `signaller` is defaulted so every call site that does not care about the
    /// process table keeps compiling unchanged — but the wake path now reads it
    /// on holder rows, so a test whose verdict depends on whether a recorded
    /// child is alive must script one rather than let the production signaller
    /// ask the real kernel about a fixture pid.
    private func coordinator(
        _ db: TBDDatabase, tmux: TmuxManager, registry: HolderRegistry? = nil,
        signaller: any ProcessSignaller = ProductionProcessSignaller()
    ) async -> HibernationCoordinator {
        let coordinator = HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(),
            signaller: signaller, actuationLog: makeTestActuationLog())
        await coordinator.setHolderRegistry(registry)
        return coordinator
    }

    /// The shape a holder's job presents to an identity check: the login shell
    /// the holder forked, or the agent binary that shell `exec`d itself into.
    private static let holderChildCommand = "/bin/zsh -i -l -c claude"

    /// A process table in which the fixture's recorded child pid names nothing.
    ///
    /// The wake path asks about that pid before it spawns, and a fixture pid is
    /// a number the kernel may well have handed to a real process on this box.
    /// Scripting the answer is what keeps "the wake went on to spawn" a fact
    /// about the code rather than about what happens to be running.
    private func deadChildSignaller(_ childPID: Int32 = 9102) -> FakeProcessSignaller {
        let signaller = FakeProcessSignaller()
        signaller.behaviors[childPID] = .init(aliveInitially: false)
        return signaller
    }

    /// Dry-run tmux that reports every window dead, recording every argv.
    ///
    /// The dead-window answer is not pessimism, it is what a holder row gets
    /// from a real server: `windowExists(windowID: "")` cannot succeed, and
    /// `TmuxManager` swallows the failure and returns `false`. Reaching that
    /// answer through the hook rather than through a real missing server keeps
    /// the fixture off live tmux — and without it the dry-run default reports
    /// the empty window ALIVE, which lets both subsystems short-circuit to a
    /// harmless no-op and hides the corruption these gates prevent.
    private func deadWindowTmux(_ recorded: RecordedTmuxArgs) -> TmuxManager {
        TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorded.append($0) },
            dryRunWindowIsDead: { _ in true })
    }

    /// A router with the same sandboxed config dirs the coordinator gets: the
    /// swap path seeds folder trust and writes a settings overlay before it
    /// spawns anything, and neither belongs in the developer's real `~/.claude`.
    private func router(_ db: TBDDatabase, tmux: TmuxManager) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())
    }

    /// Every column a park, a wake or a recreate would touch. Comparing the
    /// whole set — rather than spot-checking `hibernatedAt` — is what makes
    /// "the row was left alone" an assertion instead of a hope.
    private struct RowFingerprint: Equatable {
        let tmuxWindowID: String
        let tmuxPaneID: String
        let transport: TerminalTransport
        let holderPID: Int32?
        let childPID: Int32?
        let claudeSessionID: String?
        /// The column an in-place profile swap exists to change, and so the one
        /// that makes "the swap was refused" an assertion about the row rather
        /// than about its return value.
        let profileID: UUID?
        let hibernatedAt: Date?
        let suspendedAt: Date?
        let hibernateReason: HibernateReason?
        let suspendedSnapshot: String?
        let sessionIncarnationID: UUID?

        init(_ t: Terminal) {
            tmuxWindowID = t.tmuxWindowID
            tmuxPaneID = t.tmuxPaneID
            transport = t.transport
            holderPID = t.holderPID
            childPID = t.childPID
            claudeSessionID = t.claudeSessionID
            profileID = t.profileID
            hibernatedAt = t.hibernatedAt
            suspendedAt = t.suspendedAt
            hibernateReason = t.hibernateReason
            suspendedSnapshot = t.suspendedSnapshot
            sessionIncarnationID = t.sessionIncarnationID
        }
    }

    // MARK: - Gate 1: terminal.recreateWindow

    @Test("recreateWindow refuses a holder row and leaves every column alone")
    func recreateWindowRefusesHolderRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        let before = RowFingerprint(terminal)

        let response = await router(db, tmux: tmux).handle(try RPCRequest(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: terminal.id)))

        #expect(!response.success)
        #expect(response.error == RPCRouter.holderRecreateRefusal(terminalID: terminal.id))

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(RowFingerprint(after) == before,
                "recreateWindow mutated a holder row it was supposed to refuse")
        // The strongest half: neither branch below the guard ran. The repark
        // branch would have killed a window, the respawn branch created one.
        #expect(recorded.snapshot().isEmpty,
                "recreateWindow reached tmux for a holder row: \(recorded.snapshot())")
    }

    @Test("recreateWindow still recreates a tmux row whose window is gone")
    func recreateWindowStillActsOnTmuxRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A shell row, so the handler takes the respawn branch rather than the
        // repark branch — the branch that would have stood up a tmux window
        // under a holder row.
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@old", tmuxPaneID: "%old", kind: .shell)

        let response = await router(db, tmux: tmux).handle(try RPCRequest(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: terminal.id)))

        #expect(response.success, "error: \(response.error ?? "nil")")
        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(after.tmuxWindowID != "@old",
                "the tmux leg must still get a fresh window")
        #expect(recorded.snapshot().contains { $0.contains("new-window") })
    }

    // MARK: - Gate 2: hibernation eligibility

    @Test("a holder row is not manually hibernatable, and manualHibernate refuses it")
    func holderRowIsNotManuallyHibernatable() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        let before = RowFingerprint(terminal)

        // The pure property first: it is what the app's tab menu reads, so a
        // holder tab must not even offer Hibernate.
        #expect(!terminal.isManuallyHibernatable(holderHibernationEnabled: false))
        #expect(!terminal.isAutoHibernationEligible(holderHibernationEnabled: false))

        let result = await coordinator(db, tmux: TmuxManager(dryRun: true))
            .manualHibernate(terminalID: terminal.id)
        #expect(result == .notEligible(reason: HibernationCoordinator.holderTransportRefusal))

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(RowFingerprint(after) == before,
                "a refused manual hibernate still mutated the holder row")
    }

    @Test("an identical tmux row is still manually hibernatable and parks")
    func tmuxRowStillManuallyHibernatable() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .tmux)

        #expect(terminal.isManuallyHibernatable(holderHibernationEnabled: false))
        #expect(terminal.isAutoHibernationEligible(holderHibernationEnabled: false))

        let result = await coordinator(db, tmux: TmuxManager(dryRun: true))
            .manualHibernate(terminalID: terminal.id)
        #expect(result == .ok)
        #expect(try await db.terminals.get(id: terminal.id)?.hibernatedAt != nil)
    }

    /// The flag's untouched state is a refusal, and that is asserted against
    /// the column rather than against the Swift constant: a migration that
    /// backfilled `0`, or a `toModel` that resolved NULL through something
    /// other than `Config.holderHibernationEnabledDefault`, would both still
    /// read `false` here — but so would a default that had been flipped without
    /// anyone noticing, which is what this pins.
    @Test("an untouched install refuses to park a holder row")
    func theShippedDefaultRefusesAHolderPark() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        let before = RowFingerprint(terminal)

        #expect(
            try await db.config.get().holderHibernationEnabled == false,
            "the shipped default must be off; nothing here touched the column")

        let result = await coordinator(
            db, tmux: TmuxManager(dryRun: true),
            registry: holderRegistry(listing: [terminal])
        ).manualHibernate(terminalID: terminal.id)
        #expect(result == .notEligible(reason: HibernationCoordinator.holderTransportRefusal))

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(RowFingerprint(after) == before,
                "a park refused by the shipped default still mutated the holder row")
    }

    /// The gate's ON branch. The park is reached — which is the point — and
    /// stops at the fail-closed screen rail, because this registry adopted
    /// nothing and so is not this session's reader.
    ///
    /// That refusal is the whole rail stated without a live holder. It is the
    /// no-reader half: this registry has adopted nothing, so the daemon holds
    /// no emulator to judge. The viewer half answers with its own name
    /// (`holderViewerAttachedRefusal`) because the remedies differ — one is a
    /// tab to close, the other is a session the daemon has lost track of —
    /// while the underlying rule is one rule: the daemon cannot see the screen
    /// it would have to judge, so it fails closed. The row fingerprint is what
    /// proves the park stopped BEFORE the intent was written rather than
    /// after.
    @Test("with the flag on a holder row is hibernatable and reaches the screen rail")
    func flagOnMakesAHolderRowHibernatable() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setHolderHibernationEnabled(true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        let before = RowFingerprint(terminal)

        #expect(terminal.isManuallyHibernatable(holderHibernationEnabled: true))
        #expect(terminal.isAutoHibernationEligible(holderHibernationEnabled: true))

        let result = await coordinator(
            db, tmux: TmuxManager(dryRun: true),
            registry: holderRegistry(listing: [terminal])
        ).manualHibernate(terminalID: terminal.id)
        #expect(
            result == .notEligible(
                reason: HibernationCoordinator.holderNoReaderRefusal),
            "the park did not reach the screen rail: \(result)")
        #expect(
            HibernationCoordinator.holderNoReaderRefusal
                != HibernationCoordinator.holderViewerAttachedRefusal,
            "the two halves of the screen rail collapsed back into one string")

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(RowFingerprint(after) == before,
                "a park refused at the screen rail still wrote its intent to the row")
    }

    /// The registry is not optional decoration: with none wired there is no
    /// reader to write `/exit` to and no way to abandon the holder afterwards,
    /// so the park says so by name rather than parking a row whose process
    /// nothing in this daemon could end.
    @Test("with the flag on and no registry the park refuses by name")
    func flagOnWithoutARegistryRefusesByName() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setHolderHibernationEnabled(true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        let before = RowFingerprint(terminal)

        let result = await coordinator(db, tmux: TmuxManager(dryRun: true))
            .manualHibernate(terminalID: terminal.id)
        #expect(result == .notEligible(reason: "this daemon has no holder registry"))

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(RowFingerprint(after) == before)
    }

    @Test("the auto and merge rails both name the holder transport as the blocker")
    func autoAndMergeRailsRefuseHolderRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)

        let now = Date()
        // Idle for an hour with the sweep armed: every other rail passes, so
        // `.eligible` is what this row gets without the transport gate.
        #expect(HibernationGate.decide(
            terminal: terminal, autoHibernateEnabled: true,
            holderHibernationEnabled: false, idleTimeout: 60,
            idleSince: now.addingTimeInterval(-3600), now: now) == .holderTransport)
        #expect(HibernationGate.decideForMerge(
            terminal: terminal, inputVetoEnabled: false,
            holderHibernationEnabled: false, lastInputAt: nil) == .holderTransport)
    }

    /// The same two rails with the flag on: a holder row that passes every
    /// other rail is `.eligible`, which is what makes the flag-off assertions
    /// above about the flag rather than about some unrelated blocker.
    @Test("with the flag on the auto and merge rails elect a holder row")
    func autoAndMergeRailsElectAHolderRowWithTheFlagOn() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)

        let now = Date()
        #expect(HibernationGate.decide(
            terminal: terminal, autoHibernateEnabled: true,
            holderHibernationEnabled: true, idleTimeout: 60,
            idleSince: now.addingTimeInterval(-3600), now: now) == .eligible)
        #expect(HibernationGate.decideForMerge(
            terminal: terminal, inputVetoEnabled: false,
            holderHibernationEnabled: true, lastInputAt: nil) == .eligible)
    }

    @Test("the auto and merge rails still elect an identical tmux row")
    func autoAndMergeRailsStillElectTmuxRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .tmux)

        let now = Date()
        #expect(HibernationGate.decide(
            terminal: terminal, autoHibernateEnabled: true,
            holderHibernationEnabled: false, idleTimeout: 60,
            idleSince: now.addingTimeInterval(-3600), now: now) == .eligible)
        #expect(HibernationGate.decideForMerge(
            terminal: terminal, inputVetoEnabled: false,
            holderHibernationEnabled: false, lastInputAt: nil) == .eligible)
    }

    // MARK: - Gate 3: wake

    /// The flag gates new parks, not the wake of a row that is already parked.
    ///
    /// Turning the flag off is the soak's abort gesture, and an abort that
    /// stranded what the soak parked would be no abort at all: the app's
    /// focus-wake would fire a failing RPC on every focus, forever. So a parked
    /// holder row must reach the holder wake mechanic with the flag OFF — and
    /// the way to state that without a live `TBDHolder` is the same refusal the
    /// flag-on test uses, a registry that cannot spawn. `.respawnFailed` is
    /// therefore the PROOF: `.holderTransport` here would mean the gate is
    /// still above the parked check.
    @Test("with the flag off a wake of a parked holder row still reaches the holder mechanic")
    func flagOffWakeOfAParkedHolderRowProceedsPastTheGate() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        #expect(try await db.config.get().holderHibernationEnabled == false,
                "the fixture armed the flag it was meant to leave off")
        try await db.terminals.setHibernated(
            id: terminal.id, sessionID: "sess-holdergate", reason: .manual)
        let before = RowFingerprint(try #require(try await db.terminals.get(id: terminal.id)))
        #expect(before.hibernatedAt != nil)

        let registry = holderRegistry(listing: [terminal])
        #expect(registry.canSpawn == false, "the fixture wired a spawner it was not meant to")

        // The recorded child names nothing, so the wake goes on to spawn — and
        // then refuses for the one reason this fixture can state.
        let result = await coordinator(
            db, tmux: tmux, registry: registry, signaller: deadChildSignaller())
            .wake(terminalID: terminal.id)
        guard case .respawnFailed(let reason) = result else {
            Issue.record("expected .respawnFailed — the flag still gates a parked wake, got \(result)")
            return
        }
        #expect(reason.contains("TBDHolder"))

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(after.isParked, "a failed wake un-parked the row")
        #expect(RowFingerprint(after) == before,
                "a failed wake mutated the holder row")
        #expect(recorded.snapshot().isEmpty,
                "the holder wake path reached tmux: \(recorded.snapshot())")
    }

    /// The other side of the same gate: an UNPARKED holder row with the flag
    /// off is refused by name, mutating nothing and asking the process table
    /// nothing. This is what keeps the move above from being a removal — the
    /// flag still decides whether this install classifies a holder row at all.
    @Test("with the flag off a wake of an unparked holder row is refused by name")
    func flagOffWakeOfAnUnparkedHolderRowIsRefused() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        let before = RowFingerprint(terminal)
        #expect(before.hibernatedAt == nil && before.suspendedAt == nil)

        let result = await coordinator(db, tmux: tmux).wake(terminalID: terminal.id)
        #expect(result == .holderTransport)

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(RowFingerprint(after) == before,
                "a refused wake still mutated the holder row")
        #expect(recorded.snapshot().isEmpty,
                "wake reached tmux for a holder row: \(recorded.snapshot())")
    }

    @Test("wake still un-parks an identical tmux row")
    func wakeStillUnparksTmuxRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .tmux)
        try await db.terminals.setHibernated(
            id: terminal.id, sessionID: "sess-holdergate", reason: .manual)

        let result = await coordinator(db, tmux: tmux).wake(terminalID: terminal.id)
        #expect(result == .ok)
        #expect(try await db.terminals.get(id: terminal.id)?.isParked == false)
        #expect(!recorded.snapshot().isEmpty, "the tmux leg must still drive tmux")
    }

    /// The wake gate's ON branch, stopped at the one refusal a fixture can
    /// state without a live `TBDHolder`: this registry has no spawner, which is
    /// the shape a daemon has when its helper binary has moved.
    ///
    /// "Registry present" is not "can spawn" — a daemon whose helper is missing
    /// still builds a registry, because adopting a running holder needs no
    /// executable — and the row staying parked is what proves the wake refused
    /// rather than half-ran.
    @Test("with the flag on a wake that cannot spawn a holder leaves the row parked")
    func flagOnWakeWithoutASpawnerLeavesTheRowParked() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setHolderHibernationEnabled(true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        try await db.terminals.setHibernated(
            id: terminal.id, sessionID: "sess-holdergate", reason: .manual)
        let before = RowFingerprint(try #require(try await db.terminals.get(id: terminal.id)))

        let registry = holderRegistry(listing: [terminal])
        #expect(registry.canSpawn == false, "the fixture wired a spawner it was not meant to")

        let result = await coordinator(
            db, tmux: tmux, registry: registry, signaller: deadChildSignaller())
            .wake(terminalID: terminal.id)
        guard case .respawnFailed(let reason) = result else {
            Issue.record("expected .respawnFailed, got \(result)")
            return
        }
        #expect(reason.contains("TBDHolder"))

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(after.isParked, "a refused wake un-parked the row")
        #expect(RowFingerprint(after) == before,
                "a refused wake mutated the holder row")
        #expect(recorded.snapshot().isEmpty,
                "the holder wake path reached tmux: \(recorded.snapshot())")
    }

    /// A retried wake of a row whose holder is ALREADY running adopts it.
    ///
    /// The state under test is the one a wake leaves behind when its pid write
    /// lands and its `clearHibernated` does not: the row reads parked while
    /// naming a live holder and a live child. The periodic reconcile sweep
    /// skips parked rows and `reconcileOnStartup` only runs at daemon boot, so
    /// until this guard existed every retry in between spawned a SECOND agent
    /// onto the same session and abandoned the first, which no reconciler could
    /// then reach — the reaper's holder leg sweeps by the pids a row carries,
    /// and the row had just been made to carry the third generation's.
    ///
    /// The registry deliberately cannot spawn, and that is the discriminator
    /// rather than a limitation of the fixture: a wake that reached the spawn
    /// would answer `.respawnFailed` here, so `.ok` can only mean it stopped
    /// short of one. The pids surviving unchanged says the same thing from the
    /// row's side.
    @Test("a wake of a row parked over a live holder adopts it instead of spawning again")
    func wakeAdoptsAHolderThatIsAlreadyRunning() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setHolderHibernationEnabled(true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }

        // An hour-old child, anchored on the row's recorded start rather than
        // on `createdAt`: the shape a session woken a while ago has.
        let childStartedAt = Date().addingTimeInterval(-3600)
        let signaller = FakeProcessSignaller()
        signaller.behaviors[9109] = .init(aliveInitially: true)
        signaller.startTimes[9109] = childStartedAt
        signaller.cmdlines[9109] = Self.holderChildCommand

        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder,
            childPID: 9109, holderChildStartedAt: childStartedAt)
        try await db.terminals.setHibernated(
            id: terminal.id, sessionID: "sess-holdergate", reason: .manual)

        let registry = holderRegistry(listing: [terminal])
        #expect(registry.canSpawn == false, "the fixture wired a spawner it was not meant to")

        let result = await coordinator(
            db, tmux: tmux, registry: registry, signaller: signaller)
            .wake(terminalID: terminal.id)
        #expect(result == .ok,
                "a row parked over a live holder was not adopted")

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(!after.isParked, "the adopted row was left parked")
        #expect(after.holderPID == 9101, "adoption re-identified the holder")
        #expect(after.childPID == 9109, "adoption re-identified the child")
        #expect(after.holderChildStartedAt != nil,
                "adoption forgot the identity anchor the next check needs")
        #expect(recorded.snapshot().isEmpty,
                "the holder wake path reached tmux: \(recorded.snapshot())")
    }

    /// The other verdict on the same row: a recorded child that names nothing
    /// is not a holder to adopt, so the wake goes on to spawn one — and this
    /// fixture's registry cannot, which leaves the row parked.
    ///
    /// Without this leg the guard above would be indistinguishable from one
    /// that un-parks every parked holder row it is handed.
    @Test("a wake whose recorded child is gone still spawns, and the row stays parked")
    func wakeWithADeadChildStillSpawns() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setHolderHibernationEnabled(true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }

        let childStartedAt = Date().addingTimeInterval(-3600)
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder,
            childPID: 9109, holderChildStartedAt: childStartedAt)
        try await db.terminals.setHibernated(
            id: terminal.id, sessionID: "sess-holdergate", reason: .manual)
        let before = RowFingerprint(try #require(try await db.terminals.get(id: terminal.id)))

        let registry = holderRegistry(listing: [terminal])
        let result = await coordinator(
            db, tmux: tmux, registry: registry, signaller: deadChildSignaller(9109))
            .wake(terminalID: terminal.id)
        guard case .respawnFailed(let reason) = result else {
            Issue.record("expected .respawnFailed — a dead child must not be adopted, got \(result)")
            return
        }
        #expect(reason.contains("TBDHolder"))

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(after.isParked, "a wake that could not spawn un-parked the row")
        #expect(RowFingerprint(after) == before, "a failed wake mutated the holder row")
        #expect(recorded.snapshot().isEmpty,
                "the holder wake path reached tmux: \(recorded.snapshot())")
    }

    /// The tmux leg of the same guard: a parked tmux row is judged by its
    /// window, never by the process table, so a signaller scripted to report a
    /// perfect identity changes nothing about how it wakes.
    @Test("a parked tmux row still wakes through tmux whatever the process table says")
    func parkedTmuxRowIsUnaffectedByTheAdoptGuard() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setHolderHibernationEnabled(true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Scripted alive with an unimpeachable identity, and the row is given
        // the pids to match — a shape a tmux row would never really carry, and
        // deliberately so: without them the process table says nothing about
        // this row and the test could not tell a transport-blind guard from a
        // correct one. With them, a guard that stopped discriminating on
        // transport would adopt this row and drive no tmux at all.
        let childStartedAt = Date()
        let signaller = FakeProcessSignaller()
        signaller.behaviors[9109] = .init(aliveInitially: true)
        signaller.startTimes[9109] = childStartedAt
        signaller.cmdlines[9109] = Self.holderChildCommand

        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@7", tmuxPaneID: "%7",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-holdergate",
            kind: .claude, transport: .tmux,
            holderPID: 9101, childPID: 9109, holderChildStartedAt: childStartedAt)
        try await db.terminals.setHibernated(
            id: terminal.id, sessionID: "sess-holdergate", reason: .manual)

        let result = await coordinator(db, tmux: tmux, signaller: signaller)
            .wake(terminalID: terminal.id)
        #expect(result == .ok)
        #expect(try await db.terminals.get(id: terminal.id)?.isParked == false)
        #expect(!recorded.snapshot().isEmpty,
                "the tmux leg must still drive tmux to wake a parked row")
    }

    // MARK: - Gate 4: terminal.swapProfile, .inPlace

    @Test("an in-place profile swap refuses a holder row and leaves every column alone")
    func inPlaceSwapRefusesHolderRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        let before = RowFingerprint(terminal)

        let response = await router(db, tmux: tmux).handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: terminal.id, newProfileID: nil, mode: .inPlace)))

        #expect(!response.success)
        #expect(response.error == RPCRouter.holderInPlaceSwapRefusal(terminalID: terminal.id))

        // The row is the whole point. Unguarded, `inPlaceSwapRespawn` commits
        // the replacement identity — a fresh `sessionIncarnationID`, the new
        // profile — BEFORE it asks tmux for anything, and only then fails
        // against `tmuxWindowID == ""`. A test that read the error string alone
        // would go green against exactly that bug.
        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(RowFingerprint(after) == before,
                "a refused in-place swap still committed a new identity to the holder row")
        // The other half a return value cannot see: the graceful interrupt that
        // precedes the respawn addresses `tmuxPaneID == ""`, so the real
        // process is never interrupted while the row is being told it was.
        #expect(recorded.snapshot().isEmpty,
                "the in-place swap reached tmux for a holder row: \(recorded.snapshot())")
    }

    @Test("an in-place profile swap still respawns an identical tmux row")
    func inPlaceSwapStillActsOnTmuxRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .tmux)
        let before = RowFingerprint(terminal)

        let response = await router(db, tmux: tmux).handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: terminal.id, newProfileID: nil, mode: .inPlace)))

        #expect(response.success, "error: \(response.error ?? "nil")")
        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(after.sessionIncarnationID != before.sessionIncarnationID,
                "the tmux leg must still commit a replacement incarnation")
        #expect(recorded.snapshot().contains { $0.contains("respawn-window") },
                "the tmux leg must still respawn its window: \(recorded.snapshot())")
    }

    // MARK: - Gate 5: terminal.delete — the one that acts

    @Test("delete disposes a holder row's holder instead of killing a tmux window")
    func deleteDisposesHolderInsteadOfKillingAWindow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        // `childPID: 0` deliberately. It is the one value `HolderRegistry`'s
        // disposal refuses to signal, and every other value a fixture could
        // name is a pid this shared box may really be running. What is under
        // test here is that the router hands the row to `abandon` at all; the
        // `forget`-then-kill inside it is the registry's own contract, covered
        // by the suites that run a real holder.
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder, childPID: 0)
        let registry = holderRegistry(listing: [terminal])
        // Arm the registry with a fact only `abandon` clears. No holder answers
        // at the derived rendezvous, so the startup sweep records the session as
        // having ended with an unknown status — and that recorded status is what
        // separates "the row went away" from "the holder was disposed of".
        _ = await registry.adoptAll()
        let armed = await registry.lastKnownStatus(for: terminal.id)
        #expect(armed == .exitedStatusUnknown, "the fixture never armed the observable")

        let router = router(db, tmux: tmux)
        router.holderRegistry = registry
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalDelete,
            params: TerminalDeleteParams(terminalID: terminal.id)))

        #expect(response.success, "error: \(response.error ?? "nil")")
        #expect(try await db.terminals.get(id: terminal.id) == nil)
        let disposed = await registry.lastKnownStatus(for: terminal.id)
        #expect(disposed == nil,
                "delete removed the row without disposing of its holder, so the holder, its child and its rendezvous files are now owned by nothing")
        // The mirror of the assertion above: the tmux branch is not merely
        // useless for this row, taking it is what leaves the holder behind.
        #expect(recorded.snapshot().isEmpty,
                "delete reached tmux for a holder row: \(recorded.snapshot())")
    }

    // MARK: - Gate 6: terminal.delete's activity rails — the one that was OFF

    /// A busy holder session used to be closeable without `--force`.
    ///
    /// Not corruption and not a leak: a safety rail that silently stopped
    /// applying. The rail refuses to close a `.working` row, but qualifies that
    /// on the session being alive so a row wedged at `.working` by a crash stays
    /// closeable — and it asked tmux that question for every row. A holder row's
    /// window id is the empty string, `windowExists` answers `false`, and
    /// `false` is exactly the answer that switches the rail off.
    @Test("the close rails refuse a busy holder session, and dispose nothing")
    func closeRailsRefuseBusyHolderSession() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder, childPID: 0)
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .working, source: .derived)
        let busy = try #require(try await db.terminals.get(id: terminal.id))
        let before = RowFingerprint(busy)

        // A registry that has recorded nothing about this session: no sweep has
        // run, so nothing has said the job ended. That is the state a live
        // holder is in, and it is also the state a holder owned by another
        // installation is left in, which is why the leg reads "no recorded
        // ending" as running rather than requiring a positive `.alive`.
        let router = router(db, tmux: tmux)
        router.holderRegistry = holderRegistry(listing: [busy])
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalDelete,
            params: TerminalDeleteParams(terminalID: terminal.id, respectActivityRails: true)))

        #expect(!response.success)
        #expect(response.errorCode == RPCErrorCode.terminalBusy.rawValue,
                "the CLI maps the code to exit 2 without parsing prose")
        #expect(response.error?.contains("--force") == true,
                "the message must name the escape hatch")
        // The row is the assertion, not the error string: a rail that refused
        // and tore down anyway would be a worse bug than the one it replaces.
        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(RowFingerprint(after) == before,
                "a refused close still mutated the holder row")
        #expect(recorded.snapshot().isEmpty,
                "the close rails reached tmux for a holder row: \(recorded.snapshot())")
    }

    /// A holder that nothing answers for is a holder that is GONE, and that is
    /// not the same fact as the job it forked being gone.
    ///
    /// `adoptAll`'s catch-all records `exitedStatusUnknown` for exactly that
    /// state, and the name is the whole point: nobody collected a status. The
    /// holder's death hangs its job up, and a job that ignores `SIGHUP` — the
    /// `nohup` shape `HolderTeardownGroupKillTests` already exercises on the
    /// disposal path — survives it as an orphan. Nothing re-adopts a row nobody
    /// calls `adopt()` on again, so the status sticks for the daemon's whole
    /// lifetime. A safety rail must fail CLOSED on that: when we cannot
    /// establish the job stopped, the confirmation is what the rail is for.
    @Test("the close rails refuse a busy holder row whose holder is unreachable")
    func closeRailsRefuseHolderRowWithUnknownExit() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder, childPID: 0)
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .working, source: .derived)
        let busy = try #require(try await db.terminals.get(id: terminal.id))
        let before = RowFingerprint(busy)

        let registry = holderRegistry(listing: [busy])
        // Nothing answers at the derived rendezvous, so the startup sweep
        // records the session as ended with an unknown status.
        _ = await registry.adoptAll()
        let ended = await registry.lastKnownStatus(for: terminal.id)
        #expect(ended == .exitedStatusUnknown, "the fixture never armed the unknown status")

        let router = router(db, tmux: tmux)
        router.holderRegistry = registry
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalDelete,
            params: TerminalDeleteParams(terminalID: terminal.id, respectActivityRails: true)))

        #expect(!response.success)
        #expect(response.errorCode == RPCErrorCode.terminalBusy.rawValue,
                "the CLI maps the code to exit 2 without parsing prose")
        #expect(response.error?.contains("--force") == true,
                "the message must name the escape hatch")
        // The row is the assertion, not the error string: the bug this closes
        // is a teardown that happened without the confirmation, and only the
        // row can see that.
        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(RowFingerprint(after) == before,
                "a refused close still mutated the holder row")
        #expect(recorded.snapshot().isEmpty,
                "the close rails reached tmux for a holder row: \(recorded.snapshot())")
    }

    /// The escape hatch the refusal above names, on the holder transport. A
    /// user who genuinely lost a holder is not trapped: `--force` drops the
    /// rails (the CLI sends no `respectActivityRails` at all), and the row —
    /// and the holder teardown that goes with it — proceeds as before.
    @Test("--force still closes a busy holder row whose holder is unreachable")
    func forceClosesHolderRowWithUnknownExit() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder, childPID: 0)
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .working, source: .derived)
        let busy = try #require(try await db.terminals.get(id: terminal.id))

        let registry = holderRegistry(listing: [busy])
        _ = await registry.adoptAll()
        #expect(await registry.lastKnownStatus(for: terminal.id) == .exitedStatusUnknown,
                "the fixture never armed the unknown status")

        let router = router(db, tmux: tmux)
        router.holderRegistry = registry
        // `--force` is the absence of the rails flag, not a second flag: see
        // `TerminalCommands`, which sends `force ? nil : true`.
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalDelete,
            params: TerminalDeleteParams(terminalID: terminal.id)))

        #expect(response.success, "error: \(response.error ?? "nil")")
        #expect(response.errorCode == nil)
        #expect(try await db.terminals.get(id: terminal.id) == nil)
    }

    /// Every status the holder leg can be handed, including the one no
    /// in-process fixture can arrange: `.exited` is recorded only by a holder
    /// that really collected an exit status, so the RPC-level legs above cannot
    /// reach it. It is also the leg that keeps the fix from being too broad —
    /// a real observed exit must still close without `--force`, and only
    /// `.exitedStatusUnknown` moved.
    @Test("the holder leg treats an unknown status as unknown, not as exited")
    func holderLivenessReadsUnknownStatusAsUnknown() {
        #expect(RPCRouter.activityRailLiveness(holderStatus: .exited(code: 0)) == .stopped)
        #expect(RPCRouter.activityRailLiveness(holderStatus: .exited(code: 137)) == .stopped)
        #expect(RPCRouter.activityRailLiveness(holderStatus: .exitedStatusUnknown) == .unknown)
        #expect(RPCRouter.activityRailLiveness(holderStatus: .alive) == .running)
        #expect(RPCRouter.activityRailLiveness(holderStatus: nil) == .running)
    }

    /// The refusal has to say WHY it is refusing, or a user whose holder is
    /// genuinely gone reads "would kill in-flight work" about a session they
    /// have every reason to believe is dead and is left guessing why `--force`
    /// became necessary.
    @Test("the unknown-liveness refusal names the missing fact, not just the rail")
    func unknownLivenessRefusalNamesTheMissingFact() {
        let id = UUID()
        let unknown = RPCRouter.closeRailsRefusal(
            terminalID: id, activityState: .working, liveness: .unknown)
        let running = RPCRouter.closeRailsRefusal(
            terminalID: id, activityState: .working, liveness: .running)

        #expect(unknown.contains("--force"), "the message must name the escape hatch")
        #expect(unknown.contains("holder"), "the message must name what is actually gone")
        #expect(unknown.contains("SIGHUP"), "the message must name why that is not enough")
        #expect(unknown != running,
                "an unknown liveness must not be reported as a known-live session")
        #expect(running.contains("--force"))
    }

    @Test("the close rails still refuse a busy tmux row whose window is alive")
    func closeRailsStillRefuseBusyTmuxRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        // The dry-run default reports every window ALIVE, which is the tmux
        // state this leg is about.
        let tmux = TmuxManager(dryRun: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .tmux)
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .working, source: .derived)

        let router = router(db, tmux: tmux)
        // Wired in and listing nothing, so an inverted transport comparison
        // would consult a registry that has never heard of this row rather than
        // a nil that would make the holder branch unreachable either way.
        router.holderRegistry = holderRegistry(listing: [])
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalDelete,
            params: TerminalDeleteParams(terminalID: terminal.id, respectActivityRails: true)))

        #expect(!response.success)
        #expect(response.errorCode == RPCErrorCode.terminalBusy.rawValue)
        #expect(try await db.terminals.get(id: terminal.id) != nil)
    }

    /// The leg that would redden if the transport comparison were inverted.
    /// Its window is dead and its registry has recorded nothing, so the tmux
    /// branch answers "not running" (close) while the holder branch would
    /// answer "running" (refuse) — the two legs disagree here and nowhere else.
    @Test("the close rails still release a busy tmux row whose window is dead")
    func closeRailsReleaseBusyTmuxRowWithDeadWindow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .tmux)
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .working, source: .derived)

        let router = router(db, tmux: tmux)
        router.holderRegistry = holderRegistry(listing: [])
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalDelete,
            params: TerminalDeleteParams(terminalID: terminal.id, respectActivityRails: true)))

        #expect(response.success, "error: \(response.error ?? "nil")")
        #expect(try await db.terminals.get(id: terminal.id) == nil)
    }

    @Test("delete still kills an identical tmux row's window")
    func deleteStillKillsTmuxWindow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .tmux)
        // Wired in and listing nothing, so an inverted transport comparison
        // would reach a registry that has never heard of this row rather than a
        // nil that would have made the branch unreachable either way.
        let registry = holderRegistry(listing: [])
        let router = router(db, tmux: tmux)
        router.holderRegistry = registry

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalDelete,
            params: TerminalDeleteParams(terminalID: terminal.id)))

        #expect(response.success, "error: \(response.error ?? "nil")")
        #expect(try await db.terminals.get(id: terminal.id) == nil)
        let argv = recorded.snapshot()
        #expect(argv.contains { $0.contains("kill-window") && $0.contains("@7") },
                "the tmux leg must still kill its own window: \(argv)")
    }

    // MARK: - Gate 10: the one mechanic that is routed rather than refused

    /// `app.setMainAreaSize` fans a new terminal size out over every terminal
    /// on an active worktree. For a holder row it called
    /// `resizeWindow(windowID: "")`, whose failure `try?` swallowed — so the
    /// session kept the size it was spawned with while the app's main area
    /// moved out from under it, and the daemon's emulator (what
    /// `terminal.output` renders) kept the old grid too.
    ///
    /// This gate is the one that does NOT refuse. The holder transport can
    /// answer this question: `HolderReader.resize` reshapes the emulator and
    /// sets the pty's window size, which is both halves of what the tmux call
    /// was for. Refusing a mechanic the transport can serve would remove a
    /// working feature rather than close a hole.
    ///
    /// What these two tests pin is the branch: a holder row no longer reaches
    /// tmux, and a tmux row still does. That the reader is then actually
    /// resized needs a real `TBDHolder` to observe and belongs in
    /// `TBDDaemonLiveTests` — here `reader(for:)` answers nil, which is also
    /// the un-adopted case the branch must survive without throwing.
    @Test("setMainAreaSize does not reach tmux for a holder row")
    func setMainAreaSizeSkipsTmuxForHolderRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        let before = RowFingerprint(terminal)

        let router = router(db, tmux: tmux)
        router.holderRegistry = holderRegistry(listing: [terminal])
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.setMainAreaSize,
            params: SetMainAreaSizeParams(cols: 120, rows: 40)))

        #expect(response.success, "error: \(response.error ?? "nil")")
        #expect(recorded.snapshot().contains { $0.contains("resize-window") } == false,
                "setMainAreaSize resized a tmux window for a holder row: \(recorded.snapshot())")
        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(RowFingerprint(after) == before)
    }

    @Test("setMainAreaSize still resizes an identical tmux row's window")
    func setMainAreaSizeStillResizesTmuxRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await seedClaudeTerminal(db, worktreeID: wt.id, transport: .tmux)

        let router = router(db, tmux: tmux)
        // Wired in and listing nothing, so an inverted transport comparison
        // reaches a registry that has never heard of this row rather than a nil
        // that would make the branch unreachable either way.
        router.holderRegistry = holderRegistry(listing: [])
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.setMainAreaSize,
            params: SetMainAreaSizeParams(cols: 120, rows: 40)))

        #expect(response.success, "error: \(response.error ?? "nil")")
        let argv = recorded.snapshot()
        #expect(argv.contains { $0.contains("resize-window") && $0.contains("@7") },
                "the tmux leg must still resize its own window: \(argv)")
    }

    // MARK: - Gate 9: the two verbs that refused for the wrong reason

    /// `terminal.send` and `terminal.attachCommand` both consult the pane
    /// before acting, and both got `.missing` for a holder row — `tmuxPaneID`
    /// is the empty string, so no line in tmux's answer can match it. Neither
    /// typed or composed anything, so neither was *unsafe*; both told the
    /// caller a live session's pane "no longer exists", and `attachCommand`
    /// said it under the `terminalSessionGone` code the app reads as a window
    /// worth recovering.
    ///
    /// `attachCommand` therefore changes no outcome: it replaces a safe lie
    /// with an accurate refusal, so the message, the error code and the
    /// actuation record name the transport rather than blaming a coordinate
    /// that was never stale. A holder session has no tmux session to attach to.
    ///
    /// `terminal.send` no longer refuses at all. It delivers, by writing the
    /// session's pty rather than a pane — the tests below are what the old
    /// refusal test became — and it keeps a refusal only for the two shapes
    /// this transport genuinely cannot serve, each naming its own missing
    /// capability instead of the transport.

    /// Records the bytes a holder send reached the pty with, standing in for
    /// the daemon's own descriptor. `viewerAttachment` answers nil, so these
    /// tests exercise the detached route: nobody is attached to a session
    /// seeded straight into the database.
    private final class HolderWrites: @unchecked Sendable {
        private let lock = NSLock()
        private var written: [Data] = []
        var all: [Data] { lock.withLock { written } }
        func courier() -> HolderInjectionCourier {
            HolderInjectionCourier(
                sendFrame: { _ in Issue.record("a detached session must not reach the app") },
                viewerAttachment: { _ in nil },
                writeDirectly: { [self] _, bytes in
                    lock.withLock { written.append(bytes) }
                })
        }
    }

    @Test("terminal.send types into a holder row without touching tmux")
    func sendDeliversToHolderRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        let before = RowFingerprint(terminal)
        let writes = HolderWrites()

        let rpc = router(db, tmux: tmux)
        rpc.holderInjectionCourier = writes.courier()
        let response = await rpc.handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: terminal.id, text: "hello", submit: true)))

        #expect(response.success, "error: \(response.error ?? "nil")")
        // Asserted on the COMPOSED output, not on a spot check: one message
        // carrying the dispatch envelope, the caller's text verbatim, and the
        // carriage return that submits it — in that order and with nothing
        // else in it.
        let message = try #require(writes.all.first)
        let text = try #require(String(data: message, encoding: .utf8))
        #expect(writes.all.count == 1, "the whole send must be one write, not two")
        #expect(text.hasPrefix("<tbd-dispatch id="))
        #expect(text.hasSuffix("/>\nhello\r"))
        // This router has neither an oracle seam nor a registry, so nothing
        // could answer what modes the child is in — and the send proceeded
        // anyway, bare, recording that it was a guess made blind. Refusing
        // instead would make every rail's send fail closed whenever the daemon
        // cannot see a store, which is precisely when rails need to send.
        let outcome = try #require(await Self.outcomeRow(of: rpc))
        #expect(outcome["modeSource"] as? String == "unavailable")
        #expect(outcome["modeAgeMilliseconds"] == nil,
                "an unavailable oracle has no store whose age could be recorded")
        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(RowFingerprint(after) == before)
        // The strongest half: delivery sits ahead of the whole tmux mechanic,
        // so nothing about the send is addressed to a pane that never existed.
        #expect(recorded.snapshot().isEmpty,
                "terminal.send reached tmux for a holder row: \(recorded.snapshot())")
    }

    // MARK: - Gate 10: the child's modes decide the bytes

    /// The oracle seam, standing in for a registry-backed reader.
    ///
    /// Reaching the three answers through a real registry would mean a real
    /// holder, a real pty and a real attach for what is a pure question about
    /// which bytes get composed. The registry-backed resolution is exercised
    /// live; this is how the composition's own branches are pinned.
    private func oracle(
        bracketedPaste: Bool,
        source: TerminalScreen.Source = .daemon,
        ageMilliseconds: Int = 0
    ) -> @Sendable (UUID) async -> TerminalModeReading? {
        { _ in
            TerminalModeReading(
                modes: TerminalScreen.ChildModes(
                    bracketedPaste: bracketedPaste,
                    applicationCursor: false,
                    alternateScreen: false),
                source: source,
                ageMilliseconds: ageMilliseconds)
        }
    }

    /// The outcome row this router last wrote, read back off its own actuation
    /// log. The provenance is asserted **on the row** rather than on a log
    /// line, because the row is what a person reading the record afterwards
    /// actually has.
    private static func outcomeRow(of rpc: RPCRouter) async -> [String: Any]? {
        let path = await rpc.actuationLog.path
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var rows: [[String: Any]] = []
        for line in contents.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let row = object as? [String: Any]
            else { continue }
            rows.append(row)
        }
        return rows.last { $0["kind"] as? String == "outcome" }
    }

    /// The defect this closes, at the router level: with the child in
    /// bracketed-paste mode the whole message — envelope and body together —
    /// goes inside one explicit paste, and the submitting `\r` follows the end
    /// marker. Still one write, so the message is never split across a routing
    /// decision.
    @Test("a send to a bracketing child is one wrapped paste with the Enter outside it")
    func sendWrapsForABracketingChild() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(db, worktreeID: wt.id, transport: .holder)
        let writes = HolderWrites()

        let rpc = router(db, tmux: deadWindowTmux(recorded))
        rpc.holderInjectionCourier = writes.courier()
        rpc.holderModeOracle = oracle(bracketedPaste: true, source: .daemon, ageMilliseconds: 0)
        let response = await rpc.handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: terminal.id, text: "hello", submit: true)))

        #expect(response.success, "error: \(response.error ?? "nil")")
        #expect(writes.all.count == 1, "the whole send must be one write, not two")
        let written = try #require(writes.all.first)
        let text = try #require(String(data: written, encoding: .utf8))
        #expect(text.hasPrefix("\u{1b}[200~<tbd-dispatch id="))
        #expect(text.hasSuffix("/>\nhello\u{1b}[201~\r"))
        #expect(
            text.components(separatedBy: "\u{1b}[200~").count == 2,
            "the start marker appears more than once: \(text.debugDescription)")

        let outcome = try #require(await Self.outcomeRow(of: rpc))
        #expect(outcome["result"] as? String == "dispatched")
        #expect(outcome["modeSource"] as? String == "daemon")
        #expect(outcome["modeAgeMilliseconds"] as? Int == 0)
        #expect(recorded.snapshot().isEmpty)
    }

    /// The other direction, and it is not symmetry for its own sake: a shell at
    /// its prompt, or any program that never asked for bracketing, prints
    /// markers it does not understand and would execute a line starting with
    /// one.
    @Test("a send to a non-bracketing child is bare bytes and an Enter")
    func sendStaysBareForANonBracketingChild() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(db, worktreeID: wt.id, transport: .holder)
        let writes = HolderWrites()

        let rpc = router(db, tmux: deadWindowTmux(recorded))
        rpc.holderInjectionCourier = writes.courier()
        rpc.holderModeOracle = oracle(bracketedPaste: false)
        let response = await rpc.handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: terminal.id, text: "hello", submit: true)))

        #expect(response.success, "error: \(response.error ?? "nil")")
        let written = try #require(writes.all.first)
        let text = try #require(String(data: written, encoding: .utf8))
        #expect(text.hasSuffix("/>\nhello\r"))
        #expect(!text.contains("\u{1b}[200~"))
        #expect(!text.contains("\u{1b}[201~"))
        #expect(recorded.snapshot().isEmpty)
    }

    /// The residue of the whole design, made examinable. When a viewer holds
    /// the pty and does not answer, the daemon composes against the modes its
    /// retained emulator held at the attach and **proceeds** — and records that
    /// it guessed, and how old the guess was. A row reading `staleDaemon` at 41
    /// minutes tells whoever reads the record afterwards exactly that.
    @Test("a send composed against a stale emulator records its source and age")
    func sendRecordsStaleProvenance() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(db, worktreeID: wt.id, transport: .holder)
        let writes = HolderWrites()

        let rpc = router(db, tmux: deadWindowTmux(recorded))
        rpc.holderInjectionCourier = writes.courier()
        rpc.holderModeOracle = oracle(
            bracketedPaste: true, source: .staleDaemon, ageMilliseconds: 2_460_000)
        let response = await rpc.handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: terminal.id, text: "hello", submit: true)))

        #expect(response.success, "a stale oracle must not refuse the send")
        // Composed per the stale modes, not bare: proceeding means acting on
        // what the emulator says, not falling back to a safe-looking default.
        let written = try #require(writes.all.first)
        let text = try #require(String(data: written, encoding: .utf8))
        #expect(text.hasPrefix("\u{1b}[200~"))
        #expect(text.hasSuffix("\u{1b}[201~\r"))

        let outcome = try #require(await Self.outcomeRow(of: rpc))
        #expect(outcome["result"] as? String == "dispatched")
        // Spelled exactly as `TerminalScreen.Source.staleDaemon` encodes, so a
        // supervisor can match the row against the screen it read.
        #expect(outcome["modeSource"] as? String == "staleDaemon")
        #expect(outcome["modeAgeMilliseconds"] as? Int == 2_460_000)
    }

    /// A caller with something to say whose message composes to nothing, and
    /// the row still says what it was composed against.
    ///
    /// `--text $'\e[201~'` with no `--submit` against a bracketing child is the
    /// second way to reach an empty message: the composition strips the end
    /// marker — a caller's own marker would otherwise close the paste — and
    /// what is left is empty, so nothing is written. The composition happened
    /// all the same, and its provenance is a fact about the attempt, so the row
    /// carries the source it asked. Only `--text ""` composes against nothing
    /// and has nothing to disclose.
    ///
    /// A **shell** row, because the dispatch envelope goes only to agent
    /// sessions: prepended, it would leave a non-empty body and this case could
    /// not be reached at all.
    @Test("a body that strips to nothing still records what it was composed against")
    func strippedToNothingStillRecordsProvenance() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.shell, kind: .shell, transport: .holder,
            holderPID: 9101, childPID: 9102)
        let writes = HolderWrites()

        let rpc = router(db, tmux: deadWindowTmux(recorded))
        rpc.holderInjectionCourier = writes.courier()
        rpc.holderModeOracle = oracle(bracketedPaste: true, source: .daemon, ageMilliseconds: 0)
        let response = await rpc.handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: terminal.id, text: "\u{1b}[201~", submit: false)))

        #expect(response.success, "error: \(response.error ?? "nil")")
        #expect(writes.all.isEmpty, "a message that composed to nothing must write nothing")
        let outcome = try #require(await Self.outcomeRow(of: rpc))
        #expect(outcome["result"] as? String == "dispatched")
        #expect(outcome["modeSource"] as? String == "daemon")
        #expect(outcome["modeAgeMilliseconds"] as? Int == 0)
    }

    @Test("terminal.send --verify refuses a holder row by naming verification")
    func sendVerifyRefusesHolderRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        let writes = HolderWrites()

        let rpc = router(db, tmux: tmux)
        rpc.holderInjectionCourier = writes.courier()
        let response = await rpc.handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: terminal.id, text: "hello", submit: true, verify: true)))

        #expect(!response.success)
        #expect(response.error == RPCRouter.holderVerifyRefusal(terminalID: terminal.id))
        // What is missing is the OBSERVATION, not the transport — a caller told
        // "this transport cannot be typed into" would stop trying.
        #expect(response.error?.contains("delivery observation") == true)
        #expect(writes.all.isEmpty, "a refused verify must type nothing")
        #expect(recorded.snapshot().isEmpty)
    }

    @Test("terminal.send --keys refuses a holder row by naming the missing key mapping")
    func sendKeysRefusesHolderRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        let writes = HolderWrites()

        let rpc = router(db, tmux: tmux)
        rpc.holderInjectionCourier = writes.courier()
        let response = await rpc.handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(terminalID: terminal.id, keys: "Escape Enter")))

        #expect(!response.success)
        #expect(response.error == RPCRouter.holderKeysRefusal(terminalID: terminal.id))
        #expect(writes.all.isEmpty, "a refused key send must type nothing")
        #expect(recorded.snapshot().isEmpty)
    }

    @Test("terminal.send tells a caller when this daemon has no holder input path")
    func sendWithoutCourierSaysSo() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)

        // No courier wired — mock mode, and every test that never exercises the
        // transport. The send must name that rather than appear to succeed.
        let response = await router(db, tmux: tmux).handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: terminal.id, text: "hello", submit: true)))

        #expect(!response.success)
        #expect(response.error == RPCRouter.holderInputUnavailable(terminalID: terminal.id))
        #expect(recorded.snapshot().isEmpty)
    }

    @Test("terminal.send still types into an identical tmux row")
    func sendStillActsOnTmuxRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        // The dry-run pane consultation answers "alive, carrying no identity",
        // which is the branch that proceeds.
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .tmux)

        let response = await router(db, tmux: tmux).handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: terminal.id, text: "hello", submit: true)))

        #expect(response.success, "error: \(response.error ?? "nil")")
        let argv = recorded.snapshot()
        #expect(argv.contains { $0.contains("paste-buffer") },
                "the tmux leg must still paste: \(argv)")
    }

    @Test("terminal.attachCommand refuses a holder row by name")
    func attachCommandRefusesHolderRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        let before = RowFingerprint(terminal)

        let response = await router(db, tmux: tmux).handle(try RPCRequest(
            method: RPCMethod.terminalAttachCommand,
            params: TerminalAttachCommandParams(
                worktreeID: wt.id, terminalID: terminal.id)))

        #expect(!response.success)
        #expect(response.error == RPCRouter.holderAttachRefusal(terminalID: terminal.id))
        // Not `terminalSessionGone`: that code is the app's cue to recover a
        // window, and this session has none to recover.
        #expect(response.errorCode != RPCErrorCode.terminalSessionGone.rawValue)
        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(RowFingerprint(after) == before)
        #expect(recorded.snapshot().isEmpty,
                "attachCommand reached tmux for a holder row: \(recorded.snapshot())")
    }

    @Test("terminal.attachCommand still composes a command for an identical tmux row")
    func attachCommandStillActsOnTmuxRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .tmux)

        let response = await router(db, tmux: tmux).handle(try RPCRequest(
            method: RPCMethod.terminalAttachCommand,
            params: TerminalAttachCommandParams(
                worktreeID: wt.id, terminalID: terminal.id)))

        #expect(response.success, "error: \(response.error ?? "nil")")
        let result = try response.decodeResult(TerminalAttachCommandResult.self)
        #expect(result.paneID == "%7")
        #expect(result.windowID == "@7")
    }

    // MARK: - Gate 8: the other teardowns that delete a row

    /// `terminal.delete` was never the only path that deletes a terminal row.
    /// Worktree archive, forget, `scratch.delete`/`scratch.archive` and the
    /// Watch Desk close all kill windows and then delete the rows, and every
    /// one of them leaked a holder for the same reason: `tmuxWindowID` is the
    /// empty string, so the kill addresses nothing while the holder, the job it
    /// forked and its rendezvous files outlive the row that was the only record
    /// of their pids. Nothing reclaims them until Milestone B's reconciler.
    ///
    /// The observable is the one the delete gate established: `adoptAll`
    /// records a status for a session nothing answers for, and `abandon` is the
    /// only thing that clears it. A row that simply vanished leaves it set.
    private func armedRegistry(
        listing terminals: [Terminal], for terminalID: UUID
    ) async throws -> HolderRegistry {
        let registry = holderRegistry(listing: terminals)
        _ = await registry.adoptAll()
        let armed = await registry.lastKnownStatus(for: terminalID)
        #expect(armed == .exitedStatusUnknown, "the fixture never armed the observable")
        return registry
    }

    private func lifecycle(
        _ db: TBDDatabase, tmux: TmuxManager, registry: HolderRegistry?
    ) -> WorktreeLifecycle {
        var lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver())
        lifecycle.holderRegistry = registry
        return lifecycle
    }

    @Test("archiving a worktree disposes its holder instead of killing a window")
    func archiveDisposesHolder() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        // `childPID: 0` for the same reason as the delete gate: it is the one
        // value the registry's disposal refuses to signal, and every other
        // value a fixture could name is a pid this shared box may be running.
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder, childPID: 0)
        let registry = try await armedRegistry(listing: [terminal], for: terminal.id)

        _ = try await lifecycle(db, tmux: tmux, registry: registry)
            .beginArchiveWorktree(worktreeID: wt.id)

        #expect(try await db.terminals.get(id: terminal.id) == nil,
                "archive is supposed to delete the row; the gate is about what goes with it")
        let disposed = await registry.lastKnownStatus(for: terminal.id)
        #expect(disposed == nil,
                "archive deleted the row without disposing of its holder, so the holder, its child and its rendezvous files are now owned by nothing")
        #expect(recorded.snapshot().isEmpty,
                "archive reached tmux for a holder row: \(recorded.snapshot())")
    }

    @Test("archiving a worktree still captures and kills an identical tmux row")
    func archiveStillKillsTmuxWindow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .tmux)
        // Wired in and listing nothing, so an inverted transport comparison
        // reaches a registry that has never heard of this row rather than a nil
        // that would make the branch unreachable either way.
        let registry = holderRegistry(listing: [])

        _ = try await lifecycle(db, tmux: tmux, registry: registry)
            .beginArchiveWorktree(worktreeID: wt.id)

        #expect(try await db.terminals.get(id: terminal.id) == nil)
        let argv = recorded.snapshot()
        #expect(argv.contains { $0.contains("kill-window") && $0.contains("@7") },
                "the tmux leg must still kill its own window: \(argv)")
    }

    @Test("forgetting a worktree disposes its holder instead of killing a window")
    func forgetDisposesHolder() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder, childPID: 0)
        let registry = try await armedRegistry(listing: [terminal], for: terminal.id)

        try await lifecycle(db, tmux: tmux, registry: registry)
            .forgetWorktree(worktreeID: wt.id)

        #expect(try await db.terminals.get(id: terminal.id) == nil)
        let disposed = await registry.lastKnownStatus(for: terminal.id)
        #expect(disposed == nil,
                "forget deleted the row without disposing of its holder, so the holder, its child and its rendezvous files are now owned by nothing")
        #expect(recorded.snapshot().isEmpty,
                "forget reached tmux for a holder row: \(recorded.snapshot())")
    }

    @Test("forgetting a worktree still kills an identical tmux row's window")
    func forgetStillKillsTmuxWindow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .tmux)
        let registry = holderRegistry(listing: [])

        try await lifecycle(db, tmux: tmux, registry: registry)
            .forgetWorktree(worktreeID: wt.id)

        #expect(try await db.terminals.get(id: terminal.id) == nil)
        let argv = recorded.snapshot()
        #expect(argv.contains { $0.contains("kill-window") && $0.contains("@7") },
                "the tmux leg must still kill its own window: \(argv)")
    }

    // MARK: - Gate 7: the auto-resume rail, which types without a user gesture

    /// Arms one pending resume row for `terminal` and returns it, with the
    /// governing toggle on — production only ever actuates a row that came
    /// from `scheduler.schedule()`, which always inserts first, and the
    /// actuator re-reads both facts on every eligibility pass.
    private func armedResume(
        _ db: TBDDatabase, terminal: Terminal
    ) async throws -> ScheduledResume {
        try await db.config.setAutoResumeOnLimitReset(true)
        let row = ScheduledResume(
            terminalID: terminal.id, worktreeID: terminal.worktreeID,
            claudeSessionID: terminal.claudeSessionID,
            resetsAt: Date().addingTimeInterval(-120),
            fireAt: Date().addingTimeInterval(-60),
            limitType: "session", rawMessage: "limit",
            createdAt: Date().addingTimeInterval(-3600))
        _ = try await db.scheduledResumes.insertPending(row)
        return row
    }

    /// An actuator whose every side effect is observable: no real sleeping, no
    /// transcript on disk, a tmux double that records the keys it is asked to
    /// type, and — when the caller passes one — a holder input path that
    /// records the bytes it is handed.
    ///
    /// `holderSend` defaults to nil, which is also what a daemon with no holder
    /// registry wires, so the flag-off tests below assert the flag and not an
    /// absent seam. `waiter` defaults to a no-op, so only the test that asserts
    /// on the pause between the holder arm's two writes records them.
    ///
    /// `holderSessionEnded` defaults to nil for the same reason `holderSend`
    /// does: that is what a daemon with no holder registry wires, so a test
    /// that says nothing about liveness is asserting on today's behaviour.
    private func resumeActuator(
        _ db: TBDDatabase, tmux: FakeResumeTmux,
        holderSend: (@Sendable (UUID, Data) async -> Bool)? = nil,
        holderSessionEnded: (@Sendable (UUID) async -> Bool)? = nil,
        waiter: @escaping @Sendable (Duration) async -> Void = { _ in }
    ) -> LimitResumeActuator {
        LimitResumeActuator(
            db: db, tmux: tmux, inspector: FakeInspector(claudePID: 4242),
            readTranscript: { _ in nil },
            transcriptModifiedAt: { _ in nil },
            waiter: waiter, actuationLog: makeTestActuationLog(),
            holderSend: holderSend,
            holderSessionEnded: holderSessionEnded)
    }

    /// The reproduction, on the answer a real tmux gives — and the shipped
    /// default, untouched.
    ///
    /// `windowExists(windowID: "")` is `false`, so the rail cancelled the
    /// user's armed auto-resume as `.terminalGone` — a silent cancel that
    /// records "the terminal is gone" for a session that is perfectly alive,
    /// and leaves nobody told. The refusal is now named, and `.failed` so the
    /// daemon's notification says so once.
    ///
    /// Nothing here sets `holder_hibernation_enabled`: the column is NULL,
    /// nobody has chosen, and `Config.holderHibernationEnabledDefault` decides
    /// — which is the state every install is in until someone opts into the
    /// soak. A holder input path is wired all the same, so what refuses is the
    /// flag and not an absent seam.
    @Test("auto-resume refuses a holder row by name under the shipped default")
    func autoResumeRefusesHolderRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shipped = try await db.config.get()
        #expect(shipped.holderHibernationEnabled == false,
                "the fixture is not in the default-off state this test is about")
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        let before = RowFingerprint(terminal)
        let resume = try await armedResume(db, terminal: terminal)

        let tmux = FakeResumeTmux()
        tmux.windowAlive = false   // what a real server answers for ""
        let holder = RecordedHolderWrites()
        let outcome = await resumeActuator(db, tmux: tmux, holderSend: holder.send)
            .actuate(resume)

        #expect(outcome == .failed(LimitResumeActuator.holderTransportRefusal),
                "expected the named refusal, got \(outcome)")
        #expect(tmux.sends.isEmpty)
        #expect(holder.writes().isEmpty,
                "the flag is off and the rail still wrote to the holder's pty")
        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(RowFingerprint(after) == before,
                "a refused auto-resume mutated the holder row")
    }

    /// The placement assertion: the guard sits ahead of the tmux question, not
    /// behind it.
    ///
    /// Every check between `windowExists` and the keys passes in this fixture —
    /// the pane answers alive and anonymous, Claude is foreground, copy-mode is
    /// off — so a guard placed after the window probe would let "continue" be
    /// typed at whatever the empty pane id resolves to. That is what makes the
    /// old behavior an accident rather than a safe default: it depended on
    /// `TmuxManager.windowExists` swallowing its error.
    @Test("auto-resume types nothing at a holder row with the flag explicitly off, even when tmux claims the window is alive")
    func autoResumeTypesNothingAtHolderRowWithLiveWindowAnswer() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Explicitly off: a chosen `0` rather than the NULL the test above
        // covers, which is the state a user who tried the soak and turned it
        // back off is in.
        try await db.config.setHolderHibernationEnabled(false)
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        let before = RowFingerprint(terminal)
        let resume = try await armedResume(db, terminal: terminal)

        let tmux = FakeResumeTmux()
        tmux.windowAlive = true
        let holder = RecordedHolderWrites()
        let outcome = await resumeActuator(db, tmux: tmux, holderSend: holder.send)
            .actuate(resume)

        #expect(outcome == .failed(LimitResumeActuator.holderTransportRefusal),
                "expected the named refusal, got \(outcome)")
        #expect(tmux.sends.isEmpty,
                "auto-resume typed into a holder row: \(tmux.sends)")
        #expect(holder.writes().isEmpty,
                "the flag is off and the rail still wrote to the holder's pty")
        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(RowFingerprint(after) == before)
    }

    /// The other branch of the same gate: with the flag on, the rail delivers
    /// the resume through the holder input path instead of refusing.
    ///
    /// Two writes with the tmux arm's 150 ms pause between them, asserted as
    /// one ordered log because the order is the property. ESC has to arrive in
    /// a read of its own: an ink-style parser reads ESC followed immediately by
    /// a printable byte as a meta key, so a single `ESC`+`continue`+`\r` write
    /// composes Alt-c and then "ontinue" every time, which no retry recovers.
    /// The second write keeps its carriage return — 9 bytes, under the 64 at
    /// which Claude Code's stdin tokenizer swallows an unwrapped `\r`.
    ///
    /// The bytes are spelled out here rather than compared against the
    /// actuator's own constants, because those constants are what this test
    /// exists to pin.
    @Test("auto-resume writes ESC, a pause, then continue + CR to a holder session with the flag on")
    func autoResumeWritesTheContinueMessageToHolderRowWithFlagOn() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await db.config.setHolderHibernationEnabled(true)
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        // The activity hook already reports working, so the first verification
        // poll succeeds without a transcript on disk — the same fixture the
        // tmux leg uses, because verification reads hook-fed state and the
        // transcript and so is the same code for both transports. It also
        // means verification never reaches its own `waiter` call, so every
        // pause in the log below belongs to the send.
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .working, source: .derived)
        let resume = try await armedResume(db, terminal: terminal)

        let tmux = FakeResumeTmux()
        // A holder row must not consult tmux either way; answering "alive"
        // makes that a real assertion rather than a refusal in disguise.
        tmux.windowAlive = true
        let holder = RecordedHolderWrites()
        let outcome = await resumeActuator(
            db, tmux: tmux, holderSend: holder.send, waiter: holder.waiter
        ).actuate(resume)

        #expect(outcome == .sent, "expected .sent, got \(outcome)")
        #expect(holder.snapshot() == [
            .write(terminalID: terminal.id, bytes: Data([0x1B])),
            .pause(.milliseconds(150)),
            .write(terminalID: terminal.id, bytes: Data("continue".utf8) + Data([0x0D])),
        ], "the holder arm's send was \(holder.snapshot())")
        #expect(tmux.sends.isEmpty,
                "the holder arm reached tmux: \(tmux.sends)")
    }

    /// Parking cancels the pending row, so this is the fire-time backstop for a
    /// park that raced the scheduler — and with the flag on, parking a holder
    /// row is something that can now happen. Same silent cancel as the tmux
    /// path: `.terminalGone`, nothing written.
    @Test("auto-resume writes nothing to a parked holder row with the flag on")
    func autoResumeLeavesParkedHolderRowAloneWithFlagOn() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await db.config.setHolderHibernationEnabled(true)
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        // Armed first, then parked: the order a park that raced the scheduler
        // actually happens in.
        let resume = try await armedResume(db, terminal: terminal)
        try await db.terminals.setHibernated(
            id: terminal.id, sessionID: "sess-holdergate", snapshot: nil)

        let tmux = FakeResumeTmux()
        tmux.windowAlive = true
        let holder = RecordedHolderWrites()
        let outcome = await resumeActuator(db, tmux: tmux, holderSend: holder.send)
            .actuate(resume)

        #expect(outcome == .terminalGone, "expected .terminalGone, got \(outcome)")
        #expect(holder.writes().isEmpty,
                "auto-resume wrote into a parked holder session")
        #expect(tmux.sends.isEmpty)
    }

    /// The holder arm's liveness answer, in the position `windowExists`
    /// occupies on the tmux arm and with the same silent cancel.
    ///
    /// Nothing had parked this row: its child simply ended. Without the seam
    /// the arm has no liveness question at all and types "continue" onto a pty
    /// nobody is reading, reporting an armed resume as delivered into a session
    /// that is over.
    @Test("auto-resume cancels silently when the holder reports the session over")
    func autoResumeCancelsWhenTheHolderSessionHasEnded() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await db.config.setHolderHibernationEnabled(true)
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .working, source: .derived)
        let resume = try await armedResume(db, terminal: terminal)

        let tmux = FakeResumeTmux()
        tmux.windowAlive = true
        let holder = RecordedHolderWrites()
        let outcome = await resumeActuator(
            db, tmux: tmux, holderSend: holder.send,
            holderSessionEnded: { _ in true }
        ).actuate(resume)

        #expect(outcome == .terminalGone, "expected .terminalGone, got \(outcome)")
        #expect(holder.writes().isEmpty,
                "auto-resume typed into a session its holder had reported over")
        #expect(tmux.sends.isEmpty)
    }

    /// The other answer. A seam that answered "ended" for everything would pass
    /// the test above while cancelling every armed resume on the transport, so
    /// this leg is what makes that one about the answer rather than about the
    /// seam's presence.
    @Test("auto-resume still sends when the holder reports the session live")
    func autoResumeSendsWhenTheHolderSessionIsLive() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await db.config.setHolderHibernationEnabled(true)
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .working, source: .derived)
        let resume = try await armedResume(db, terminal: terminal)

        let tmux = FakeResumeTmux()
        tmux.windowAlive = true
        let holder = RecordedHolderWrites()
        let outcome = await resumeActuator(
            db, tmux: tmux, holderSend: holder.send,
            holderSessionEnded: { _ in false }
        ).actuate(resume)

        #expect(outcome == .sent, "expected .sent, got \(outcome)")
        #expect(holder.writes() == [
            .write(terminalID: terminal.id, bytes: Data([0x1B])),
            .write(terminalID: terminal.id, bytes: Data("continue".utf8) + Data([0x0D])),
        ], "the holder arm's send was \(holder.snapshot())")
    }

    /// The seam absent. A daemon with no holder registry wires nil, and that
    /// must behave exactly as it did before the seam existed — asking nobody
    /// and proceeding to the courier, which fails by name if the session really
    /// is gone.
    @Test("auto-resume with no liveness seam sends exactly as it did before")
    func autoResumeWithoutALivenessSeamIsUnchanged() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await db.config.setHolderHibernationEnabled(true)
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .working, source: .derived)
        let resume = try await armedResume(db, terminal: terminal)

        let tmux = FakeResumeTmux()
        tmux.windowAlive = true
        let holder = RecordedHolderWrites()
        let outcome = await resumeActuator(
            db, tmux: tmux, holderSend: holder.send, holderSessionEnded: nil
        ).actuate(resume)

        #expect(outcome == .sent, "expected .sent, got \(outcome)")
        #expect(holder.writes() == [
            .write(terminalID: terminal.id, bytes: Data([0x1B])),
            .write(terminalID: terminal.id, bytes: Data("continue".utf8) + Data([0x0D])),
        ], "the holder arm's send was \(holder.snapshot())")
    }

    /// A courier that found no route answers no, and the rail says so by name
    /// rather than reporting the generic "no activity after 2 sends" — and it
    /// does not try again, because the courier has already exhausted its own
    /// routes by the time it answers.
    ///
    /// A refused Escape also stops the sequence there: no pause, and no
    /// "continue" typed at a session that did not take the Escape.
    @Test("auto-resume fails by name when the holder input path refuses the Escape")
    func autoResumeFailsByNameWhenHolderWriteIsRefused() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await db.config.setHolderHibernationEnabled(true)
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        let resume = try await armedResume(db, terminal: terminal)

        let tmux = FakeResumeTmux()
        let holder = RecordedHolderWrites(acceptedWrites: 0)
        let outcome = await resumeActuator(
            db, tmux: tmux, holderSend: holder.send, waiter: holder.waiter
        ).actuate(resume)

        #expect(outcome == .failed(LimitResumeActuator.holderWriteRefused),
                "expected the named write failure, got \(outcome)")
        #expect(holder.snapshot() == [.write(terminalID: terminal.id, bytes: Data([0x1B]))],
                "a refused Escape was followed by more: \(holder.snapshot())")
        #expect(tmux.sends.isEmpty)
    }

    /// The other half of the same failure: the Escape lands, the text does not.
    /// Same named failure, and still no retry — a half-delivered send is not a
    /// send, and the courier that refused the second write would refuse it
    /// again by the same route.
    @Test("auto-resume fails by name when the holder input path refuses the continue text")
    func autoResumeFailsByNameWhenHolderSecondWriteIsRefused() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await db.config.setHolderHibernationEnabled(true)
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        let resume = try await armedResume(db, terminal: terminal)

        let tmux = FakeResumeTmux()
        let holder = RecordedHolderWrites(acceptedWrites: 1)
        let outcome = await resumeActuator(
            db, tmux: tmux, holderSend: holder.send, waiter: holder.waiter
        ).actuate(resume)

        #expect(outcome == .failed(LimitResumeActuator.holderWriteRefused),
                "expected the named write failure, got \(outcome)")
        #expect(holder.snapshot() == [
            .write(terminalID: terminal.id, bytes: Data([0x1B])),
            .pause(.milliseconds(150)),
            .write(terminalID: terminal.id, bytes: Data("continue".utf8) + Data([0x0D])),
        ], "the send was retried or reshaped: \(holder.snapshot())")
        #expect(tmux.sends.isEmpty)
    }

    /// The flag is on, the row is a holder row, and this daemon has no way to
    /// write to a holder's pty at all (mock mode, or no registry to build a
    /// courier on). A different refusal from the flag's, because it is a
    /// different repair.
    @Test("auto-resume fails by name when the daemon has no holder input path")
    func autoResumeFailsByNameWithNoHolderInputPath() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await db.config.setHolderHibernationEnabled(true)
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        let before = RowFingerprint(terminal)
        let resume = try await armedResume(db, terminal: terminal)

        let tmux = FakeResumeTmux()
        tmux.windowAlive = true
        let outcome = await resumeActuator(db, tmux: tmux, holderSend: nil).actuate(resume)

        #expect(outcome == .failed(LimitResumeActuator.holderInputPathMissing),
                "expected the named missing-path failure, got \(outcome)")
        #expect(tmux.sends.isEmpty,
                "a daemon with no holder input path fell back to typing at tmux: \(tmux.sends)")
        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(RowFingerprint(after) == before)
    }

    /// The tmux leg. An inverted transport comparison would disable auto-resume
    /// for the transport that still has a pane to type into.
    @Test("auto-resume still types the continue sequence into a tmux row")
    func autoResumeStillActsOnTmuxRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .tmux)
        // The activity hook already reports working, so the first verification
        // poll succeeds without a transcript on disk.
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .working, source: .derived)
        let resume = try await armedResume(db, terminal: terminal)

        let tmux = FakeResumeTmux()
        tmux.windowAlive = true
        let outcome = await resumeActuator(db, tmux: tmux).actuate(resume)

        #expect(outcome == .sent, "expected .sent, got \(outcome)")
        #expect(tmux.sends == ["key:Escape", "text:continue", "key:Enter"])
    }

    /// The tmux leg of the flag itself. `holder_hibernation_enabled` decides
    /// how a HOLDER row is resumed and nothing about a tmux one: with it on, a
    /// tmux row still gets the three-key sequence through `send-keys` and the
    /// holder input path is never touched.
    @Test("auto-resume still types the continue sequence into a tmux row with holder hibernation on")
    func autoResumeStillActsOnTmuxRowWithHolderHibernationOn() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await db.config.setHolderHibernationEnabled(true)
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .tmux)
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .working, source: .derived)
        let resume = try await armedResume(db, terminal: terminal)

        let tmux = FakeResumeTmux()
        tmux.windowAlive = true
        let holder = RecordedHolderWrites()
        let outcome = await resumeActuator(db, tmux: tmux, holderSend: holder.send)
            .actuate(resume)

        #expect(outcome == .sent, "expected .sent, got \(outcome)")
        #expect(tmux.sends == ["key:Escape", "text:continue", "key:Enter"])
        #expect(holder.writes().isEmpty,
                "a tmux row was routed through the holder input path")
    }

    // MARK: - Gate 11: the idle sweep and a screen the daemon cannot read

    private func sweepLogPath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-holdergate-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("actuations.jsonl").path
    }

    private func logRows(at path: String) throws -> [[String: Any]] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return try contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try #require(
                    try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
    }

    /// A coordinator whose actuation record is a real file this test can count
    /// rows in, and whose date seam the test drives — the sweep's poll/decide
    /// sequence needs three passes and two elapsed windows, and none of that
    /// may cost wall time.
    private func sweepCoordinator(
        _ db: TBDDatabase, logPath: String, dates: TestDateSource,
        registry: HolderRegistry?
    ) async -> HibernationCoordinator {
        let coordinator = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            configDirManager: isolatedConfigDirManager(),
            now: dates.provider,
            exitPollAttempts: 1, exitPollInterval: .milliseconds(1),
            actuationLog: ActuationLog(path: logPath))
        await coordinator.setHolderRegistry(registry)
        return coordinator
    }

    /// Seed the idle marker, cross the idle window to arm the debounce, then
    /// let the settle window elapse so the rail reaches its act moment.
    private func sweepToTheActMoment(
        _ coord: HibernationCoordinator, dates: TestDateSource, idleMinutes: Int = 1
    ) async {
        await coord.sweep()
        dates.advance(by: TimeInterval(idleMinutes) * 60 + 1)
        await coord.sweep()
        dates.advance(by: HibernationCoordinator.killDebounce + 1)
        await coord.sweep()
    }

    /// The registry check the sweep makes before it arms or fires a holder row.
    ///
    /// `HibernationGate` is pure and cannot see who holds a pty, so a holder
    /// row whose screen the daemon cannot read still reaches `.eligible` — and
    /// `performHolderHibernate` then fails closed, but only after the sweep has
    /// written a request row and its refused outcome. On a tab the user is
    /// looking at that condition holds for as long as the tab is open, so the
    /// pair would be paid on every sweep forever. The assertion is therefore on
    /// the RECORD being empty, not on the row being unparked: the row is
    /// unparked either way, and only the record can tell "refused" from "never
    /// asked".
    @Test("the sweep neither arms nor fires a holder row whose screen it cannot read")
    func sweepSkipsAHolderRowTheDaemonIsNotReading() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setHolderHibernationEnabled(true)
        try await db.config.setAutoHibernate(enabled: true, idleMinutes: 1)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        let before = RowFingerprint(terminal)
        let logPath = try sweepLogPath()
        let dates = TestDateSource()
        // This registry adopted nothing, so it holds no reader for the session
        // — the same state a daemon is in while a viewer owns the pty, reached
        // without a live holder.
        let coord = await sweepCoordinator(
            db, logPath: logPath, dates: dates,
            registry: holderRegistry(listing: [terminal]))

        await sweepToTheActMoment(coord, dates: dates)
        // A fourth pass a whole window later. Resetting the markers must mean
        // "never fires while this holds", not "fires one sweep later".
        dates.advance(by: 61 + HibernationCoordinator.killDebounce + 1)
        await coord.sweep()

        let written = try logRows(at: logPath)
        #expect(written.isEmpty,
                "the sweep asked for a park it could never have completed: \(written)")
        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(RowFingerprint(after) == before)
    }

    /// The other side of that check, and the marker half of the same fix.
    ///
    /// With no registry wired at all the sweep has nothing to ask, so it does
    /// arm and fire — which is what makes the assertion above about the
    /// registry answer rather than about holder rows being skipped wholesale.
    /// The park then refuses by name, and that refusal clears `idleSince` and
    /// `pendingKillSince` like every other refusal in the method: the next
    /// sweep, at the same instant with the debounce still long past, writes
    /// nothing. Leaving the markers armed would re-fire the identical refusal
    /// on every pass.
    @Test("with no registry the sweep fires once and the refusal clears its markers")
    func sweepFiresOnceWhenNoRegistryCanAnswer() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setHolderHibernationEnabled(true)
        try await db.config.setAutoHibernate(enabled: true, idleMinutes: 1)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        let logPath = try sweepLogPath()
        let dates = TestDateSource()
        let coord = await sweepCoordinator(
            db, logPath: logPath, dates: dates, registry: nil)

        await sweepToTheActMoment(coord, dates: dates)

        let afterAct = try logRows(at: logPath)
        #expect(afterAct.count == 2, "expected one request row and its outcome, got \(afterAct)")
        #expect(afterAct.first?["kind"] as? String == "hibernate")
        // The outcome's free-text slot is `error`, which is where
        // `ActuationOutcome.detail` puts a refusal reason.
        #expect(afterAct.last?["error"] as? String == "this daemon has no holder registry")

        await coord.sweep()
        let afterASecondPass = try logRows(at: logPath)
        #expect(afterASecondPass.count == 2,
                "the refusal left its markers armed, so the next sweep re-fired it: \(afterASecondPass)")
        #expect(try await db.terminals.get(id: terminal.id)?.isParked == false)
    }

    /// The transport leg. The registry question is asked of holder rows only —
    /// an inverted comparison would stop the idle sweep parking tmux sessions
    /// on any daemon that happens to have a registry wired.
    @Test("the sweep still parks an identical tmux row on a daemon with a registry")
    func sweepStillParksATmuxRowWithARegistryWired() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setHolderHibernationEnabled(true)
        try await db.config.setAutoHibernate(enabled: true, idleMinutes: 1)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .tmux)
        let logPath = try sweepLogPath()
        let dates = TestDateSource()
        let coord = await sweepCoordinator(
            db, logPath: logPath, dates: dates,
            registry: holderRegistry(listing: [terminal]))

        await sweepToTheActMoment(coord, dates: dates)

        #expect(try await db.terminals.get(id: terminal.id)?.isParked == true)
        let written = try logRows(at: logPath)
        #expect(written.count == 2, "expected one request row and its outcome, got \(written)")
        #expect(written.last?["result"] as? String == "dispatched")
    }
}
