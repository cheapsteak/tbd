import Foundation
import os
import TBDShared

private let supervisionLogger = Logger(
    subsystem: "com.tbd.daemon", category: "supervision.handlers")

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

    /// `supervise.setProjectMark` — `tbd supervise on/off <project>`.
    ///
    /// **`on <project>` is ensure-desk** (design §9): the mark is set first,
    /// then a live supervisor is verified to exist. The two are ordered that
    /// way deliberately — the mark is what the gesture promises, and a desk that
    /// could not be spawned is an anomaly, never a refusal of coverage the
    /// operator asked for.
    ///
    /// **`off` disposes nothing.** The mark is a delivery precondition
    /// rechecked at act time, so a stood-down desk simply receives nothing —
    /// an idle session holding context that cost real tokens to build. No
    /// disposal path exists on this surface at all.
    ///
    /// **The result line carries the mark and nothing more.** No desk state
    /// reaches stdout: reporting a fact the command did not establish is the
    /// invented measurement this design refuses (`docs/cli-supervise.md`).
    func handleSuperviseSetProjectMark(_ paramsData: Data) async throws -> RPCResponse {
        let store = try requireSupervision()
        let params = try decoder.decode(SuperviseSetProjectMarkParams.self, from: paramsData)

        // The Nightwatch coexistence gate. The two supervision paths are
        // mutually exclusive until Nightwatch is retired, not sequential, so
        // turning a project on while Nightwatch is running is refused with the
        // condition named. **Only `on`.** `off` is never refusable in either
        // direction: an operator who could not turn coverage off while the
        // other path held it on would be wedged with no way out.
        if params.on {
            let mode = try await db.config.get().nightwatchMode
            guard mode == .off else {
                throw SupervisionNightwatchConflict.superviseOnWhileNightwatchRunning(mode: mode)
            }
        }

        let result = try await store.setProjectMark(project: params.project, on: params.on)

        if params.on {
            await ensureDesk(project: params.project)
        }
        return try RPCResponse(result: result)
    }

    /// Ensure `project` has a live supervisor, reporting rather than refusing.
    ///
    /// Every failure here is an anomaly on the daemon's own record — the log
    /// and, for a dangling binding, an operator notification — and none of them
    /// reaches the caller: the mark is already set, and retroactively failing a
    /// gesture that took effect would be a lie about what happened.
    private func ensureDesk(project: String) async {
        guard let desks = supervisionDesks, let store = supervision else { return }
        do {
            let inputs = try await store.deskInputs(project: project)
            _ = try await desks.ensureDesk(project: inputs)
        } catch {
            supervisionLogger.error(
                """
                Coverage of "\(project, privacy: .public)" is on, but its supervisor could not \
                be ensured: \(String(describing: error), privacy: .public). The mark stands; \
                nothing will be delivered until a supervisor exists.
                """)
        }
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

    // MARK: - The playbook

    /// `supervise.playbook` — the project's resolved standing conduct: which
    /// level answered, its path, its hash, and its bytes. Read-only.
    func handleSupervisePlaybook(_ paramsData: Data) async throws -> RPCResponse {
        let store = try requireSupervision()
        let params = try decoder.decode(SupervisePlaybookParams.self, from: paramsData)
        return try RPCResponse(result: await store.playbook(project: params.project))
    }

    /// `supervise.playbookCustomize` — copy the shipped default into one level,
    /// once. Refused when that level already exists: TBD writes it exactly once
    /// and never reconciles it (design §5).
    func handleSupervisePlaybookCustomize(_ paramsData: Data) async throws -> RPCResponse {
        let store = try requireSupervision()
        let params = try decoder.decode(SupervisePlaybookCustomizeParams.self, from: paramsData)
        return try RPCResponse(result: await store.customizePlaybook(
            project: params.project, level: params.level))
    }

    // MARK: - The read-only surfaces
    //
    // Neither makes a decision, sends anything, or starts anything. They are
    // free to call: the readout is a sweep program's opening move on every
    // tick, and the ledger query closes its loop.
    //
    // Read-only about *decisions*, not about bytes on disk. Both resolve the
    // project through `SupervisionStore.projectFacts`, which reads through the
    // store's reconciliation — so a coverage span an operator ended by
    // hand-editing the supervision file gets closed here, appending a
    // `projectOff` line. That append records a decision the **operator** made,
    // observed at the first read that noticed it; the readout authored nothing.
    // Skipping the reconciliation to keep the file untouched would be the worse
    // trade: the surface would report a mark it already knows is stale.

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

    // MARK: - The brief pipe

    /// `supervise.brief` — one briefing submission, answered synchronously
    /// (sweep-program design §3).
    ///
    /// A shell like the rest: the whole pipeline — the standing-state refusals,
    /// the liveness contact, the size bound, the identity-blind pacing and the
    /// single delivery attempt — lives in `SupervisionStore.submitBriefing`,
    /// where the state it reads and writes already lives. The brake is read
    /// here, once, and handed down, so the refusal and the record are computed
    /// from one value taken at one moment.
    ///
    /// **The CLI performs no local size check**, so every submission reaches
    /// this handler, including an oversize one: refusing locally would move no
    /// liveness record, and a broken composer would then read as a silent one.
    func handleSuperviseBrief(_ paramsData: Data) async throws -> RPCResponse {
        let store = try requireSupervision()
        let params = try decoder.decode(SuperviseBriefParams.self, from: paramsData)
        let brake = try await supervisionBrake()
        return try RPCResponse(result: await store.submitBriefing(
            project: params.project, text: params.text, brake: brake,
            deliverer: supervisionBriefingDeliverer))
    }
}

/// The refusals that keep the two supervision paths apart while both are live.
///
/// **Nightwatch stays live until the redesign's cutover, so the two are mutually
/// exclusive rather than sequential.** Both drive the same fleet through the
/// same terminals, on different theories of who decides what — running them
/// together would have two rails nudging one agent with neither aware of the
/// other. Each direction refuses the *on* gesture and names the condition.
///
/// **Neither direction can refuse an `off`**, and that asymmetry is the whole
/// safety property: turning supervision off, and setting Nightwatch to `.off`,
/// always work. An operator who ran into a refusal in both directions would be
/// wedged with the fleet running and no gesture that could stop it.
enum SupervisionNightwatchConflict: Error, CustomStringConvertible, LocalizedError {
    case superviseOnWhileNightwatchRunning(mode: NightwatchMode)
    case nightwatchOnWhileProjectsSupervised(projects: [String])

    var description: String {
        switch self {
        case .superviseOnWhileNightwatchRunning(let mode):
            return "Nightwatch is running (mode: \(mode.rawValue)), and it supervises the same "
                + "fleet this would. Turn it off first with \"tbd nightwatch mode off\", then "
                + "turn the project on. Turning projects OFF is never refused."
        case .nightwatchOnWhileProjectsSupervised(let projects):
            let named = projects.map { "\"\($0)\"" }.joined(separator: ", ")
            let verb = projects.count == 1 ? "is" : "are"
            return "\(named) \(verb) under fleet supervision, which watches the same fleet "
                + "Nightwatch would. Turn each project off first with "
                + "\"tbd supervise off <project>\", then set the Nightwatch mode. Setting "
                + "Nightwatch to off is never refused."
        }
    }

    var errorDescription: String? { description }
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
