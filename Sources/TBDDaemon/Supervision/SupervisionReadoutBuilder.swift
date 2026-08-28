import Foundation
import os
import TBDShared

private let readoutLogger = Logger(subsystem: "com.tbd.daemon", category: "supervision.readout")

/// Composes `supervise.readout` — the fact surface of
/// `docs/specs/2026-08-01-fleet-supervision-sweep-program-design.md` §3 — out
/// of facts the daemon already holds.
///
/// **Per agent this costs at most what `session.states` already costs: database
/// reads plus byte-bounded transcript tails, and zero subprocesses, tmux calls,
/// pane reads and model calls.** That is a constraint, not an aspiration — this
/// surface is designed to be asked every tick for the whole fleet, and the
/// moment anything here shells out it stops being askable at that cadence and
/// the supervision loop loses the facts it runs on. The one read that is not
/// per-agent is the actuation record's bounded tail, paid once per readout.
///
/// Nothing is re-derived. The perimeter comes from `SupervisionFleetReading`,
/// the state from `SessionStateResolver` over `SessionStateFactGatherer`, the
/// counters from `SessionCountersTracker`, the stillness from
/// `BranchTipTracker`, the work facts from the worktree row, and the machinery
/// and supervisor sections from `SupervisionStore`'s own resolution. A second
/// implementation of any of them would be a second answer.
struct SupervisionReadoutBuilder: Sendable {
    /// How far back the not-to-act query reads the actuation record.
    ///
    /// The trade it makes, stated so nobody has to guess: an intervention whose
    /// request row predates this window is **not reported**, so the readout
    /// understates rather than invents. It never claims an act is in flight
    /// that is not; it can stay quiet about one that has been outstanding for
    /// more than a day, which by then is a finding for the record rather than a
    /// reason to wait. Twenty-four hours is far past
    /// `DeliveryRecord.acknowledgementDeadline` (60 s), so every act whose
    /// status is still genuinely moving is inside it.
    static let interventionLookback: TimeInterval = 24 * 60 * 60

    let db: TBDDatabase
    let fleet: any SupervisionFleetReading
    let sessionCounters: SessionCountersTracker
    let branchTips: BranchTipTracker
    let actuationRecord: ActuationRecordReader
    /// How a session transcript is measured when a standing prompt is checked
    /// against it. A seam, not a clock: a file's modification time is data.
    let transcriptFingerprinter: TranscriptFingerprinter
    let now: @Sendable () -> Date

    init(
        db: TBDDatabase,
        fleet: any SupervisionFleetReading,
        sessionCounters: SessionCountersTracker,
        branchTips: BranchTipTracker,
        actuationRecord: ActuationRecordReader,
        transcriptFingerprinter: @escaping TranscriptFingerprinter = TranscriptFingerprinting.live,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.db = db
        self.fleet = fleet
        self.sessionCounters = sessionCounters
        self.branchTips = branchTips
        self.actuationRecord = actuationRecord
        self.transcriptFingerprinter = transcriptFingerprinter
        self.now = now
    }

    // MARK: - The pass

