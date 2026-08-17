import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// `SupervisionDeskManager.ensureDesk` — the four branches of design §9's
/// hosted-desk lifecycle, and the one thing a spawn must never do.
///
/// Tier 2 — real filesystem and an in-memory database, tmux in `dryRun`, time
/// pinned through the date seam. Nothing here waits on wall time and nothing
/// reaches a real tmux server.
@Suite("Supervision desk lifecycle")
struct SupervisionDeskManagerTests {

    // MARK: - Fixture

    /// Thread-safe record of which windows the fixture should call dead.
    private final class DeadWindows: @unchecked Sendable {
        private let lock = NSLock()
        private var dead: Set<String> = []
        private var deadOnce: Set<String> = []
        func markDead(_ windowID: String) { lock.withLock { _ = dead.insert(windowID) } }

        /// Report the window dead on the **first** read and alive on every read
        /// after it. That is the seam that makes two reads of one desk differ:
        /// `isLive` is documented to answer "not live" to a read that merely
        /// glitched, and the recheck before the archive then sees the session
        /// that was there all along.
        func markDeadUntilFirstRead(_ windowID: String) {
            lock.withLock { _ = deadOnce.insert(windowID) }
        }

        func isDead(_ windowID: String) -> Bool {
            lock.withLock {
                if dead.contains(windowID) { return true }
                return deadOnce.remove(windowID) != nil
            }
        }
    }

    /// Something else touching the desk record, standing by to land mid-spawn.
    /// Armed after the fixture is built, because what it does is written in
    /// terms of the store the fixture created — and, for the reap, so it fires
    /// during one chosen spawn and not the one that set the record up.
    private final class ArmedHook: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (@Sendable () -> Void)?

        func arm(_ action: @escaping @Sendable () -> Void) {
            lock.withLock { self.action = action }
        }

