import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// `terminal.migrateTransport` — the wire surface over the transport migrator.
///
/// The migrator's own composition is proved in `TerminalTransportMigratorTests`;
/// these tests drive it through the router with its operations replaced, so
/// what they prove is the handler: what it forwards, what it reports, and what
/// it broadcasts.
@Suite("terminal.migrateTransport RPC")
struct TerminalMigrateTransportRPCTests {

    /// What each row saw already published when its own move began.
    private actor PublicationObservations {
        private(set) var all: [UUID: [UUID]] = [:]
        func record(_ terminalID: UUID, _ publishedIDs: [UUID]) {
            all[terminalID] = publishedIDs
        }
    }

    /// Collects every delta the router publishes.
    private final class DeltaBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [StateDelta] = []
        func append(_ d: StateDelta) { lock.lock(); items.append(d); lock.unlock() }
        var all: [StateDelta] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private struct Fixture {
        let router: RPCRouter
        let db: TBDDatabase
        let worktreeID: UUID
        let deltas: DeltaBox
        let actuationLogPath: String

        /// Every row the record holds, as JSON objects.
        func actuationRows() throws -> [[String: Any]] {
            guard let contents = try? String(
                contentsOfFile: actuationLogPath, encoding: .utf8) else { return [] }
            return try contents
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { line in
                    try #require(try JSONSerialization.jsonObject(
                        with: Data(line.utf8)) as? [String: Any])
                }
        }
    }

    static let server = "tbd-test"

    /// Operations whose park parks the row for real (so the compare-and-set can
    /// succeed) and whose wake always answers `wakeResult`. `serverState`
    /// answers the tmux-server sighting for each live row; `canSpawnHolder` is
    /// the knob for the unspawnable refusal.
    private static func operations(
        db: TBDDatabase,
        canSpawnHolder: Bool = true,
        serverState: @escaping @Sendable (Terminal) async -> LeftoverTmuxServerState = { _ in .absent },
        wakeResult: WakeResult = .ok(sessionIncarnationID: nil)
    ) -> TerminalTransportMigrator.Operations {
        TerminalTransportMigrator.Operations(
            canSpawnHolder: { canSpawnHolder },
            tmuxServerSighting: { terminal in
                LeftoverTmuxServerSighting(server: server, state: await serverState(terminal))
            },
            parkLeftover: { terminal in
                try await db.terminals.setHibernated(
                    id: terminal.id, sessionID: "acme-session", reason: .recovery)
                return try await db.terminals.get(id: terminal.id)
            },
            wake: { _ in wakeResult },
            // The move's own composition is proved in
            // `RunningShellTransportMoveTests`; here it only has to land the
            // row on the holder, which is what the handler reads back and
            // broadcasts.
            moveRunningShell: { terminal in
                _ = try? await db.terminals.moveRunningShellToHolder(
                    id: terminal.id,
                    expectedState: TerminalReplacementSnapshot(terminal: terminal),
                    incarnationID: UUID(),
                    holderPID: 9201, childPID: 9202, startedAt: Date())
                return .moved
            })
    }

    private func makeFixture(
        canSpawnHolder: Bool = true,
        wakeResult: WakeResult = .ok(sessionIncarnationID: nil)
    ) async throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
        let actuationLogDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-actuation-migrate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: actuationLogDirectory, withIntermediateDirectories: true)
        let actuationLogPath = actuationLogDirectory
            .appendingPathComponent("actuations.jsonl").path
        let deltas = DeltaBox()
        let subs = StateSubscriptionManager()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(),
                tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            subscriptions: subs,
            actuationLog: ActuationLog(path: actuationLogPath))
        router.transportMigratorOperationsOverride = Self.operations(
            db: db, canSpawnHolder: canSpawnHolder, wakeResult: wakeResult)

        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "tbd/wt",
            path: "/tmp/acme-wt-\(UUID().uuidString)", tmuxServer: Self.server)
        return Fixture(
            router: router, db: db, worktreeID: worktree.id, deltas: deltas,
            actuationLogPath: actuationLogPath)
    }

    private func tmuxRow(
        _ f: Fixture, kind: TerminalKind = .claude, parked: Bool = false
    ) async throws -> Terminal {
        let created = try await f.db.terminals.create(
            worktreeID: f.worktreeID, tmuxWindowID: "@7", tmuxPaneID: "%7",
            label: "acme", claudeSessionID: kind == .claude ? "acme-session" : nil,
            kind: kind, transport: .tmux)
        if parked {
            try await f.db.terminals.setHibernated(
                id: created.id, sessionID: "acme-session", reason: .manual)
        }
        return try #require(try await f.db.terminals.get(id: created.id))
    }

    private func respond(_ f: Fixture, terminalID: UUID?) async throws -> RPCResponse {
        await f.router.handle(try RPCRequest(
            method: RPCMethod.terminalMigrateTransport,
            params: TerminalMigrateTransportParams(terminalID: terminalID)))
    }

    private func call(_ f: Fixture, terminalID: UUID?) async throws -> TerminalMigrateTransportResult {
        let response = try await respond(f, terminalID: terminalID)
        #expect(response.success, "error: \(response.error ?? "nil")")
        return try response.decodeResult(TerminalMigrateTransportResult.self)
    }

    private func replacedRows(_ f: Fixture) -> [Terminal] {
        f.deltas.all.compactMap {
            if case .terminalReplaced(let t) = $0 { return t } else { return nil }
        }
    }

    @Test("one session migrates through the RPC")
    func oneSessionMigratesThroughTheRPC() async throws {
        let f = try await makeFixture()
        let row = try await tmuxRow(f, parked: true)

        let result = try await call(f, terminalID: row.id)

        #expect(result.migrated == [row.id])
        #expect(result.skipped.isEmpty && result.refused.isEmpty)
        #expect(try await f.db.terminals.get(id: row.id)?.transport == .holder)
    }

    @Test("a fleet call carries every reason back, skips and refusals apart")
    func aFleetCallCarriesEveryReasonBack() async throws {
        let f = try await makeFixture()
        let parked = try await tmuxRow(f, parked: true)
        // A Codex tab naming no thread has nothing to move.
        let codex = try await tmuxRow(f, kind: .codex)
        let stillRunning = try await tmuxRow(f)
        let onHolder = try await f.db.terminals.create(
            worktreeID: f.worktreeID, tmuxWindowID: "", tmuxPaneID: "",
            label: "acme", claudeSessionID: "acme-session", kind: .claude,
            transport: .holder, holderPID: 9101, childPID: 9102)
        let runningID = stillRunning.id
        f.router.transportMigratorOperationsOverride = Self.operations(
            db: f.db, serverState: { $0.id == runningID ? .running : .absent })

        let result = try await call(f, terminalID: nil)

        #expect(result.migrated == [parked.id])
        #expect(result.skipped == [TerminalMigrationSkip(
            terminalID: codex.id, reason: TransportMigrationEligibility.codexSkip)])
        #expect(result.refused == [TerminalMigrationSkip(
            terminalID: stillRunning.id,
            reason: LeftoverTmuxSession.stillRunningRefusal(
                terminalID: stillRunning.id, server: Self.server))])
        #expect(result.alreadyHolder == [onHolder.id])
    }

    /// A live session whose tmux server may still be running cannot be moved:
    /// TBD can neither reach nor stop it. The refusal carries the command that
    /// ends the server, the row is untouched, and nothing is published.
    @Test("a live session whose tmux server may still run is refused with the way forward")
    func aLiveSessionOnARunningServerIsRefused() async throws {
        let f = try await makeFixture()
        let row = try await tmuxRow(f)
        f.router.transportMigratorOperationsOverride = Self.operations(
            db: f.db, serverState: { _ in .running })

        let result = try await call(f, terminalID: row.id)

        #expect(result.migrated.isEmpty && result.skipped.isEmpty)
        #expect(result.refused == [TerminalMigrationSkip(
            terminalID: row.id,
            reason: LeftoverTmuxSession.stillRunningRefusal(terminalID: row.id, server: Self.server))])
        #expect(try await f.db.terminals.get(id: row.id) == row)
        #expect(replacedRows(f).isEmpty, "a row that did not move was published")
    }

    @Test("a refusal lands in refused, not skipped")
    func aRefusalLandsInRefused() async throws {
        let f = try await makeFixture(canSpawnHolder: false)
        let row = try await tmuxRow(f, parked: true)

        let result = try await call(f, terminalID: row.id)

        #expect(result.migrated.isEmpty && result.skipped.isEmpty)
        #expect(result.refused.map(\.terminalID) == [row.id])
        #expect(result.refused.first?.reason == TerminalTransportMigrator.holderUnspawnableRefusal)
    }

    /// The most likely way to get this wrong is to copy the swap handler's
    /// requirement that a row be a Claude session. A live shell whose tmux
    /// server is gone is started again on the holder.
    @Test("a shell migrates: no Claude session id is required")
    func aShellMigrates() async throws {
        let f = try await makeFixture()
        let shell = try await tmuxRow(f, kind: .shell)
        #expect(shell.claudeSessionID == nil)

        let result = try await call(f, terminalID: shell.id)

        #expect(result.migrated == [shell.id], "result: \(result)")
        #expect(try await f.db.terminals.get(id: shell.id)?.transport == .holder)
    }

    @Test("an unknown terminal is a skip with the not-found reason")
    func anUnknownTerminalIsASkip() async throws {
        let f = try await makeFixture()
        let missing = UUID()
        let result = try await call(f, terminalID: missing)
        #expect(result.skipped == [TerminalMigrationSkip(
            terminalID: missing, reason: TerminalTransportMigrator.notFoundSkip)])
    }

    @Test("every migrated row is broadcast whole, and nothing else is")
    func everyMigratedRowIsBroadcast() async throws {
        let f = try await makeFixture()
        let parked = try await tmuxRow(f, parked: true)
        _ = try await tmuxRow(f)
        f.router.transportMigratorOperationsOverride = Self.operations(
            db: f.db, serverState: { _ in .running })

        _ = try await call(f, terminalID: nil)

        let replaced = replacedRows(f)
        #expect(replaced.map(\.id) == [parked.id])
        #expect(replaced.first?.transport == .holder,
                "the broadcast row must carry the new transport")
    }

    // MARK: - A row that moved and did not resume

    /// The rewrite landed, the wake did not. Reported as a refusal and left
    /// unpublished, a client would keep caching `tmux` and the window id the
    /// rewrite blanked, and the person would be told a session "can't be
    /// moved" that has in fact moved.
    @Test("a wake that fails after the rewrite is reported apart from the refusals")
    func aWakeThatFailsAfterTheRewriteIsItsOwnOutcome() async throws {
        let f = try await makeFixture(wakeResult: .notHibernated)
        let row = try await tmuxRow(f)

        let result = try await call(f, terminalID: row.id)

        #expect(result.migrated.isEmpty, "a session that did not resume was counted as migrated")
        #expect(result.refused.isEmpty, "a session that moved was reported as refused")
        #expect(result.movedNotResumed.map(\.terminalID) == [row.id])
        #expect(result.movedNotResumed.first?.reason.contains("moved to the pty holder") == true)
        #expect(try await f.db.terminals.get(id: row.id)?.transport == .holder)
    }

    /// The broadcast is keyed on what the row says, not on the outcome.
    @Test("a row that moved without resuming is still broadcast with its new transport")
    func aRowThatMovedWithoutResumingIsBroadcast() async throws {
        let f = try await makeFixture(wakeResult: .notHibernated)
        let row = try await tmuxRow(f)

        _ = try await call(f, terminalID: row.id)

        let replaced = replacedRows(f)
        #expect(replaced.map(\.id) == [row.id],
                "the rewritten row was not published, so clients keep a stale transport")
        #expect(replaced.first?.transport == .holder)
        #expect(replaced.first?.tmuxWindowID.isEmpty == true,
                "the published row still names a tmux window")
    }

    /// Per row, inside the loop. A fleet run's broadcasts landing only after
    /// the whole run leaves every mounted pane reading a transport its session
    /// has left, for the length of the run.
    ///
    /// Observed from inside each row's own move — the sighting is its first
    /// step — and stated without assuming which row the list order puts
    /// first: whichever one goes second must already see the other's
    /// replacement published, and must not see its own.
    @Test("a fleet run publishes each row before it moves the next one")
    func aFleetRunPublishesEachRowAsItFinishes() async throws {
        let f = try await makeFixture()
        _ = try await tmuxRow(f)
        _ = try await tmuxRow(f)
        let observations = PublicationObservations()
        let published = f.deltas
        f.router.transportMigratorOperationsOverride = Self.operations(
            db: f.db,
            serverState: { terminal in
                await observations.record(terminal.id, published.all.compactMap {
                    if case .terminalReplaced(let t) = $0 { return t.id } else { return nil }
                })
                return .absent
            })

        _ = try await call(f, terminalID: nil)

        let seen = await observations.all
        #expect(seen.count == 2, "the run did not reach both rows: \(seen)")
        #expect(seen.values.map(\.count).sorted() == [0, 1],
                "the publications did not land one per row, in the loop: \(seen)")
        for (terminalID, alreadyPublished) in seen {
            #expect(!alreadyPublished.contains(terminalID),
                    "a row saw its own replacement published before it moved")
        }
    }

    // MARK: - The record

    /// One row per session, targeted at that session — the shape
    /// `worktree.suspend` and `worktree.resume` have. A fleet gesture that
    /// stops up to a hundred programs must not leave one row naming nothing.
    @Test("a fleet run writes one actuation row per session, each naming it")
    func aFleetRunWritesOneRowPerSession() async throws {
        let f = try await makeFixture()
        let parked = try await tmuxRow(f, parked: true)
        let stillRunning = try await tmuxRow(f)
        f.router.transportMigratorOperationsOverride = Self.operations(
            db: f.db, serverState: { _ in .running })

        _ = try await call(f, terminalID: nil)

        let rows = try f.actuationRows()
        let requests = rows.filter { $0["method"] as? String == RPCMethod.terminalMigrateTransport }
        #expect(requests.count == 2, "the run wrote \(requests.count) rows for 2 sessions")
        let named = requests.compactMap { ($0["target"] as? [String: Any])?["terminal"] as? String }
        #expect(Set(named) == [parked.id.uuidString, stillRunning.id.uuidString],
                "a row named no session: \(named)")
        // And each one's outcome: the moved session dispatched, the one whose
        // tmux server may still run refused as not-eligible with its reason.
        func outcome(for terminalID: UUID) throws -> [String: Any] {
            let request = try #require(requests.first {
                ($0["target"] as? [String: Any])?["terminal"] as? String == terminalID.uuidString
            })
            return try #require(rows.first {
                $0["confirms"] as? String == request["id"] as? String
            })
        }
        let dispatched = try outcome(for: parked.id)
        #expect(dispatched["result"] as? String == "dispatched")
        let refused = try outcome(for: stillRunning.id)
        #expect(refused["result"] as? String == "refused")
        #expect(refused["reason"] as? String == "not-eligible")
        #expect(refused["error"] as? String == LeftoverTmuxSession.stillRunningRefusal(
            terminalID: stillRunning.id, server: Self.server))
    }

    /// A row that moved and did not resume is a transport failure, not a
    /// refusal: a refusal asserts the daemon stopped before acting, and this
    /// one parked and rewrote the row.
    @Test("a move whose wake failed is recorded as a transport failure")
    func aMoveWhoseWakeFailedIsRecordedAsATransportFailure() async throws {
        let f = try await makeFixture(wakeResult: .notHibernated)
        let row = try await tmuxRow(f)

        _ = try await call(f, terminalID: row.id)

        let rows = try f.actuationRows()
        let request = try #require(rows.first {
            $0["method"] as? String == RPCMethod.terminalMigrateTransport
        })
        let outcome = try #require(rows.first {
            $0["confirms"] as? String == request["id"] as? String
        })
        #expect(outcome["result"] as? String == "transport-failed")
    }

    @Test("the result round-trips, and a payload without the newer lists decodes")
    func wireTypesRoundTrip() throws {
        let id = UUID()
        let result = TerminalMigrateTransportResult(
            migrated: [id],
            movedNotResumed: [TerminalMigrationSkip(terminalID: id, reason: "not resumed")],
            skipped: [TerminalMigrationSkip(terminalID: id, reason: "r")],
            refused: [], alreadyHolder: [id])
        let data = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(TerminalMigrateTransportResult.self, from: data) == result)
        // A payload from before either list still decodes.
        let legacy = #"{"migrated":[],"skipped":[],"refused":[]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(
            TerminalMigrateTransportResult.self, from: legacy)
        #expect(decoded.alreadyHolder.isEmpty)
        #expect(decoded.movedNotResumed.isEmpty)
    }
}
