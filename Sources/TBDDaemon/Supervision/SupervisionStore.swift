import Foundation
import os
import TBDShared

private let storeLogger = Logger(subsystem: "com.tbd.daemon", category: "supervision.store")

/// Why a supervision RPC was refused for a reason the shared types do not
/// already name. Every case reaches a human on the CLI's stderr, so every
/// message names the offending value and the way out.
public enum SupervisionStoreError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case unknownRepoIdentifier(String)
    case ambiguousRepoName(String, repos: [UUID])
    case unknownProject(String)
    case projectAlreadyDeclared(String)
    case modeNotDeclared(project: String, requested: String, declared: [String])
    case concurrentEdit(project: String)

    public var description: String {
        switch self {
        case .unknownRepoIdentifier(let identifier):
            return "There is no repo \"\(identifier)\" — name a repo by its id or its display name."
        case .ambiguousRepoName(let name, let repos):
            let ids = repos.map(\.uuidString).sorted().joined(separator: ", ")
            return "\"\(name)\" names \(repos.count) repos (\(ids)). Name the one you mean by its id."
        case .unknownProject(let project):
            return "There is no project \"\(project)\" — run \"tbd supervise project list\" to see them."
        case .projectAlreadyDeclared(let project):
            return "A project named \"\(project)\" is already declared. "
                + "Delete it first, or move repos into it."
        case .modeNotDeclared(let project, let requested, let declared):
            let choices = declared.isEmpty ? "(none declared)" : declared.joined(separator: ", ")
            return "Mode \"\(requested)\" is not declared for project \"\(project)\" "
                + "— choices: \(choices)."
        case .concurrentEdit(let project):
            return "The supervision file kept changing while \"\(project)\"'s mark was being "
                + "set, so nothing was written. Something else is editing it — try again."
        }
    }

    public var errorDescription: String? { description }
}

/// The machinery facts one project's readout carries, resolved through the same
/// topology every other gesture uses.
///
/// Daemon-internal rather than a wire type: `SupervisionReadoutBuilder` composes
/// `SupervisionReadoutMachinery` and the supervisor section out of it, and
/// `SupervisionLedgerQuery` takes the project's repo set from it. Both exist so
/// that neither resolves topology itself — `SupervisionStore` is the single
/// reader of `supervision.json`, and a second resolution would be a second
/// answer to a question with one.
public struct SupervisionProjectFacts: Sendable, Equatable {
    /// The resolved project: its repos, mark, declared and active modes, and
    /// supervisor arrangement.
    public let project: SupervisionProject
    /// The fleet brake as the caller read it, carried through so the readout's
    /// machinery section is built from one value taken at one moment rather
    /// than from two reads that can disagree.
    public let brake: SupervisionBrakeState
    /// When the current coverage span opened, or nil when the project is off or
    /// the record holds no opening line to pair with.
    public let spanStartedAt: SupervisionInstant?
    /// When a sweep program last made contact, or nil when it never has.
    public let lastSweepContactAt: SupervisionInstant?

    public init(project: SupervisionProject, brake: SupervisionBrakeState,
                spanStartedAt: SupervisionInstant?, lastSweepContactAt: SupervisionInstant?) {
        self.project = project
        self.brake = brake
        self.spanStartedAt = spanStartedAt
        self.lastSweepContactAt = lastSweepContactAt
    }
}

/// What one brake transition did, and where it sits in the order they were
/// committed.
///
/// The sequence exists because more than one thing has to react to a brake
/// change — the ledger, and the heartbeat's timer — and only the store's gate
/// knows what order the transitions actually landed in. Handing that order out
/// as a token lets a consumer outside the gate discard an edge that lost its
/// race, **without** lengthening the serialized region to cover that consumer's
/// work. It is a number rather than a callback on purpose: the store is the
/// single writer of the record and must not acquire references to the observers
/// that read it — the heartbeat's snapshot closure already holds the store, so
/// injecting the heartbeat back into the store would close a retain cycle
/// between two actors.
public struct SupervisionBrakeTransition: Sendable, Equatable {
    /// Whether the brake actually moved. A gesture that resolved to no change
    /// still gets a sequence — it is an ordering token, not a change counter.
    public let changed: Bool
    /// Monotonic within one store, assigned inside the gate.
    public let sequence: UInt64

    public init(changed: Bool, sequence: UInt64) {
        self.changed = changed
        self.sequence = sequence
    }
}

