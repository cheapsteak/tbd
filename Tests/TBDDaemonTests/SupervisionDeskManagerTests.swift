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
        func markDead(_ windowID: String) { lock.withLock { _ = dead.insert(windowID) } }
        func isDead(_ windowID: String) -> Bool { lock.withLock { dead.contains(windowID) } }
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

    private static func makeFixture() throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-supervision-desk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let deadWindows = DeadWindows()
        let tmux = TmuxManager(
            dryRun: true, dryRunWindowIsDead: { deadWindows.isDead($0) })
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
        guard let data = FileManager.default.contents(atPath: fixture.actuationPath) else {
            return []
        }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap {
                try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
            }
            .compactMap { $0["kind"] as? String }
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
        let worktree = try await fixture.db.worktrees.getLocal(id: entry.worktree)
        #expect(worktree?.worktree.repoID == nil)
        #expect(worktree?.path.hasPrefix(TBDConstants.scratchDir.path) == true)

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
