import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// `terminal.migrateTransport` — the wire surface over the transport migrator.
///
/// The migrator's own composition is proved in `TerminalTransportMigratorTests`;
/// these tests drive it through the router with its three operations replaced,
/// so what they prove is the handler: what it forwards, what it reports, and
/// what it broadcasts.
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

    /// Operations whose park parks the row for real (so the compare-and-set can
    /// succeed) and whose wake always succeeds. `canSpawnHolder` is a knob for
    /// the refusal path, `wakeResult` for the moved-but-not-resumed one, and
    /// `nightwatchMode` for the gate.
    private func makeFixture(
        canSpawnHolder: Bool = true,
        wakeResult: WakeResult = .ok(sessionIncarnationID: nil),
        nightwatchMode: NightwatchMode = .off
    ) async throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setNightwatchMode(nightwatchMode)
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
        router.transportMigratorOperationsOverride = TerminalTransportMigrator.Operations(
            canSpawnHolder: { canSpawnHolder },
            park: { id in
                try? await db.terminals.setHibernated(
                    id: id, sessionID: "acme-session", reason: .manual)
                return .ok
            },
            wake: { _ in wakeResult },
            paneBusyRefusal: { _ in nil },
            retireWindow: { _ in },
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

        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "tbd/wt",
            path: "/tmp/acme-wt-\(UUID().uuidString)", tmuxServer: "tbd-test")
        return Fixture(
            router: router, db: db, worktreeID: worktree.id, deltas: deltas,
            actuationLogPath: actuationLogPath)
    }

    private func tmuxRow(
        _ f: Fixture, kind: TerminalKind = .claude, parked: Bool = false,
        activity: TerminalActivityState = .idle
    ) async throws -> Terminal {
        let created = try await f.db.terminals.create(
            worktreeID: f.worktreeID, tmuxWindowID: "@7", tmuxPaneID: "%7",
            label: "acme", claudeSessionID: kind == .claude ? "acme-session" : nil,
            kind: kind, transport: .tmux)
        try await f.db.terminals.setActivityState(
            id: created.id, activityState: activity, source: .derived)
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
        let working = try await tmuxRow(f, activity: .working)
        let onHolder = try await f.db.terminals.create(
            worktreeID: f.worktreeID, tmuxWindowID: "", tmuxPaneID: "",
            label: "acme", claudeSessionID: "acme-session", kind: .claude,
            transport: .holder, holderPID: 9101, childPID: 9102)

        let result = try await call(f, terminalID: nil)

        #expect(result.migrated == [parked.id])
        #expect(result.skipped == [TerminalMigrationSkip(
            terminalID: working.id, reason: "Session is actively running")])
        #expect(result.refused.isEmpty)
        #expect(result.alreadyHolder == [onHolder.id])
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
    /// requirement that a row be a Claude session.
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
        _ = try await tmuxRow(f, activity: .working)

        _ = try await call(f, terminalID: nil)

        let replaced = replacedRows(f)
        #expect(replaced.map(\.id) == [parked.id])
        #expect(replaced.first?.transport == .holder,
                "the broadcast row must carry the new transport")
    }

    // MARK: - A row that moved and did not resume

    /// The outcome the handler used to render as a refusal and never publish:
    /// the rewrite landed, the wake did not. A client that never heard about it
    /// keeps caching `tmux` and the window id this migration retired, and the
    /// person is told a session "can't be moved" that has in fact moved.
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
                "the published row still names the retired window")
    }

    /// Per row, inside the loop. A fleet run's broadcasts landing only after
    /// the whole run leaves every mounted pane attached to a window the
    /// migration already killed, for the length of the run.
    ///
    /// Observed from inside each row's own move, and stated without assuming
    /// which row the list order puts first: whichever one goes second must
    /// already see the other's replacement published, and must not see its own.
    @Test("a fleet run publishes each row before it moves the next one")
    func aFleetRunPublishesEachRowAsItFinishes() async throws {
        let f = try await makeFixture()
        _ = try await tmuxRow(f, parked: true)
        _ = try await tmuxRow(f, parked: true)
        let observations = PublicationObservations()
        let published = f.deltas
        f.router.transportMigratorOperationsOverride = TerminalTransportMigrator.Operations(
            canSpawnHolder: { true },
            park: { _ in .ok },
            wake: { _ in .ok(sessionIncarnationID: nil) },
            paneBusyRefusal: { terminal in
                await observations.record(terminal.id, published.all.compactMap {
                    if case .terminalReplaced(let t) = $0 { return t.id } else { return nil }
                })
                return nil
            },
            retireWindow: { _ in },
            moveRunningShell: { _ in .moved })

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
        let working = try await tmuxRow(f, activity: .working)

        _ = try await call(f, terminalID: nil)

        let rows = try f.actuationRows()
        let requests = rows.filter { $0["method"] as? String == RPCMethod.terminalMigrateTransport }
        #expect(requests.count == 2, "the run wrote \(requests.count) rows for 2 sessions")
        let named = requests.compactMap { ($0["target"] as? [String: Any])?["terminal"] as? String }
        #expect(Set(named) == [parked.id.uuidString, working.id.uuidString],
                "a row named no session: \(named)")
        // And each one's outcome: the moved session dispatched, the busy one
        // refused as not-eligible with the rail's reason.
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
        let refused = try outcome(for: working.id)
        #expect(refused["result"] as? String == "refused")
        #expect(refused["reason"] as? String == "not-eligible")
        #expect(refused["error"] as? String == "Session is actively running")
    }

    /// A row that moved and did not resume is a transport failure, not a
    /// refusal: a refusal asserts the daemon stopped before acting, and this
    /// one rewrote the row and retired its window.
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

    // MARK: - The Nightwatch gate

    /// The third door into the Nightwatch/holder pair. The reachable state is
    /// the one `NightwatchHolderGate.modeRefusal` sends a person to: the flag
    /// off, no live holder rows, a watch mode on. One `--all` from there would
    /// put the forbidden pair live.
    @Test(arguments: [NightwatchMode.daywatch, NightwatchMode.nightwatch])
    func aWatchModeRefusesTheWholeCall(_ mode: NightwatchMode) async throws {
        let f = try await makeFixture(nightwatchMode: mode)
        let row = try await tmuxRow(f, parked: true)

        let response = try await respond(f, terminalID: nil)

        #expect(!response.success, "the migration ran with \(mode) active")
        #expect(response.error == NightwatchHolderGate.migrationRefusal)
        #expect(try await f.db.terminals.get(id: row.id)?.transport == .tmux,
                "a row was migrated behind the refusal")
        #expect(replacedRows(f).isEmpty, "the refused call broadcast a row")
        #expect(try f.actuationRows().isEmpty,
                "the refused call wrote an actuation row for a session it never touched")
    }

    /// The other branch, and the one every other test in this suite rests on:
    /// with the mode off the same call migrates.
    @Test("with no watch mode the same call migrates")
    func withNoWatchModeTheSameCallMigrates() async throws {
        let f = try await makeFixture(nightwatchMode: .off)
        let row = try await tmuxRow(f, parked: true)

        let result = try await call(f, terminalID: nil)

        #expect(result.migrated == [row.id])
        #expect(try await f.db.terminals.get(id: row.id)?.transport == .holder)
    }

    @Test("the actuation surface names the method")
    func theActuationSurfaceNamesTheMethod() {
        #expect(ActuationSurface.terminalMigrateTransport.method
            == RPCMethod.terminalMigrateTransport)
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