        func run() { lock.withLock { action }?() }
    }

    /// Every delta a spawn broadcast, decoded. The app builds the sidebar out
    /// of these, so "the desk appears with its tab" is a property of the pair.
    private final class DeltaSink: @unchecked Sendable {
        private let lock = NSLock()
        private var received: [StateDelta] = []
        let subscriptions = StateSubscriptionManager()

        init() {
            subscriptions.addSubscriber { [self] data in
                if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                    lock.withLock { received.append(delta) }
                }
                return true
            }
        }

        var deltas: [StateDelta] { lock.withLock { received } }
    }

    private struct Fixture {
        let db: TBDDatabase
        let directory: URL
        let desks: SupervisionDesksStore
        let ledgerPath: String
        let actuationPath: String
        let dates: TestDateSource
        let deadWindows: DeadWindows
        let manager: SupervisionDeskManager
    }

    /// - Parameters:
    ///   - createWindowError: makes the real spawn throw, the way tmux refusing
    ///     a `new-window` does.
    ///   - duringSpawn: runs while the spawn is in flight — after `ensureDesk`
    ///     has read `desks.json` and before the record is written. It stands in
    ///     for a concurrent `SupervisionDeskCollector` reap, which rewrites that
    ///     same file per reap while the hourly sweep runs.
    ///   - spawnSession: replaces the spawn outright, for the one failing exit
    ///     the real one cannot produce.
    private static func makeFixture(
        createWindowError: (@Sendable (String) -> Error?)? = nil,
        duringSpawn: (@Sendable () -> Void)? = nil,
        spawnSession: SupervisionDeskSpawn? = nil,
        subscriptions: StateSubscriptionManager? = nil
    ) throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-supervision-desk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let deadWindows = DeadWindows()
        let recorder: (@Sendable ([String]) -> Void)?
        if let duringSpawn {
            recorder = { _ in duringSpawn() }
        } else {
            recorder = nil
        }
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: recorder,
            dryRunWindowIsDead: { deadWindows.isDead($0) },
            dryRunCreateWindowError: createWindowError)
        let desks = SupervisionDesksStore(
            fileURL: directory.appendingPathComponent("desks.json"))
        let ledgerPath = directory.appendingPathComponent("ledger.jsonl").path
        let actuationPath = directory.appendingPathComponent("actuations.jsonl").path
        let dates = TestDateSource()

        return Fixture(
            db: db,
            directory: directory,
            desks: desks,
            ledgerPath: ledgerPath,
            actuationPath: actuationPath,
            dates: dates,
            deadWindows: deadWindows,
            manager: SupervisionDeskManager(
                db: db,
                lifecycle: WorktreeLifecycle(
                    db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
                tmux: tmux,
                desks: desks,
                ledger: SupervisionLedgerWriter(path: ledgerPath),
                actuationLog: ActuationLog(path: actuationPath),
                subscriptions: subscriptions,
                spawnSession: spawnSession,
                now: dates.provider))
    }

    private static func inputs(
        project: String = "acme-web", appointed: SupervisionSupervisorBinding? = nil,
        playbook: String = "# Conduct\n"
    ) -> SupervisionDeskInputs {
        SupervisionDeskInputs(
            project: project, mode: "attended",
            playbook: SupervisionPlaybook(
                project: project, tier: .shipped, path: nil, bytes: Data(playbook.utf8)),
            appointed: appointed)
    }

    private static func ledgerEvents(_ fixture: Fixture) -> [SupervisionLifecycleEvent] {
        guard let data = FileManager.default.contents(atPath: fixture.ledgerPath) else { return [] }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { try? JSONDecoder().decode(SupervisionLedgerLine.self, from: Data($0)) }
            .compactMap { $0.payload.event }
    }

    /// Every actuation row this fixture's rail wrote, as `(kind, result)`. The
    /// assertion behind "a spawn delivers nothing": a nudge would show up here
    /// as a `send`.
    private static func actuationKinds(_ fixture: Fixture) -> [String] {
        actuationRows(fixture).compactMap { $0["kind"] as? String }
    }

    private static func actuationRows(_ fixture: Fixture) -> [[String: Any]] {
        guard let data = FileManager.default.contents(atPath: fixture.actuationPath) else {
            return []
        }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap {
                try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
            }
    }

    /// The one scratch row this fixture's spawn created. Read out of the
    /// database rather than off `TBDConstants.scratchDir`, whose resolver reads
    /// `TBD_HOME` — a serialized suite elsewhere in the process can move that
    /// between the spawn and the assertion.
    private static func onlyScratchRow(_ fixture: Fixture) async throws -> Worktree {
        let rows = try await fixture.db.worktrees.listScratch()
        #expect(rows.count == 1)
        return try #require(rows.first)
    }

    // MARK: - Spawn

    @Test("A project with no desk gets one, recorded by id, with a spawn line")
    func spawnsWhenNoDeskExists() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome = try await fixture.manager.ensureDesk(project: Self.inputs())
        guard case .spawned(let entry) = outcome else {
            Issue.record("expected a spawn, got \(outcome)")
            return
        }
        // The record is by id and the terminal really exists.
        let terminal = try await fixture.db.terminals.get(id: entry.terminal)
        #expect(terminal != nil)
        // A scratch space: a `repoID == nil` row, named for what it is.
        // Deliberately not asserted against `TBDConstants.scratchDir` — that
        // resolver reads `TBD_HOME`, which a serialized suite elsewhere in the
        // process can move between the spawn and the assertion.
        let worktree = try await fixture.db.worktrees.getLocal(id: entry.worktree)
        #expect(worktree?.worktree.repoID == nil)
        #expect(worktree?.worktree.name.hasPrefix("supervision-desk") == true)

        #expect(try fixture.desks.load().desk(for: "acme-web") == entry)
        #expect(Self.ledgerEvents(fixture) == [.deskSpawned])
    }

    @Test("A spawn delivers nothing — no message, no nudge, no opening prompt")
    func spawnDeliversNothing() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await fixture.manager.ensureDesk(project: Self.inputs())

        // A quiet project's desk idles at zero token cost: the opening material
        // rides the first briefing. A nudge would appear here as a `send` row,
        // because every payload into a session is recorded before it is sent.
        let kinds = Self.actuationKinds(fixture)
        #expect(kinds.allSatisfy { $0 == "spawn" || $0 == "outcome" })
        #expect(!kinds.contains("send"))
        // And the desk's own worktree row carries no parked prompt.
        let entry = try #require(try fixture.desks.load().desk(for: "acme-web"))
        let worktree = try await fixture.db.worktrees.getLocal(id: entry.worktree)
        #expect(worktree?.worktree.pendingPrompt == nil)
    }

    @Test("A spawn announces the scratch space AND its terminal")
    func spawnBroadcastsBothDeltas() async throws {
        let sink = DeltaSink()
        let fixture = try Self.makeFixture(subscriptions: sink.subscriptions)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome = try await fixture.manager.ensureDesk(project: Self.inputs())
        guard case .spawned(let entry) = outcome else {
            Issue.record("expected a spawn, got \(outcome)")
            return
        }

        // The row delta alone puts the desk in the sidebar with no tabs under
        // it until the next full state refresh. `scratch.create` sends the
        // pair for the same reason.
        #expect(sink.deltas.contains {
            if case .worktreeCreated(let delta) = $0 { return delta.worktreeID == entry.worktree }
            return false
        })
        #expect(sink.deltas.contains {
            if case .terminalCreated(let delta) = $0 {
                return delta.terminalID == entry.terminal && delta.worktreeID == entry.worktree
            }
            return false
        })
    }

    @Test("The desk's conduct hash is the resolved playbook's")
    func recordsTheConductHash() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let playbook = "# Conduct\n\nEscalate instead of guessing.\n"
        _ = try await fixture.manager.ensureDesk(
            project: Self.inputs(playbook: playbook))
        let entry = try #require(try fixture.desks.load().desk(for: "acme-web"))
        #expect(entry.conductHash == SupervisionPlaybook.hash(of: Data(playbook.utf8)))
    }

    @Test("A Codex-preferring fleet still gets a Claude desk, and keeps its preference")
    func codexPreferenceStillSpawnsAClaudeDesk() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        // The whole fleet prefers Codex. A supervisor is the one exception:
        // its standing conduct rides `--append-system-prompt`, which only the
        // Claude spawn path carries, so a Codex desk would launch with no
        // conduct at all.
        try await fixture.db.config.setPrimaryAgentPreference(.codex)

        let outcome = try await fixture.manager.ensureDesk(project: Self.inputs())
        guard case .spawned(let entry) = outcome else {
            Issue.record("expected a spawn, got \(outcome)")
            return
        }
        let terminal = try #require(try await fixture.db.terminals.get(id: entry.terminal))
        #expect(terminal.kind == .claude)
        #expect(terminal.label == TerminalLabel.claudeCode)
        // Forcing the adapter for this one session changes nothing about the
        // fleet: every other spawn still reads Codex out of the config.
        #expect(try await fixture.db.config.get().primaryAgentPreference == .codex)
    }

    // MARK: - A spawn that fails hands the scratch space back

    @Test("A spawn that throws archives its scratch row, and still records the outcome")
    func thrownSpawnArchivesTheScratchSpace() async throws {
        struct TmuxRefused: Error {}
        let fixture = try Self.makeFixture(createWindowError: { _ in TmuxRefused() })
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        await #expect(throws: SupervisionDeskError.self) {
            try await fixture.manager.ensureDesk(project: Self.inputs())
        }

        // `SupervisionDeskCollector` walks `desks.json`, and no entry was ever
        // written — so unless the row is archived here, nothing reclaims the
        // directory. `.archived` is exactly the shape `OrphanGC`'s
        // deletion-queue leg already takes.
        #expect(try fixture.desks.load().desk(for: "acme-web") == nil)
        let scratch = try await Self.onlyScratchRow(fixture)
        #expect(scratch.status == .archived)

        // The rail still says what it tried and what came back.
        let rows = Self.actuationRows(fixture)
        #expect(rows.contains { $0["kind"] as? String == "spawn" })
        #expect(rows.contains {
            $0["kind"] as? String == "outcome" && $0["result"] as? String == "transport-failed"
        })
    }

    @Test("A spawn that creates no terminal archives its scratch row too")
    func terminallessSpawnArchivesTheScratchSpace() async throws {
        // The one failing exit the real spawn cannot produce:
        // `spawnPrimaryTerminals` always returns the primary terminal, so this
        // branch is held to its behaviour through the spawn seam.
        let fixture = try Self.makeFixture(spawnSession: { _, _ in [] })
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        await #expect(throws: SupervisionDeskError.self) {
            try await fixture.manager.ensureDesk(project: Self.inputs())
        }

        #expect(try fixture.desks.load().desk(for: "acme-web") == nil)
        let scratch = try await Self.onlyScratchRow(fixture)
        #expect(scratch.status == .archived)
        // The spawn itself reached the transport and reported no failure — the
        // outcome row says so, and the anomaly is that it produced nothing.
        let rows = Self.actuationRows(fixture)
        #expect(rows.contains {
            $0["kind"] as? String == "outcome" && $0["result"] as? String == "dispatched"
        })
    }

    @Test("A desk that cannot be written to the record hands its scratch space back too")
    func unrecordableDeskArchivesTheScratchSpace() async throws {
        // The record goes unreadable while the spawn is in flight, so the
        // write that follows cannot land. This is the exit that bites hardest:
        // the session is live and nothing recorded it, so the next `on` would
        // read no entry and spawn a second desk beside it.
        let hook = ArmedHook()
        let fixture = try Self.makeFixture(duringSpawn: { hook.run() })
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let url = fixture.desks.fileURL
        hook.arm { try? Data("{ not json".utf8).write(to: url) }

        await #expect(throws: SupervisionDeskError.self) {
            try await fixture.manager.ensureDesk(project: Self.inputs())
        }

        let scratch = try await Self.onlyScratchRow(fixture)
        #expect(scratch.status == .archived)
    }

    // MARK: - Recording a desk must not resurrect a reaped one

    @Test("A reap that lands mid-spawn survives the record: the desk file is re-read")
    func recordingRereadsBeforeSaving() async throws {
        // Seed a second project's desk, then drop it while `acme-web`'s spawn
        // is in flight — the sweep's read-modify-write per reap, arriving in
        // the seconds a spawn takes. Nothing here spawns concurrently: the
        // manager's gate serializes ensures, and the race being reproduced is
        // with the collector, which does not hold that gate.
        let armed = ArmedHook()
        let fixture = try Self.makeFixture(duringSpawn: { armed.run() })
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let seeded = try await fixture.manager.ensureDesk(
            project: Self.inputs(project: "seed-project"))
        guard case .spawned = seeded else {
            Issue.record("expected a spawn, got \(seeded)")
            return
        }
        #expect(try fixture.desks.load().desk(for: "seed-project") != nil)

        // Arm the reap only now, so it lands during the second spawn.
        let desks = fixture.desks
        armed.arm {
            guard let file = try? desks.load() else { return }
            try? desks.save(file.forgetting("seed-project"))
        }
        let outcome = try await fixture.manager.ensureDesk(project: Self.inputs())
        guard case .spawned(let entry) = outcome else {
            Issue.record("expected a spawn, got \(outcome)")
            return
        }

        let file = try fixture.desks.load()
        // The concurrent change survives. Writing back the copy read before
        // the spawn would resurrect it — and a resurrected entry whose worktree
        // the sweep already archived is kept by every later sweep
        // (`desk-already-archived`), so it would never be reclaimed again.
        #expect(file.desk(for: "seed-project") == nil)
        // And the new desk is recorded on top of the file as it now stands.
        #expect(file.desk(for: "acme-web") == entry)
    }

    // MARK: - Resume

    @Test("A live desk resumes as it stands; nothing is spawned and no line is written")
    func resumesALiveDesk() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let first = try await fixture.manager.ensureDesk(project: Self.inputs())
        guard case .spawned(let entry) = first else {
            Issue.record("expected a spawn, got \(first)")
            return
        }

        let outcome = try await fixture.manager.ensureDesk(project: Self.inputs())
        #expect(outcome == .resumed(entry))
        #expect(try fixture.desks.load().desk(for: "acme-web") == entry)
        // Still exactly one spawn line: resuming is not a decision to record.
        #expect(Self.ledgerEvents(fixture) == [.deskSpawned])
    }

    // MARK: - Replace

    @Test("A desk that died is replaced, and the line links successor to predecessor")
    func replacesADeadDesk() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let first = try await fixture.manager.ensureDesk(project: Self.inputs())
        guard case .spawned(let predecessor) = first else {
            Issue.record("expected a spawn, got \(first)")
            return
        }
        // The death nothing was watching for: a stood-down project's sweep is
        // not running, so the window simply goes away.
        let terminal = try #require(try await fixture.db.terminals.get(id: predecessor.terminal))
        fixture.deadWindows.markDead(terminal.tmuxWindowID)

        let outcome = try await fixture.manager.ensureDesk(project: Self.inputs())
        guard case .replaced(let successor, let recorded) = outcome else {
            Issue.record("expected a replacement, got \(outcome)")
            return
        }
        #expect(recorded == predecessor)
        #expect(successor.terminal != predecessor.terminal)
        #expect(try fixture.desks.load().desk(for: "acme-web") == successor)
        #expect(Self.ledgerEvents(fixture) == [.deskSpawned, .deskReplaced])

        // The line really names the predecessor.
        let data = try #require(FileManager.default.contents(atPath: fixture.ledgerPath))
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { try? JSONDecoder().decode(SupervisionLedgerLine.self, from: Data($0)) }
        guard case .deskReplaced(let desk, let previous, _) = lines[1].payload else {
            Issue.record("expected a deskReplaced payload")
            return
        }
        #expect(desk.terminal == successor.terminal)
        #expect(previous.terminal == predecessor.terminal)
    }

    @Test("Replacing a desk hands the predecessor's scratch space back")
    func replacementArchivesThePredecessorsScratchSpace() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let first = try await fixture.manager.ensureDesk(project: Self.inputs())
        guard case .spawned(let predecessor) = first else {
            Issue.record("expected a spawn, got \(first)")
            return
        }
        let terminal = try #require(try await fixture.db.terminals.get(id: predecessor.terminal))
        fixture.deadWindows.markDead(terminal.tmuxWindowID)

        let outcome = try await fixture.manager.ensureDesk(project: Self.inputs())
        guard case .replaced(let successor, _) = outcome else {
            Issue.record("expected a replacement, got \(outcome)")
            return
        }

        // Recording the successor overwrites the project's key, so from that
        // moment nothing references the predecessor's space: the collector
        // enumerates `desks.json` and reads the successor, and every other
        // sweep leg walks repo-backed or already-archived rows. Leaving it
        // `.active` would leak one scratch space per replacement, forever.
        let old = try #require(try await fixture.db.worktrees.get(id: predecessor.worktree))
        #expect(old.status == .archived)
        // And the desk that now serves the project is untouched.
        let live = try #require(try await fixture.db.worktrees.get(id: successor.worktree))
        #expect(live.status == .active)
        // Nothing was raised: handing back a desk that really is gone is the
        // quiet path, and the anomaly notification below must not fire here.
        let raised = try await fixture.db.notifications.unread(worktreeID: predecessor.worktree)
        #expect(raised.isEmpty)
    }

    @Test("A predecessor that reads live at the recheck keeps its scratch space")
    func livePredecessorIsNotArchived() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let first = try await fixture.manager.ensureDesk(project: Self.inputs())
        guard case .spawned(let predecessor) = first else {
            Issue.record("expected a spawn, got \(first)")
            return
        }
        let terminal = try #require(try await fixture.db.terminals.get(id: predecessor.terminal))
        // The window reads dead once and alive after: the transient read that
        // makes `isLive` say "not live" about a session that is running. A
        // whole spawn happens between that judgement and the archive, so the
        // archive must not inherit it.
        fixture.deadWindows.markDeadUntilFirstRead(terminal.tmuxWindowID)

        let outcome = try await fixture.manager.ensureDesk(project: Self.inputs())
        guard case .replaced(let successor, _) = outcome else {
            Issue.record("expected a replacement, got \(outcome)")
            return
        }

        // Archiving it would have taken the live session's tmux window with it:
        // `WorktreeLifecycle+Reconcile` computes tracked windows from
        // non-archived rows and kills the rest.
        let old = try #require(try await fixture.db.worktrees.get(id: predecessor.worktree))
        #expect(old.status == .active)
        // The decline is not silent — the operator is told on the very row that
        // is left behind, because nothing will reclaim it later.
        let raised = try await fixture.db.notifications.unread(worktreeID: predecessor.worktree)
        #expect(raised.count == 1)
        let message = try #require(raised.first?.message)
        #expect(message.contains("still live"))
        // The successor is unaffected either way: the project has a supervisor.
        let live = try #require(try await fixture.db.worktrees.get(id: successor.worktree))
        #expect(live.status == .active)
    }

    @Test("A predecessor that cannot be read as gone keeps its scratch space too")
    func undeterminedPredecessorIsNotArchived() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let first = try await fixture.manager.ensureDesk(project: Self.inputs())
        guard case .spawned(let predecessor) = first else {
            Issue.record("expected a spawn, got \(first)")
            return
        }
        // A parked desk is not live — nothing can be delivered to it — but it
        // is wakeable by design, so it is not evidence of a session that is
        // gone. Replacing it is right; archiving the space it can wake into is
        // not.
        try await fixture.db.terminals.setSuspended(
            id: predecessor.terminal, sessionID: UUID().uuidString)

        let outcome = try await fixture.manager.ensureDesk(project: Self.inputs())
        guard case .replaced = outcome else {
            Issue.record("expected a replacement, got \(outcome)")
            return
        }

        let old = try #require(try await fixture.db.worktrees.get(id: predecessor.worktree))
        #expect(old.status == .active)
        let raised = try await fixture.db.notifications.unread(worktreeID: predecessor.worktree)
        #expect(raised.count == 1)
        let message = try #require(raised.first?.message)
        #expect(message.contains("confidently"))
    }

    // MARK: - Appointment

    @Test("An appointed binding stands: no desk is spawned and nothing is recorded")
    func appointedBindingIsHonored() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        // Spawn one desk to borrow a live terminal from, then appoint it.
        let seeded = try await fixture.manager.ensureDesk(
            project: Self.inputs(project: "seed"))
        guard case .spawned(let seedEntry) = seeded else {
            Issue.record("expected a spawn, got \(seeded)")
            return
        }

        let outcome = try await fixture.manager.ensureDesk(project: Self.inputs(
            appointed: SupervisionSupervisorBinding(terminalID: seedEntry.terminal)))
        #expect(outcome == .appointed(terminal: seedEntry.terminal))
        // A mark is coverage, a binding is selection: `on` touches neither the
        // binding nor the hosted record.
        #expect(try fixture.desks.load().desk(for: "acme-web") == nil)
    }

    @Test("A dangling binding is reported, never silently replaced by a hosted desk")
    func danglingBindingIsNotTakenOver() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let gone = UUID()
        let outcome = try await fixture.manager.ensureDesk(project: Self.inputs(
            appointed: SupervisionSupervisorBinding(terminalID: gone)))
        guard case .danglingBinding(let terminal, _) = outcome else {
            Issue.record("expected a dangling binding, got \(outcome)")
            return
        }
        #expect(terminal == gone.uuidString)
        // The operator chose that supervisor and TBD does not unchoose it.
        #expect(try fixture.desks.load().desk(for: "acme-web") == nil)
        #expect(Self.ledgerEvents(fixture).isEmpty)
    }

    @Test("A binding that does not name a terminal id is dangling, not a crash")
    func bindingWithoutAnIDIsDangling() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome = try await fixture.manager.ensureDesk(project: Self.inputs(
            appointed: SupervisionSupervisorBinding(terminal: "not-a-uuid")))
        guard case .danglingBinding(let terminal, _) = outcome else {
            Issue.record("expected a dangling binding, got \(outcome)")
            return
        }
        #expect(terminal == "not-a-uuid")
    }
}
