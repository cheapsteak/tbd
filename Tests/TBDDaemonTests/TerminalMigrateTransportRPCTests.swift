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
    }

    /// Operations whose park parks the row for real (so the compare-and-set can
    /// succeed) and whose wake always succeeds. `canSpawnHolder` is a knob for
    /// the refusal path.
    private func makeFixture(canSpawnHolder: Bool = true) async throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
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
            actuationLog: makeTestActuationLog())
        router.transportMigratorOperationsOverride = TerminalTransportMigrator.Operations(
            canSpawnHolder: { canSpawnHolder },
            park: { id in
                try? await db.terminals.setHibernated(
                    id: id, sessionID: "acme-session", reason: .manual)
                return .ok
            },
            wake: { _ in .ok(sessionIncarnationID: nil) },
            paneBusyRefusal: { _ in nil },
            retireWindow: { _ in })

        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "tbd/wt",
            path: "/tmp/acme-wt-\(UUID().uuidString)", tmuxServer: "tbd-test")
        return Fixture(router: router, db: db, worktreeID: worktree.id, deltas: deltas)
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

    private func call(_ f: Fixture, terminalID: UUID?) async throws -> TerminalMigrateTransportResult {
        let response = await f.router.handle(try RPCRequest(
            method: RPCMethod.terminalMigrateTransport,
            params: TerminalMigrateTransportParams(terminalID: terminalID)))
        #expect(response.success, "error: \(response.error ?? "nil")")
        return try response.decodeResult(TerminalMigrateTransportResult.self)
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

        let replaced: [Terminal] = f.deltas.all.compactMap {
            if case .terminalReplaced(let t) = $0 { return t } else { return nil }
        }
        #expect(replaced.map(\.id) == [parked.id])
        #expect(replaced.first?.transport == .holder,
                "the broadcast row must carry the new transport")
    }

    @Test("the actuation surface names the method")
    func theActuationSurfaceNamesTheMethod() {
        #expect(ActuationSurface.terminalMigrateTransport.method
            == RPCMethod.terminalMigrateTransport)
    }

    @Test("the result round-trips, and a payload without the already-holder list decodes")
    func wireTypesRoundTrip() throws {
        let id = UUID()
        let result = TerminalMigrateTransportResult(
            migrated: [id], skipped: [TerminalMigrationSkip(terminalID: id, reason: "r")],
            refused: [], alreadyHolder: [id])
        let data = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(TerminalMigrateTransportResult.self, from: data) == result)
        // A payload without the already-holder list still decodes.
        let legacy = #"{"migrated":[],"skipped":[],"refused":[]}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(TerminalMigrateTransportResult.self, from: legacy).alreadyHolder.isEmpty)
    }
}