/// The daemon's single writer of `~/tbd/supervision/supervision.json`, and the
/// one place a coverage decision becomes a ledger line.
///
/// Holds the operator's file in memory for lookups, resolves topology against
/// the repo list, rewrites the file atomically after each operator action, and
/// appends the lifecycle line that records what changed — **file first, then
/// ledger**. That order is not arbitrary: a line written before the save could
/// claim a decision the save then failed to apply, which is exactly the false
/// claim the record exists to forbid, while a save that lands without its line
/// leaves a span whose start reads as unknown — degraded, but true.
///
/// **A no-op is not a decision.** Turning on a project already on, turning off
/// one already off, or selecting the mode already selected returns
/// `changed: false`, writes no ledger line, and does not rewrite the file.
///
/// **Untouched and turned-off are one state**, all the way down: a mark is
/// membership in `supervised`, absence is off, and nothing here carries a third
/// tier.
///
/// Every mutation reads the file and writes it back with **no suspension in
/// between**, so two operators acting at once cannot compute from the same base
/// and clobber each other. Actor isolation gives that for free only across
/// synchronous stretches, which is why each method does its awaiting (the repo
/// list, the roster) before the read-modify-write and not inside it.
public actor SupervisionStore {
    private let files: SupervisionFileStore
    private let ledger: SupervisionLedgerWriter
    private let fleet: any SupervisionFleetReading
    private let playbooks: SupervisionPlaybookResolver
    private let now: @Sendable () -> Date

    /// The operator's file as last read from disk. Every read goes through
    /// `freshFile()`, which reloads first when the bytes on disk changed.
    private var cached = SupervisionFile()

    /// Identity of the bytes `cached` was read from, or nil when the file was
    /// absent. See `freshFile()`.
    private var fingerprint: FileFingerprint?

    /// Open coverage spans by project, recovered from the ledger at first use
    /// and maintained from there. Never persisted beside the mark — a derived
    /// "covered since" field would drift out of step with the lines that
    /// actually record coverage (design §9).
    private var spanStarts: [String: SupervisionInstant] = [:]

    /// Set once the first read of both files has happened.
    private var loaded = false

    /// Set when `freshFile()` reloaded bytes this store did not write, and
    /// cleared by `reconcileExternalEdits(repos:)`. Deliberately not set by the
    /// **initial** load: recovering state at boot is reading, not observing a
    /// change, and a restart must write no ledger line.
    private var sawExternalEdit = false

    /// Per-project counters the coverage summary reports, fed by the brief pipe
    /// (`submitBriefing`).
    ///
    /// In memory rather than persisted because both facts become queries over
    /// the ledger's own `delivery` lines once those exist, and a persisted copy
    /// would be a second answer to a question with one.
    private var sweepContacts: [String: Int] = [:]
    private var briefingsDelivered: [String: Int] = [:]
    private var lastSweepContact: [String: SupervisionInstant] = [:]

    /// When each project last spent its briefing pacing slot — the *only* input
    /// the rate limit reads besides `now()`, which is what makes it
    /// identity-blind (design §3 step 2).
    ///
    /// In memory, beside the counters above and for the same reason. A daemon
    /// restart forgetting that a briefing was paced two minutes ago costs one
    /// extra delivery; persisting it would be a second copy of a fact the
    /// ledger's own `delivery` lines answer once they exist.
    ///
    /// **A `Date` behind the store's date seam, deliberately not a `Clock`.**
    /// Nothing here sleeps, debounces, polls or times out — pacing compares a
    /// stored stamp against `now()`, so this is data, not behavior, and the
    /// repo's injected-clock rule does not apply. `now` is what a test pins.
    private var lastPacedBriefing: [String: Date] = [:]

    public init(
        files: SupervisionFileStore,
        ledger: SupervisionLedgerWriter,
        fleet: any SupervisionFleetReading,
        playbooks: SupervisionPlaybookResolver = SupervisionPlaybookResolver(),
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.files = files
        self.ledger = ledger
        self.fleet = fleet
        self.playbooks = playbooks
        self.now = now
    }

    // MARK: - Loading

    /// The `(device, inode, size, mtime)` of the file `cached` was read from.
    ///
    /// Four facts rather than one: an atomic rewrite (this store's own, or an
    /// editor's `:w`) replaces the inode, while an in-place edit keeps it and
    /// moves size or mtime.
    private struct FileFingerprint: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
        }
    }

    /// Read both files once, at daemon start, so a malformed `supervision.json`
    /// is loud at boot rather than at whichever operator gesture happens to hit
    /// it first.
    ///
    /// **Loading writes no ledger line, sends nothing, and starts nothing.**
    /// Reading state back is not re-deciding: the marks say what is covered
    /// now, the ledger says since when, and a restart that replayed either
    /// would be inventing decisions nobody made.
    public func load() async throws {
        try await ensureLoaded()
    }

    private func ensureLoaded() async throws {
        guard !loaded else { return }
        let recovered = await ledger.spanStarts()
        // Re-check after the await. Two callers can both pass the guard above
        // and suspend on the ledger read; if the first finishes and then
        // completes a whole `on` gesture — including its `spanStarts` entry —
        // the second's continuation would overwrite `spanStarts` with a
        // snapshot taken before that opening line existed, and the project
        // would render a bare `on` with its opening line sitting on disk. The
        // first completer leaves the actor fully initialized, so returning
        // here is strictly safe.
        guard !loaded else { return }
        cached = try files.load()
        fingerprint = FileFingerprint(path: files.fileURL.path)
        spanStarts = recovered
        loaded = true
    }

    /// The file as it is on disk right now, reloading when the bytes changed.
    ///
    /// Synchronous on purpose: it is the first step of every read-modify-write,
    /// and a suspension between the read and the save is what would let two
    /// operators clobber each other.
    ///
    /// **Freshness is checked per operation rather than watched.** The file is
    /// hand-editable by design, and the daemon is its only programmatic writer,
    /// which rules a `FileWatcher` out on two counts. A watcher fires on this
    /// store's own atomic rewrites, so it would need self-write suppression —
    /// "was that edit mine?" bookkeeping that is wrong in exactly the cases it
    /// matters. And a watcher is debounced, so an operator who edits the file
    /// and immediately runs `tbd supervise on <project>` opens a window where
    /// the daemon computes from stale bytes and then rewrites them, silently
    /// destroying the edit. A `stat(2)` taken at the moment of the read closes
    /// that window by construction, at human-gesture rates, with no descriptor
    /// or dispatch source to keep alive.
    private func freshFile() throws -> SupervisionFile {
        let current = FileFingerprint(path: files.fileURL.path)
        guard current != fingerprint else { return cached }
        storeLogger.debug(
            "supervision.json changed on disk; reloading \(self.files.fileURL.path, privacy: .public)")
        cached = try files.load()
        fingerprint = current
        // The reload may have taken coverage away from a project this store is
        // still holding a span for. Closing that span needs the ledger, which
        // needs a suspension this method must not take — see
        // `reconcileExternalEdits(repos:)`, which drains the flag.
        sawExternalEdit = true
        return cached
    }

    /// Write the file, then adopt it. A throw leaves `cached` and the file
    /// itself untouched: `SupervisionFileStore.save` validates before it
    /// touches the disk and writes through a temp-and-rename, so a refused or
    /// failed save is byte-identical to no save at all.
    private func persist(_ updated: SupervisionFile) throws {
        try files.save(updated)
        cached = updated
        fingerprint = FileFingerprint(path: files.fileURL.path)
    }

    // MARK: - Reconciling what an edit outside this store did

    /// Close the coverage of any project this store holds a span for that the
    /// file no longer covers, after an edit this store did not make.
    ///
    /// The ledger is written from the gesture path, so without this a mark
    /// cleared by hand — or a repo removed, or a singleton absorbed by a hand
    /// edit — would leave the span open forever, and the next `on` would append
    /// a second `projectOn` over it. A reader would then see one span covering
    /// hours in which the mark was off. The file is hand-editable **by design**,
    /// so that is a foreseeable state, not abuse.
    ///
    /// **The closing line is timestamped when the daemon noticed, not when the
    /// operator edited**, because the daemon does not know when they edited.
    /// That overstates the span by the un-noticed interval — bounded by the
    /// heartbeat's cadence, since the heartbeat reads through here every minute
    /// — and the alternative overstates it by everything that follows, forever.
    /// Noticing is an observation the daemon really made; inventing an earlier
    /// end time would not be.
    ///
    /// **This is not the startup path.** `ensureLoaded` never sets the flag this
    /// drains, so a restart still writes no line: a mark that is off with an
    /// open span in the record simply renders off, which is what a bare `on`
    /// with no opening line already means on the readout.
    ///
    /// The reverse case is deliberately not handled: a mark *added* by hand
    /// gets no synthesized `projectOn`. Writing one would make TBD the author
    /// of a decision the operator made in a text editor, at a time it guessed.
    private func reconcileExternalEdits(repos: [SupervisionRepo]) {
        guard sawExternalEdit else { return }
        sawExternalEdit = false
        guard !spanStarts.isEmpty else { return }

        let file = cached
        // A file that will not resolve tells us nothing about which projects
        // still exist, so close nothing: leaving a span open is recoverable,
        // and closing one on a guess is not. The reload already ran
        // `validate()`, so the only condition that reaches here is a declared
        // name colliding with a repo's own project — a real state, and one
        // worth saying out loud rather than swallowing.
        let projects: [SupervisionProject]
        do {
            projects = try SupervisionTopology.resolve(file: file, repos: repos)
        } catch {
            let reason = String(describing: error)
            storeLogger.error(
                """
                Could not reconcile coverage after an edit to \
                \(self.files.fileURL.path, privacy: .public): \(reason, privacy: .public). \
                Open spans are left open rather than closed on a guess.
                """)
            return
        }
        let covered = Set(projects.filter(\.mark).map(\.name))
        orphanedSpans = spanStarts.keys
            .filter { !covered.contains($0) }
            .sorted()
            .map { (project: $0, mode: file.activeMode(for: $0)) }
    }

    /// Projects whose spans `reconcileExternalEdits` found orphaned, waiting for
    /// the ledger append that closes them. Held between the synchronous
    /// detection and the asynchronous write so neither has to happen in the
    /// other's context.
    private var orphanedSpans: [(project: String, mode: String)] = []

    private func closeOrphanedSpans() async {
        guard !orphanedSpans.isEmpty else { return }
        let orphans = orphanedSpans
        orphanedSpans = []
        for orphan in orphans {
            storeLogger.notice(
                """
                Coverage of "\(orphan.project, privacy: .public)" ended outside TBD — closing \
                its span on the record as of now.
                """)
            await appendProjectOff(project: orphan.project, mode: orphan.mode, at: now())
        }
    }

    /// Everything every entry point does before it touches the file: load once,
    /// read the repo list, and settle any coverage an outside edit ended.
    ///
    /// Returns the repo list, because every caller needs it and resolving
    /// topology without it is impossible.
    private func prepare() async throws -> [SupervisionRepo] {
        try await ensureLoaded()
        let repos = try await fleet.repos()
        // `freshFile()` is what notices an outside edit, so this pass primes the
        // flag that the drain below consumes.
        _ = try freshFile()
        reconcileExternalEdits(repos: repos)
        await closeOrphanedSpans()
        return repos
    }

    /// The projects a topology edit stops resolving, and the coverage that has
    /// to end with them.
    ///
    /// **Computed by comparing resolved project sets, not declarations.** A
    /// singleton has no entry in `projects`, so a rule phrased over declarations
    /// misses the two edits that make one stop resolving — a `move` absorbing it
    /// into a declared project, and a `create` that names it as a member — and
    /// both are ordinary operator gestures. Getting this wrong is not merely a
    /// missing line: the absorbed project keeps its mark, so dissolving the
    /// group later brings it back **on**, hours later, with no gesture and no
    /// opening line. Comparing what resolves before against what resolves after
    /// covers every way a project can vanish, including ones no verb has yet.
    private func applyTopologyEdit(
        from file: SupervisionFile, to proposed: SupervisionFile, repos: [SupervisionRepo]
    ) async throws -> SuperviseProjectListResult {
        let before = try SupervisionTopology.resolve(file: file, repos: repos)
        // Resolving the proposal is also what validates it — a name colliding
        // with a repo's own project throws here, before anything is written.
        let after = try SupervisionTopology.resolve(file: proposed, repos: repos)
        let surviving = Set(after.map(\.name))
        let vanished = before.filter { !surviving.contains($0.name) }

        // A vanished project leaves nothing behind that could bind a future
        // project of the same name — the mark above all, but the mode selection
        // and supervisor binding with it, matching what `SupervisionTopology`
        // already does for a declaration a move empties.
        var updated = proposed
        for project in vanished {
            updated.supervised.removeAll { $0 == project.name }
            updated.modes.removeValue(forKey: project.name)
            updated.supervisors.removeValue(forKey: project.name)
        }

        let result = try topologyResult(file: updated, repos: repos)
        try persist(updated)

        for project in vanished where project.mark {
            await appendProjectOff(
                project: project.name, mode: project.activeMode, at: now())
        }
        return result
    }

    // MARK: - Status

    /// The `supervise.status` readout.
    public func status(brake: SupervisionBrakeState) async throws -> SupervisionStatus {
        let repos = try await prepare()
        let file = try freshFile()
        let projects = try SupervisionTopology.resolve(file: file, repos: repos)
        let markedProjects = projects.filter(\.mark)
        let effectivelySupervising = brake == .released && !markedProjects.isEmpty

        // The two halves of "nothing is watching" are separate codes because
        // they call for opposite actions — mark a project, or release the brake
        // — and `effectivelySupervising` is false in both, so it cannot tell
        // them apart.
        var warnings: [SupervisionWarning] = []
        if brake == .released && markedProjects.isEmpty {
            warnings.append(SupervisionWarning(
                code: .noProjectsOn,
                message: "the brake is released but no project is on — nothing is being supervised."))
        }
        // Only when a mark actually stands. An engaged brake over a fleet with
        // nothing marked is a deliberately quiet system; warning there would
        // train an operator to ignore the line.
        if brake == .engaged && !markedProjects.isEmpty {
            let named = markedProjects.map { "\"\($0.name)\"" }.joined(separator: ", ")
            let verb = markedProjects.count == 1 ? "is" : "are"
            warnings.append(SupervisionWarning(
                code: .brakeEngagedWithProjectsOn,
                message: """
                    the fleet brake is engaged, so nothing is being supervised — \(named) \
                    \(verb) marked on and will resume the moment the brake is released.
                    """))
        }
        let unusable = SupervisionTopology.projectsWithoutUsableDirectory(in: projects)
        if !unusable.isEmpty {
            warnings.append(SupervisionWarning(
                code: .unusableProjectName, message: Self.unusableNameSentence(unusable)))
        }
        // These repos resolve to no project at all, so they appear in no row
        // above — the warning is the only place their absence is visible.
        let ambiguous = SupervisionTopology.ambiguousRepoNames(file: file, repos: repos)
        if !ambiguous.isEmpty {
            warnings.append(SupervisionWarning(
                code: .ambiguousRepoName, message: Self.ambiguousNameSentence(ambiguous)))
        }

        return SupervisionStatus(
            brake: brake,
            effectivelySupervising: effectivelySupervising,
            projects: projects.map { project in
                SupervisionStatusProject(
                    name: project.name,
                    on: project.mark,
                    mode: project.activeMode,
                    declaredModes: project.declaredModes,
                    supervisor: project.supervisor,
                    // An off project renders exactly `off`: no span, and never
                    // a "was on until". A third rendering would imply a third
                    // state that does not exist.
                    spanStartedAt: project.mark ? spanStarts[project.name] : nil,
                    lastSweepContactAt: lastSweepContact[project.name],
                    // The declared contact window lives in the project's sweep
                    // selection, whose vocabulary belongs to the sweep program.
                    // Nothing here invents one: null is what the readout renders
                    // as "coverage unknown", the honest not-yet value.
                    coverageWindow: nil)
            },
            warnings: warnings)
    }

    /// The sentence the `unusableProjectName` warning carries. It names the
    /// projects — the CLI's own fallback wording cannot, since it sees only the
    /// code.
    static func unusableNameSentence(_ names: [String]) -> String {
        let quoted = names.map { "\"\($0)\"" }.joined(separator: ", ")
        let subject = names.count == 1 ? "it" : "them"
        let verb = names.count == 1 ? "is" : "are"
        return """
            \(quoted) cannot be used as a directory name, so nothing can be written beside \
            \(subject) — no playbook, journal, proposals or programs. \
            \(names.count == 1 ? "It" : "They") \(verb) supervised like any other project; \
            rename the repo to give \(subject) a directory.
            """
    }

    /// The sentence the `ambiguousRepoName` warning carries. It names both the
    /// name and the repos holding it, because the operator's fix — rename one,
    /// or declare a project over them — needs to know which ones.
    static func ambiguousNameSentence(_ ambiguous: [SupervisionAmbiguousRepoName]) -> String {
        let clauses = ambiguous.map { entry in
            "\(entry.repos.count) repos are named \"\(entry.name)\" "
                + "(\(entry.repos.map(\.uuidString).joined(separator: ", ")))"
        }
        return """
            \(clauses.joined(separator: "; ")). A project is identified by its name, so two \
            candidates for one name identify nothing: those repos resolve to no project and \
            are not supervised. The rest of the fleet is unaffected. Rename one, or declare a \
            project naming them.
            """
    }

    /// The machinery facts one project's readout carries, resolved through the
    /// same topology every other gesture uses.
    ///
    /// Goes through `prepare()` like every other entry point, so an edit made
    /// to `supervision.json` in a text editor is noticed and its orphaned
    /// coverage reconciled before the facts are read — a readout computed from
    /// stale bytes would report a mark the operator cleared minutes ago.
    ///
    /// **An unknown project is refused, never answered with an empty readout.**
    /// A readout carrying no agents reads as "this project has no agents", and
    /// a program that mistook "there is no such project" for that would report
    /// a quiet fleet where it should have reported a typo.
    public func projectFacts(project: String, brake: SupervisionBrakeState) async throws
        -> SupervisionProjectFacts {
        let repos = try await prepare()
        let file = try freshFile()
        let projects = try SupervisionTopology.resolve(file: file, repos: repos)
        guard let resolved = projects.first(where: { $0.name == project }) else {
            throw SupervisionStoreError.unknownProject(project)
        }
        return SupervisionProjectFacts(
            project: resolved,
            brake: brake,
            // An off project has no span, exactly as `status` renders it: a
            // third rendering here would imply a third state that does not
            // exist.
            spanStartedAt: resolved.mark ? spanStarts[project] : nil,
            lastSweepContactAt: lastSweepContact[project])
    }

    /// The supervision ledger this store appends to. Exposed so the read-only
    /// `supervise.ledger` query reads the same file the writer writes, through
    /// the path its caller injected — never one derived from `$HOME`.
    public nonisolated var ledgerPath: String { ledger.path }

    /// The heartbeat's view of the same facts (design §14).
    public func statusFileSnapshot(brake: SupervisionBrakeState) async throws
        -> SupervisionStatusFile {
        let repos = try await prepare()
        let file = try freshFile()
        let projects = try SupervisionTopology.resolve(file: file, repos: repos)
        return SupervisionStatusFile(
            writtenAt: SupervisionInstant(now()),
            brake: brake,
            projects: projects.map { project in
                SupervisionStatusFileProject(
                    name: project.name,
                    on: project.mark,
                    mode: project.activeMode,
                    lastSweepContactAt: lastSweepContact[project.name])
            })
    }

    // MARK: - Marks

    /// Set or clear a project's standing mark.
    ///
    /// A project name that resolves to nothing is refused rather than recorded.
    /// The file itself keeps an unknown name in `supervised` verbatim — a hand
    /// edit may name a project about to be declared — but a *gesture* that
    /// names one is a typo far more often than a plan, and accepting it would
    /// buy silent non-coverage, which is the failure this whole surface exists
    /// to prevent.
    public func setProjectMark(project: String, on: Bool) async throws
        -> SuperviseSetProjectMarkResult {
        let repos = try await prepare()

        // The roster has to be read before the mark is committed — a snapshot
        // taken afterwards could fail, leaving the gesture done and the caller
        // told it failed — but reading it is a suspension, and a suspension
        // between the read and the write is what lets two operators clobber
        // each other. So: decide, snapshot, then commit only if the file has
        // not moved underneath, and start over if it has. Three attempts is a
        // bound on a race that human-rate gestures essentially never lose.
        for _ in 0..<3 {
            let file = try freshFile()
            let projects = try SupervisionTopology.resolve(file: file, repos: repos)
            guard let resolved = projects.first(where: { $0.name == project }) else {
                throw SupervisionStoreError.unknownProject(project)
            }
            let updated = file.settingMark(project, on: on)
            guard updated != file else {
                return SuperviseSetProjectMarkResult(project: project, on: on, changed: false)
            }
            // Spelled out rather than as a ternary: `try await` inside one
            // branch of `?:` sits to the right of a non-assignment operator,
            // which the grammar does not accept.
            let roster: [SupervisionRosterEntry]
            if on {
                roster = try await rosterSnapshot(for: resolved)
            } else {
                roster = []
            }
            guard try freshFile() == file else { continue }

            try persist(updated)
            let at = now()
            if on {
                let recorded = await ledger.append(SupervisionLedgerLine.projectOn(
                    project: project, mode: resolved.activeMode, roster: roster, at: at))
                // The span start is memory of the record, not a second copy of
                // it: if the opening line did not land, the span reads as
                // unknown here exactly as it would after a restart, and the
                // status renders a bare `on` rather than inventing a start.
                if recorded { spanStarts[project] = SupervisionInstant(at) }
            } else {
                await appendProjectOff(project: project, mode: resolved.activeMode, at: at)
            }
            return SuperviseSetProjectMarkResult(project: project, on: on, changed: true)
        }
        throw SupervisionStoreError.concurrentEdit(project: project)
    }

    /// The `projectOff` line and the span bookkeeping that goes with it. Shared
    /// by the explicit `off` gesture and by the two topology edits that end a
    /// project's life while its mark still stands.
    private func appendProjectOff(project: String, mode: String, at date: Date) async {
        let coverage = SupervisionCoverageSummary(
            spanStartedAt: spanStarts[project],
            spanEndedAt: SupervisionInstant(date),
            sweepContacts: sweepContacts[project] ?? 0,
            briefingsDelivered: briefingsDelivered[project] ?? 0)
        spanStarts.removeValue(forKey: project)
        sweepContacts.removeValue(forKey: project)
        briefingsDelivered.removeValue(forKey: project)
        await ledger.append(SupervisionLedgerLine.projectOff(
            project: project, mode: mode, coverage: coverage, at: date))
    }

    /// One entry per agent already inside the project's perimeter, for the
    /// `projectOn` line's roster snapshot (design §6).
    private func rosterSnapshot(for project: SupervisionProject) async throws
        -> [SupervisionRosterEntry] {
        let agents = try await fleet.agents(inRepos: Set(project.repos))
        return agents
            .map { agent in
                SupervisionRosterEntry(
                    worktree: agent.worktree, terminal: agent.terminal, repo: agent.repo,
                    project: project.name, spawnSource: agent.spawnSource,
                    transcriptPath: agent.transcriptPath)
            }
            .sorted { $0.terminal.uuidString < $1.terminal.uuidString }
    }

    // MARK: - Modes

    public func setMode(project: String, mode: String) async throws -> SuperviseSetModeResult {
        let repos = try await prepare()

        // Read-modify-write, no suspension inside.
        let file = try freshFile()
        let projects = try SupervisionTopology.resolve(file: file, repos: repos)
        guard let resolved = projects.first(where: { $0.name == project }) else {
            throw SupervisionStoreError.unknownProject(project)
        }
        guard resolved.declaredModes.contains(mode) else {
            throw SupervisionStoreError.modeNotDeclared(
                project: project, requested: mode, declared: resolved.declaredModes)
        }
        let previous = resolved.activeMode
        guard previous != mode else {
            return SuperviseSetModeResult(
                project: project, mode: mode, declaredModes: resolved.declaredModes,
                changed: false)
        }
        try persist(file.settingMode(project, to: mode))

        await ledger.append(SupervisionLedgerLine.modeChanged(
            project: project, from: previous, to: mode, at: now()))
        return SuperviseSetModeResult(
            project: project, mode: mode, declaredModes: resolved.declaredModes, changed: true)
    }

    // MARK: - The playbook

    /// The project's resolved playbook: which level stands, where it is, its
    /// hash, and its bytes.
    ///
    /// Read-only, and it resolves through the same topology every other gesture
    /// uses — so the operator level a *declared* project reads and the one a
    /// singleton reads are decided from the file this store already holds,
    /// never guessed from the name.
    ///
    /// An unknown project is refused rather than answered with the shipped
    /// default. A caller that mistook "there is no such project" for "this
    /// project has no customized playbook" would report the tool's own conduct
    /// as the project's.
    public func playbook(project: String) async throws -> SupervisionPlaybookView {
        let repos = try await prepare()
        let file = try freshFile()
        let projects = try SupervisionTopology.resolve(file: file, repos: repos)
        guard let resolved = projects.first(where: { $0.name == project }) else {
            throw SupervisionStoreError.unknownProject(project)
        }
        return SupervisionPlaybookView(
            playbooks.resolve(project: resolved, in: file, repos: repos))
    }

    /// Everything `SupervisionDeskManager.ensureDesk` needs, read in one pass
    /// through the file this store owns: the project's active mode, its
    /// resolved playbook, and its appointed supervisor binding if one stands.
    ///
    /// Exists so the desk manager resolves no topology of its own. This store is
    /// the single reader of `supervision.json`, and a second reader would be a
    /// second answer to a question with exactly one.
    public func deskInputs(project: String) async throws -> SupervisionDeskInputs {
        let repos = try await prepare()
        let file = try freshFile()
        let projects = try SupervisionTopology.resolve(file: file, repos: repos)
        guard let resolved = projects.first(where: { $0.name == project }) else {
            throw SupervisionStoreError.unknownProject(project)
        }
        return SupervisionDeskInputs(
            project: project,
            mode: resolved.activeMode,
            playbook: playbooks.resolve(project: resolved, in: file, repos: repos),
            appointed: file.supervisors[project])
    }

    /// The names of every project whose mark stands right now.
    ///
    /// Read-only, and it exists for exactly one caller: the Nightwatch
    /// coexistence gate, which must refuse turning Nightwatch on while any
    /// project is supervised. Kept narrow deliberately — `status` computes
    /// warnings and a whole readout, none of which that gate has any business
    /// evaluating.
    public func markedProjects() async throws -> [String] {
        let repos = try await prepare()
        let file = try freshFile()
        return try SupervisionTopology.resolve(file: file, repos: repos)
            .filter(\.mark)
            .map(\.name)
    }

    /// The "Customize playbook…" gesture: copy the current shipped default into
    /// one level, once.
    ///
    /// **Refused when the target already exists, and that refusal is the whole
    /// contract.** The operator and repository levels are written exactly once
    /// and TBD never writes them again — no overwrite, no merge, and no
    /// reconciliation at startup (design §5). Tool-provided content lives only
    /// in the level the tool owns, the shipped default, which updates may
    /// freely replace.
    ///
    /// **The bytes copied are the shipped default's, not the resolved
    /// playbook's.** Customizing the repo level of a project that already has an
    /// operator copy must not silently duplicate that copy one level down; the
    /// gesture means "give me the tool's default to edit".
    ///
    /// **Who reclaims the file this creates** (repo `CLAUDE.md`, "Every durable
    /// external resource needs a named reconciler"), by level, because the
    /// three levels are three different questions.
    ///
    /// - The **repo level** writes into the operator's own checkout. TBD does
    ///   not own that directory or its lifetime — git versions the file and
    ///   removing the repo from TBD leaves the checkout untouched — so no
    ///   orphan of TBD's making can arise there. Reclaiming it would be the
    ///   bug.
    /// - A **singleton's operator level** adds one file to
    ///   `~/tbd/repos/<id>/`, the existing per-repo family that already holds
    ///   `notes.md`, the hooks and the settings overlay. It is a call site in a
    ///   family whose treatment predates this gesture, not a new kind of
    ///   resource.
    /// - A **declared project's operator level** lives in that project's
    ///   directory, which design §7 makes permanent by decision: nothing
    ///   reclaims it, because "the project no longer resolves" is not an orphan
    ///   signal (a renamed repo stops resolution with the mark still standing,
    ///   §9), because one directory per human-declared project has no
    ///   unbounded-growth mode, and because its contents are the one thing §5
    ///   promises the tool writes once and never touches again.
    ///
    /// A stranded copy costs a file; a reclaimed one costs the operator's
    /// conduct.
    public func customizePlaybook(
        project: String, level: SupervisionPlaybookLevel
    ) async throws -> SupervisePlaybookCustomizeResult {
        let repos = try await prepare()
        let file = try freshFile()
        let projects = try SupervisionTopology.resolve(file: file, repos: repos)
        guard let resolved = projects.first(where: { $0.name == project }) else {
            throw SupervisionStoreError.unknownProject(project)
        }
        let site = playbooks.site(for: resolved, in: file, repos: repos)

        let target: String
        switch level {
        case .operator:
            guard let path = site.operatorPath else {
                throw SupervisionPlaybookError.noOperatorLevel(project: project)
            }
            target = path
        case .repo:
            guard let path = site.repoPath else {
                switch resolved.policy {
                case .operator:
                    throw SupervisionPlaybookError.noRepoLevel(project: project)
                case .repo(let repoID):
                    throw SupervisionPlaybookError.unknownRepoCheckout(
                        project: project, repo: repoID)
                }
            }
            // The repo level is the only one that writes outside `~/tbd`, and a
            // checkout on record can be gone from disk — that drift is why
            // `WorktreeLifecycle+Reconcile` exists. Without this the write below
            // would conjure `<gone-checkout>/.agents/` out of nothing, report
            // success, and then refuse forever because the file it invented is
            // there. Refusing while the ground truth is missing is the honest
            // answer, and it leaves the gesture available once it is back.
            if case .repo(let repoID) = resolved.policy,
               let checkout = repos.first(where: { $0.id == repoID })?.path,
               !FileManager.default.fileExists(atPath: checkout) {
                throw SupervisionPlaybookError.missingRepoCheckout(
                    project: project, checkout: checkout)
            }
            target = path
        }

        guard !FileManager.default.fileExists(atPath: target) else {
            throw SupervisionPlaybookError.alreadyCustomized(
                project: project, level: level, path: target)
        }

        let bytes = SupervisionPlaybookContent.bytes
        let url = URL(fileURLWithPath: target)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // `withoutOverwriting` closes the window between the check above and
            // the write: a second gesture that got past the same check writes
            // nothing rather than clobbering the first one's bytes.
            try bytes.write(to: url, options: .withoutOverwriting)
        } catch CocoaError.fileWriteFileExists {
            throw SupervisionPlaybookError.alreadyCustomized(
                project: project, level: level, path: target)
        } catch {
            throw SupervisionPlaybookError.writeFailed(
                path: target, detail: error.localizedDescription)
        }
        storeLogger.notice(
            """
            Wrote the shipped playbook to \(target, privacy: .public) for \
            "\(project, privacy: .public)"; TBD will never write that level again.
            """)

        return SupervisePlaybookCustomizeResult(
            project: project, level: level, path: target,
            hash: SupervisionPlaybook.hash(of: bytes))
    }

    // MARK: - The brake

    /// Serializes brake transitions. Actor isolation is not enough on its own:
    /// `commit` is an `await` on the database, and an actor releases itself
    /// across every suspension, so without this gate a second transition can
    /// run its whole commit-and-record while the first is still inside its own.
    private var brakeGateBusy = false
    private var brakeGateWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireBrakeGate() async {
        if brakeGateBusy {
            await withCheckedContinuation { brakeGateWaiters.append($0) }
            // Resumed by releaseBrakeGate(); `brakeGateBusy` stays true.
        } else {
            brakeGateBusy = true
        }
    }

    private func releaseBrakeGate() {
        if brakeGateWaiters.isEmpty {
            brakeGateBusy = false
        } else {
            brakeGateWaiters.removeFirst().resume()
        }
    }

    /// Commit a fleet brake change and record it as one indivisible step.
    ///
    /// **The commit and the line it justifies happen inside one serialized
    /// region, and that is the whole point of this method existing.** Putting
    /// the column's read-and-write in a single transaction makes the *column*
    /// atomic, but it says nothing about the order two transitions reach the
    /// ledger: two overlapping toggles — the CLI racing the app's Settings
    /// switch — could commit in one order and append in the other, leaving the
    /// record's last line disagreeing with the database about what the brake
    /// is now. The ledger is exactly what a watchdog or a person reads to
    /// answer that question, so a record that can contradict the live state is
    /// worse than no record.
    ///
    /// `commit` performs the database write and returns the **resolved**
    /// previous brake, so the decision "did this call actually move the brake"
    /// is made from a value read in the same transaction that wrote it. A call
    /// that moved nothing writes no line: the column is tri-state, so writing
    /// `false` over an unset column is a real gesture on the column and no
    /// change at all to what the brake means.
    ///
    /// The line carries no project and no mode, and cannot be given either —
    /// `SupervisionLedgerLine.brakeEngaged` / `.brakeReleased` take none, which
    /// is what keeps a fleet-wide line from ever naming one project.
    ///
    /// Orders brake transitions for consumers outside this actor. Assigned
    /// inside the gate, so its order is the commit order by construction.
    private var brakeSequence: UInt64 = 0

    /// - Returns: whether the brake actually moved, and the ordering token that
    ///   says where this transition sits relative to every other one.
    @discardableResult
    public func applyBrakeChange(
        released: Bool, commit: @Sendable () async throws -> Bool
    ) async throws -> SupervisionBrakeTransition {
        await acquireBrakeGate()
        defer { releaseBrakeGate() }

        brakeSequence += 1
        let sequence = brakeSequence
        let wasReleased = try await commit()
        guard wasReleased != released else {
            return SupervisionBrakeTransition(changed: false, sequence: sequence)
        }
        let at = now()
        await ledger.append(released
            ? SupervisionLedgerLine.brakeReleased(at: at)
            : SupervisionLedgerLine.brakeEngaged(at: at))
        return SupervisionBrakeTransition(changed: true, sequence: sequence)
    }

    // MARK: - Projects

    public func projectList() async throws -> SuperviseProjectListResult {
        let repos = try await prepare()
        let file = try freshFile()
        return try topologyResult(file: file, repos: repos)
    }

    public func projectCreate(
        name: String, repos identifiers: [String], policy: SupervisionPolicyRequest
    ) async throws -> SuperviseProjectListResult {
        let repos = try await prepare()

        // Read-modify-write, no suspension inside.
        let file = try freshFile()
        guard file.projects[name] == nil else {
            throw SupervisionStoreError.projectAlreadyDeclared(name)
        }
        let members = try identifiers.map { try resolveRepo($0, in: repos) }
        let resolvedPolicy: SupervisionPolicySource
        switch policy {
        case .operator: resolvedPolicy = .operator
        case .repo(let identifier): resolvedPolicy = .repo(try resolveRepo(identifier, in: repos))
        }

        var updated = file
        updated.projects[name] = SupervisionProjectDeclaration(
            repos: members, policy: resolvedPolicy)
        // Declaring a group over repos that were their own projects makes each
        // of those stop resolving — and a marked one's coverage ends there,
        // whether or not the operator was thinking of it that way. Validation
        // runs inside the same helper, before anything is written, so a refused
        // create is byte-identical to no create at all.
        return try await applyTopologyEdit(from: file, to: updated, repos: repos)
    }

    /// Delete a declaration, returning its repos to being their own projects.
    ///
    /// The vanished project's mark, mode entry and supervisor binding go with
    /// it — a mark outliving its project would silently turn a later project of
    /// the same name on without an operator gesture. Where the mark stood, the
    /// project's coverage genuinely ends here, so its span is closed on the
    /// record like any other `off`.
    public func projectDelete(name: String) async throws -> SuperviseProjectListResult {
        let repos = try await prepare()

        // Read-modify-write, no suspension inside.
        let file = try freshFile()
        guard file.projects[name] != nil else {
            throw SupervisionStoreError.unknownProject(name)
        }
        var updated = file
        updated.projects.removeValue(forKey: name)
        // The mark, mode and binding go with the declaration, and the coverage
        // ends with it — all of that is `applyTopologyEdit`'s job, which sees
        // this project stop resolving. Deleting a group also makes its members
        // resolve again as their own projects, which the same comparison
        // handles: they appear rather than vanish.
        return try await applyTopologyEdit(from: file, to: updated, repos: repos)
    }

    /// Move a repo between projects — the only membership verb.
    ///
    /// The transform is `SupervisionTopology.move`, a pure function over the
    /// file, so a repo can never land in zero or two projects: the input is
    /// taken by value, a refusal throws before anything is written, and a save
    /// that fails leaves both the file and this actor's copy exactly as they
    /// were.
    public func projectMove(repo identifier: String, to target: SupervisionMoveTarget) async throws
        -> SuperviseProjectListResult {
        let repos = try await prepare()

        // Read-modify-write, no suspension inside.
        let file = try freshFile()
        let repoID = try resolveRepo(identifier, in: repos)
        let updated = try SupervisionTopology.move(
            repo: repoID, to: target, in: file, repos: repos)
        guard updated != file else { return try topologyResult(file: file, repos: repos) }

        // Absorbing a repo into a declared project makes that repo's own
        // project stop resolving — and a singleton has no declaration, so only
        // comparing what resolves catches it. See `applyTopologyEdit`.
        return try await applyTopologyEdit(from: file, to: updated, repos: repos)
    }

    private func topologyResult(file: SupervisionFile, repos: [SupervisionRepo]) throws
        -> SuperviseProjectListResult {
        let names = Dictionary(
            repos.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let projects = try SupervisionTopology.resolve(file: file, repos: repos)
        return SuperviseProjectListResult(projects: projects.map { project in
            SupervisionProjectTopologyEntry(
                name: project.name,
                repos: project.repos.map { id in
                    SupervisionProjectRepoRef(id: id, name: names[id] ?? id.uuidString)
                },
                policy: project.policy,
                sweepScript: project.sweep?.script)
        })
    }

    /// Resolve a repo id or display name to a repo.
    ///
    /// A display name shared by two repos is refused naming the condition,
    /// never guessed: the operator typed one name and there are two answers, so
    /// there is nothing to act on.
    ///
    /// Refusing here does not contradict `SupervisionTopology.resolve`, which
    /// *reports* the same ambiguity as a warning and carries on covering the
    /// rest of the fleet. The two are asymmetric on purpose. Reading is a
    /// question about everything, and one repo's naming must not take the
    /// fleet's coverage down; a gesture is a question about one repo, and
    /// picking either candidate would act on a repo the operator did not name.
    private func resolveRepo(_ identifier: String, in repos: [SupervisionRepo]) throws -> UUID {
        if let id = UUID(uuidString: identifier) {
            guard repos.contains(where: { $0.id == id }) else {
                throw SupervisionStoreError.unknownRepoIdentifier(identifier)
            }
            return id
        }
        let matches = repos.filter { $0.name == identifier }
        switch matches.count {
        case 0: throw SupervisionStoreError.unknownRepoIdentifier(identifier)
        case 1: return matches[0].id
        default: throw SupervisionStoreError.ambiguousRepoName(identifier, repos: matches.map(\.id))
        }
    }

    // MARK: - The brief pipe

    /// Take one briefing submission and answer, synchronously, what became of
    /// it (`docs/specs/2026-08-01-fleet-supervision-sweep-program-design.md` §3,
    /// `docs/cli-supervise.md`).
    ///
    /// **The order of the steps is the design, not an implementation detail.**
    ///
    /// 1. *Resolve the project.* An unknown name is refused — never answered
    ///    with an empty success, for the same reason `projectFacts` refuses
    ///    one: a program that mistook a typo for "nothing to report" would
    ///    report a quiet fleet.
    /// 2. *Refuse for a standing state, before anything is recorded.* An off
    ///    project answers `refused-off`; an engaged brake answers
    ///    `refused-paused`. Neither records contact: the contact window is
    ///    disarmed while coverage is closed, so no contact is owed and none is
    ///    counted.
    /// 3. *Record the contact* — for every submission past step 2, empty or
    ///    not, and **before** the remaining refusals. That ordering is the
    ///    point: a sweep program whose composer has a runaway bug and submits
    ///    300 KiB every tick must read as *broken*, not as *silent*. Silence is
    ///    the one signal reserved for "nobody looked".
    /// 4. *An empty submission stops here*, answering `delivered`.
    /// 5. *Size bound*, on bytes.
    /// 6. *Pace*, identity-blind, on timestamps alone — the window is *tested*
    ///    here and *spent* in step 7.
    /// 7. *Deliver* — one full attempt, never a retry. Persistence is the
    ///    submitting program's concern; TBD's job is an honest synchronous
    ///    result. A briefing that reached a supervisor spends the pacing slot;
    ///    one that reached nobody leaves it for the resubmission.
    ///
    /// **`refused-off` wins when a project is off and the brake is engaged.**
    /// Off is a standing state: releasing the brake would change nothing, so
    /// answering "retry when supervision resumes" would send the program back
    /// forever. `refused-off` is the answer that says *stop submitting*, which
    /// is the correct advice in that state.
    ///
    /// **This creates no durable external resource.** The pacing and liveness
    /// state above is in memory and dies with the process, and the only write
    /// path is an append to the ledger, a file `SupervisionLedgerWriter`
    /// creates and owns. Nothing here is orphanable, so no reconciler is owed
    /// one (repo `CLAUDE.md`, "Every durable external resource needs a named
    /// reconciler").
    ///
    /// **No step reads the briefing text.** Its byte count and whether that
    /// count is zero are the only two facts taken from it, and that boundary is
    /// what the whole design rests on.
    public func submitBriefing(
        project: String, text: String, brake: SupervisionBrakeState,
        deliverer: any SupervisionBriefingDelivering
    ) async throws -> SupervisionBriefResult {
        // 1. Resolve. Throws `unknownProject` — a refusal, never an empty
        // success.
        let facts = try await projectFacts(project: project, brake: brake)
        let at = now()

        // 2. The standing states, before anything is recorded. Off is checked
        // first on purpose: with both conditions true, "stop submitting" is the
        // advice that holds, while "retry when supervision resumes" would send
        // a program back to a project that is off regardless of the brake.
        if !facts.project.mark {
            return Self.briefResult(project: project, outcome: .refusedOff, at: at, detail: """
                Project "\(project)" is off, so nothing is supervising it — this briefing was \
                not delivered and no contact was recorded. Turn it on with \
                "tbd supervise on \(project)" rather than resubmitting.
                """)
        }
        if brake == .engaged {
            return Self.briefResult(project: project, outcome: .refusedPaused, at: at, detail: """
                The fleet brake is engaged, so nothing was delivered and no contact was \
                recorded. Retry when supervision resumes.
                """)
        }

        // 3. Contact, for every submission that got past the standing states,
        // and ahead of every remaining refusal so that a broken composer reads
        // as broken rather than silent.
        noteSweepContact(project: project, at: at)

        // 4. Empty means zero bytes, and nothing else. Whitespace is not empty:
        // TBD does not read the text, and deciding that a briefing of three
        // newlines "says nothing" would be reading it.
        //
        // `delivered` here carries the widened sense the outcome's own doc
        // comment states — the submission was accepted and everything it
        // required happened, which for a quiet contact is the liveness update
        // alone. It writes no ledger line, and pacing never applies to it: its
        // durable trace is the coverage summary on the lifecycle line that ends
        // the span, and throttling the heartbeat would make a healthy sweep
        // look like a dead one.
        guard !text.utf8.isEmpty else {
            return Self.briefResult(project: project, outcome: .delivered, at: at, detail: """
                Quiet contact recorded for "\(project)"; nothing delivered.
                """)
        }

        // 5. Bytes, not characters — the bound is on what gets stored and sent.
        // Contact is already recorded by now, which is the whole reason step 3
        // precedes this.
        let size = text.utf8.count
        guard size <= SupervisionBriefing.maxBriefingBytes else {
            return Self.briefResult(project: project, outcome: .refusedSize, at: at, detail: """
                The briefing is \(size) bytes, over the \
                \(SupervisionBriefing.maxBriefingBytes)-byte bound, so it was not delivered — \
                compose a smaller one. The contact was recorded.
                """)
        }

        // 6. Pace — the window is tested here and spent in step 7. Timestamps
        // and the project name, and nothing else: the moment this consults who
        // is submitting or what the text says, pacing stops being a mechanism
        // and becomes a policy, and policy is user-land's.
        if let spent = lastPacedBriefing[project],
           at.timeIntervalSince(spent) < SupervisionBriefing.rateLimitInterval {
            let opensAt = spent.addingTimeInterval(SupervisionBriefing.rateLimitInterval)
            return Self.briefResult(
                project: project, outcome: .refusedRateLimit, at: at,
                retryAfter: SupervisionInstant(opensAt),
                detail: """
                    A briefing for "\(project)" went out less than \
                    \(Int(SupervisionBriefing.rateLimitInterval)) seconds ago, so this one was \
                    not delivered. The window lifts at \(SupervisionInstant(opensAt).wireValue). \
                    The contact was recorded.
                    """)
        }
        // 7. One full attempt, never a retry — adapter fallback included. What
        // happens next is the submitting program's continuation policy, which
        // is why the result stays specific instead of collapsing into a generic
        // failure.
        let outcome = await deliverer.deliver(project: project, text: text)
        if outcome == .delivered {
            // The slot is spent only for a briefing that actually reached a
            // supervisor — the pipe paces *delivered* briefings, which is what
            // both §3 and §10 say and what the rate limit is for. A submission
            // refused as paused, off or oversize therefore never burns it, and
            // neither does one that reached nobody: `no-live-supervisor` is the
            // answer whose documented remedy is to run `on` and resubmit in the
            // same run, and a slot spent on a briefing nobody received would
            // refuse that resubmission for two minutes.
            //
            // Guarded on `outcome` — the deliverer's verdict — rather than on
            // the result this function returns. The two differ: a quiet contact
            // also answers `delivered`, in the wider sense the outcome's own
            // doc comment states, and it returns at step 4 without ever
            // reaching a deliverer. Keying the commit here is what keeps
            // "pacing never applies to quiet contact" true.
            //
            // Accepted residual: the stamp is `at`, taken at step 1, so the
            // window is measured from when the submission was taken rather than
            // from when delivery completed. That matches "enforced on
            // timestamps alone" and the difference is sub-second in practice.
            lastPacedBriefing[project] = at
            noteBriefingDelivered(project: project)
            // Slice 5, which ships delivery, owes the ledger's `delivery` line
            // here: written request-first, carrying the delivered text's hash
            // and the conduct hash (design §6, §12). Nothing delivers yet, so
            // there is no untested branch pretending to write one.
        }
        return Self.briefResult(
            project: project, outcome: outcome, at: at,
            detail: Self.deliveryDetail(project: project, outcome: outcome))
    }

    /// One submission's answer, assembled in one place so every outcome carries
    /// the same shape — and so `retryAfter` is null everywhere except
    /// `refused-rate-limit`, whose remedy is the only one that is "wait".
    private static func briefResult(
        project: String, outcome: SupervisionBriefOutcome, at date: Date,
        retryAfter: SupervisionInstant? = nil, detail: String
    ) -> SupervisionBriefResult {
        SupervisionBriefResult(
            project: project, result: outcome, submittedAt: SupervisionInstant(date),
            detail: detail, retryAfter: retryAfter)
    }

    /// The sentence a human reads for an outcome the deliverer decided. Never
    /// parsed — the machine-readable answer is `result`.
    private static func deliveryDetail(
        project: String, outcome: SupervisionBriefOutcome
    ) -> String {
        switch outcome {
        case .delivered:
            return "Delivered to \"\(project)\"'s supervisor."
        case .noLiveSupervisor:
            return """
                No supervisor stands for "\(project)", so the briefing was not delivered. \
                Establish one and resubmit; the contact was recorded.
                """
        case .transportFailed:
            return """
                The delivery attempt to "\(project)"'s supervisor failed. TBD makes one \
                attempt and never retries a briefing; the contact was recorded.
                """
        // The refusals above never reach the deliverer, so an outcome landing
        // here would mean a deliverer answered with one. Say what happened
        // rather than inventing a remedy for a state that has none.
        case .refusedOff, .refusedPaused, .refusedRateLimit, .refusedSize:
            return """
                The delivery attempt for "\(project)" answered \(outcome.rawValue); nothing \
                was delivered.
                """
        }
    }

    // MARK: - Counters the coverage summary reports

    /// Record that a sweep program made contact with a project — every briefing
    /// submission that gets past the standing-state refusals, empty or not.
    ///
    /// Called from `submitBriefing` step 3, which is the obligation this method
    /// was written for: without it the closing line's `sweepContacts` and the
    /// status readout's `lastSweepContactAt` would lie the moment briefings
    /// exist.
    public func noteSweepContact(project: String, at date: Date) {
        sweepContacts[project, default: 0] += 1
        lastSweepContact[project] = SupervisionInstant(date)
    }

    /// Record that a briefing was delivered to a project's supervisor. Called
    /// from `submitBriefing` step 7, on delivery only.
    public func noteBriefingDelivered(project: String) {
        briefingsDelivered[project, default: 0] += 1
    }
}