    func build(facts: SupervisionProjectFacts) async throws -> SupervisionReadout {
        let generatedAt = now()

        // The perimeter, and only the perimeter: `agents(inRepos:)` already
        // excludes archived worktrees and terminals explicitly recorded as
        // shells, and keeps a nil-kind row as `unknown`. That rule lives there,
        // and re-deriving it here would be a second perimeter.
        let agents = try await fleet.agents(inRepos: Set(facts.project.repos))
            .sorted { $0.terminal.uuidString < $1.terminal.uuidString }

        let notToAct = notToActFacts(at: generatedAt)
        let resolver = SessionStateResolver(now: now)
        let gatherer = SessionStateFactGatherer(now: now)

        var worktreeRows: [UUID: Worktree] = [:]
        /// The terminals actually enumerated, per worktree — the scope the
        /// counter prune below is allowed to reach. See `retain` at the end.
        var enumerated: [UUID: Set<UUID>] = [:]
        var entries: [SupervisionReadoutAgent] = []
        entries.reserveCapacity(agents.count)

        // The readout may be the only reader on a daemon with no app attached,
        // so it supersedes a stale prompt on its own pass rather than reporting
        // one. No delta is broadcast from here: a readout is a pull, not a UI
        // event, and the app's own poll re-reads the row within its interval.
        let supersession = AwaitingInputSupersession(
            db: db, fingerprint: transcriptFingerprinter)

        for agent in agents {
            guard var terminal = try await db.terminals.get(id: agent.terminal) else { continue }
            if await supersession.reconcile(terminal: terminal) {
                terminal.awaitingInputReason = nil
                terminal.awaitingInputObservedAt = nil
            }
            let worktree: Worktree
            if let cached = worktreeRows[agent.worktree] {
                worktree = cached
            } else if let row = try await db.worktrees.get(id: agent.worktree) {
                worktreeRows[agent.worktree] = row
                worktree = row
            } else {
                // The perimeter listed it and the row is gone — a deletion that
                // landed between the two reads. There is no branch to report,
                // so the honest answer is to leave it out rather than to invent
                // an empty work section for a worktree that no longer exists.
                continue
            }

            let state = resolver.resolve(gatherer.facts(for: terminal))
            let commitsUnchangedSince = await branchTips.unchangedSince(
                repoID: agent.repo, worktreeID: agent.worktree)
            let counters = await sessionCounters.sample(
                terminalID: terminal.id,
                worktreeID: agent.worktree,
                transcriptPath: terminal.transcriptPath,
                commitsUnchangedSince: commitsUnchangedSince,
                at: generatedAt)
            enumerated[agent.worktree, default: []].insert(terminal.id)

            entries.append(SupervisionReadoutAgent(
                terminal: terminal.id,
                worktree: agent.worktree,
                repo: agent.repo,
                spawnSource: agent.spawnSource,
                transcriptPath: terminal.transcriptPath,
                state: state,
                work: SupervisionReadoutWork(
                    branch: worktree.branch,
                    hasConflicts: worktree.hasConflicts,
                    commitsUnchangedSince: commitsUnchangedSince.map { SupervisionInstant($0) },
                    // Carried whole rather than collapsed: "the forge answered
                    // and there is no PR" and "we could not find out" are
                    // opposite facts, and `prStatus` alone cannot say which.
                    pr: worktree.prObservation,
                    prStatus: worktree.prStatus),
                counters: counters,
                pinned: worktree.pinnedAt != nil,
                notToAct: SupervisionReadoutNotToAct(
                    interventionInFlight: notToAct.interventionInFlight.contains(terminal.id),
                    recheckPending: notToAct.recheckPending.contains(terminal.id),
                    rateLimitedUntil: rateLimitedUntil(state))))
        }

        // **Per worktree, never fleet-wide.** This pass enumerated a *project* —
        // several worktrees, and not the whole fleet — so a prune scoped to the
        // fleet would evict every other project's baselines against a list that
        // never contained them, resetting their observation windows silently on
        // every readout. `SessionCountersTracker.retain` says the same thing one
        // layer down. Pruning is still worth doing: the worktrees this pass DID
        // enumerate are enumerated exhaustively (`agents(inRepos:)` drops only
        // shells, which never hold a baseline), so within each of them the list
        // is complete and a terminal missing from it really is gone.
        for (worktreeID, terminalIDs) in enumerated {
            await sessionCounters.retain(terminalIDs: terminalIDs, inWorktree: worktreeID)
        }

        readoutLogger.debug(
            """
            supervise.readout: \(facts.project.name, privacy: .public) — \
            \(entries.count, privacy: .public) agent(s)
            """)

        return SupervisionReadout(
            project: facts.project.name,
            generatedAt: SupervisionInstant(generatedAt),
            supervision: SupervisionReadoutMachinery(
                brake: facts.brake,
                on: facts.project.mark,
                mode: facts.project.activeMode,
                declaredModes: facts.project.declaredModes,
                spanStartedAt: facts.spanStartedAt,
                lastSweepContactAt: facts.lastSweepContactAt),
            // **Nothing here is stubbed into reading as liveness.** No
            // supervisor is live until briefing delivery lands (slice 5), so
            // `live` is false and the four facts behind it are null on every
            // readout this build produces. `arrangement` says what *would*
            // supervise the project and never that anything is standing there.
            //
            // The two facts have to stay consistent: until slice 5 fills these
            // in, `supervise brief` honestly answers `no-live-supervisor`. A
            // readout claiming a live supervisor beside a pipe that refuses for
            // want of one would make the readout the liar.
            supervisor: SupervisionReadoutSupervisor(
                arrangement: facts.project.supervisor,
                state: nil,
                lastAttestedAct: nil,
                contextLoad: nil,
                unansweredBriefingSince: nil,
                live: false),
            agents: entries)
    }

    // MARK: - The not-to-act facts

    /// The terminals an act stands against right now, split by which of the two
    /// facts applies.
    ///
    /// They are different findings and are never collapsed: `awaitingObservation`
    /// means a verified send is in flight inside its deadline — nothing is owed
    /// and nothing is wrong — while `unconfirmed` means the deadline passed with
    /// no confirming observation, which is a finding a program may raise rather
    /// than a reason to simply wait. `DeliveryRecord.statuses` assigns exactly
    /// one of them to any single act, so one act can never produce both.
    private struct NotToActFacts {
        var interventionInFlight: Set<UUID> = []
        var recheckPending: Set<UUID> = []
    }

    private func notToActFacts(at instant: Date) -> NotToActFacts {
        let cutoff = instant.addingTimeInterval(-Self.interventionLookback)
        // Whole segments go into the join — an act's outcome rows have to be
        // walked with it — and the *window* is applied to the assessments, so a
        // request row older than the lookback is not reported even when the
        // segment holding it was read.
        let rows = actuationRecord.readRows(since: cutoff)
        var facts = NotToActFacts()
        for assessment in DeliveryRecord.statuses(in: rows, now: instant) {
            // A row whose timestamp will not parse stays: `DeliveryRecord`
            // already fails closed on it, and dropping it here would turn "we
            // cannot tell when this happened" into "nothing is outstanding".
            if let stamped = DeliveryRecord.parseTimestamp(assessment.request.ts),
               stamped < cutoff { continue }
            guard let raw = assessment.request.target?.terminal,
                  let terminalID = UUID(uuidString: raw) else { continue }
            switch assessment.status {
            case .awaitingObservation: facts.interventionInFlight.insert(terminalID)
            case .unconfirmed: facts.recheckPending.insert(terminalID)
            // An act an observation has already settled is not a reason to
            // stand off a target — whatever it established, it is over.
            case .observed: break
            }
        }
        return facts
    }

    /// The rate limit the resolved state already established, and never a
    /// second classification of the same transcript.
    ///
    /// nil when the session is not rate-limited **and** when it is but the limit
    /// announced no reset time: `SessionStateValue.rateLimited(until:)` carries
    /// an optional for that case, and inventing a stamp would put a time on a
    /// wait nobody was told the length of.
    private func rateLimitedUntil(_ state: SessionState) -> SupervisionInstant? {
        guard case .rateLimited(let until) = state.value, let until else { return nil }
        return SupervisionInstant(until)
    }
}
