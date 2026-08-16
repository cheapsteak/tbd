import Foundation
import TBDShared

/// RPC handlers for the `supervise.*` surface (`docs/cli-supervise.md`,
/// `docs/specs/2026-07-26-fleet-supervision-design.md` §10).
///
/// Every one of them is a thin shell: decode, read the brake, hand the gesture
/// to `SupervisionStore`, encode what it answered. The daemon is the single
/// writer of `~/tbd/supervision/`, and the store is where that single writer
/// lives — a handler that reached for the file itself would be a second writer
/// with none of the store's ordering.
///
/// **Nothing here broadcasts a state delta.** The one supervision fact the app
/// displays is the brake, and its own config handler already broadcasts. Marks,
/// modes and topology have no app surface in this slice, so a broadcast would
/// ask every connected client to reload for a change it cannot see.
///
/// The store is `nil` in mock mode and in tests that do not wire it, exactly
/// like `orphanGC`; these handlers refuse with a named condition rather than
/// crashing.
extension RPCRouter {

    /// The brake as it stands, resolved through the shipped default when the
    /// tri-state column is unset. Read fresh per call — the app's toggle and
    /// the CLI's bare `on`/`off` both write it, and every surface must see the
    /// same value immediately after a change.
    func supervisionBrake() async throws -> SupervisionBrakeState {
        let config = try await db.config.get()
        return config.supervisionEnabled ? .released : .engaged
    }

    private func requireSupervision() throws -> SupervisionStore {
        guard let supervision else { throw SupervisionUnavailable() }
        return supervision
    }

    func handleSuperviseStatus() async throws -> RPCResponse {
        let store = try requireSupervision()
        let brake = try await supervisionBrake()
        return try RPCResponse(result: await store.status(brake: brake))
    }

    func handleSuperviseSetProjectMark(_ paramsData: Data) async throws -> RPCResponse {
        let store = try requireSupervision()
        let params = try decoder.decode(SuperviseSetProjectMarkParams.self, from: paramsData)
        return try RPCResponse(
            result: await store.setProjectMark(project: params.project, on: params.on))
    }

    func handleSuperviseSetMode(_ paramsData: Data) async throws -> RPCResponse {
        let store = try requireSupervision()
        let params = try decoder.decode(SuperviseSetModeParams.self, from: paramsData)
        return try RPCResponse(
            result: await store.setMode(project: params.project, mode: params.mode))
    }

    func handleSuperviseProjectList() async throws -> RPCResponse {
        let store = try requireSupervision()
        return try RPCResponse(result: await store.projectList())
    }

    func handleSuperviseProjectCreate(_ paramsData: Data) async throws -> RPCResponse {
        let store = try requireSupervision()
        let params = try decoder.decode(SuperviseProjectCreateParams.self, from: paramsData)
        return try RPCResponse(result: await store.projectCreate(
            name: params.name, repos: params.repos, policy: params.policy))
    }

    func handleSuperviseProjectDelete(_ paramsData: Data) async throws -> RPCResponse {
        let store = try requireSupervision()
        let params = try decoder.decode(SuperviseProjectDeleteParams.self, from: paramsData)
        return try RPCResponse(result: await store.projectDelete(name: params.name))
    }

    func handleSuperviseProjectMove(_ paramsData: Data) async throws -> RPCResponse {
        let store = try requireSupervision()
        let params = try decoder.decode(SuperviseProjectMoveParams.self, from: paramsData)
        return try RPCResponse(result: await store.projectMove(
            repo: params.repo, to: SupervisionMoveTarget(argument: params.to)))
    }

    // MARK: - The read-only surfaces
    //
    // Both write nothing, append no ledger line, and start nothing. They are
    // free to call: the readout is a sweep program's opening move on every
    // tick, and the ledger query closes its loop.

    /// `supervise.readout` — the project's whole current picture (sweep-program
    /// design §3). An unknown project is refused by
    /// `SupervisionStore.projectFacts`, because an empty readout would read as
    /// "this project has no agents".
    func handleSuperviseReadout(_ paramsData: Data) async throws -> RPCResponse {
        let store = try requireSupervision()
        let params = try decoder.decode(SuperviseReadoutParams.self, from: paramsData)
        let facts = try await store.projectFacts(
            project: params.project, brake: try await supervisionBrake())
        let builder = SupervisionReadoutBuilder(
            db: db,
            fleet: DatabaseSupervisionFleetReader(db: db),
            sessionCounters: sessionCounters,
            branchTips: lifecycle.branchTipTracker,
            actuationRecord: ActuationRecordReader(activePath: actuationLog.path),
            now: now)
        return try RPCResponse(result: await builder.build(facts: facts))
    }

    /// `supervise.ledger` — the joined per-project view of both records since an
    /// instant (sweep-program design §3).
    ///
    /// The project is resolved through the store first, for the scoping repo
    /// set and so an unknown name is refused here exactly as the readout
    /// refuses it — an empty `lines` array would otherwise read as "nothing
    /// happened".
    func handleSuperviseLedger(_ paramsData: Data) async throws -> RPCResponse {
        let store = try requireSupervision()
        let params = try decoder.decode(SuperviseLedgerParams.self, from: paramsData)
        let facts = try await store.projectFacts(
            project: params.project, brake: try await supervisionBrake())
        let query = SupervisionLedgerQuery(
            db: db,
            supervisionLedgerPath: store.ledgerPath,
            actuationRecord: ActuationRecordReader(activePath: actuationLog.path),
            now: now)
        return try RPCResponse(result: await query.view(
            project: params.project,
            projectRepos: Set(facts.project.repos),
            since: params.since))
    }
}

/// The refusal a `supervise.*` call gets when the daemon has no supervision
/// store wired — mock mode, or a unit test that did not attach one. Named
/// rather than a bare string so the sentence a human reads on stderr says what
/// is missing and what it means.
struct SupervisionUnavailable: Error, CustomStringConvertible, LocalizedError {
    var description: String {
        "This daemon has no supervision store: nothing is being supervised, and no coverage "
            + "gesture can be recorded. Restart the daemon; if it is running in mock mode, "
            + "supervision is deliberately absent."
    }

    var errorDescription: String? { description }
}
