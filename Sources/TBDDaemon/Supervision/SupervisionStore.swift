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

    /// Per-project counters the coverage summary reports.
    ///
    /// **Nothing increments these in this slice, so zero is accurate rather
    /// than fabricated** — and they are counters rather than literals so that
    /// the change which ships briefing delivery has somewhere to feed. Feeding
    /// them is part of that change, not an optional follow-up: the moment
    /// briefings exist and these stay at zero, every closing line starts lying.
    /// In memory rather than persisted because both facts become queries over
    /// the ledger's own `delivery` lines once those exist.
    private var sweepContacts: [String: Int] = [:]
    private var briefingsDelivered: [String: Int] = [:]
    private var lastSweepContact: [String: SupervisionInstant] = [:]

    public init(
        files: SupervisionFileStore,
        ledger: SupervisionLedgerWriter,
        fleet: any SupervisionFleetReading,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.files = files
        self.ledger = ledger
        self.fleet = fleet
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
        // Set after the await, so a second caller that arrives mid-suspension
        // repeats the (idempotent, side-effect-free) read rather than
        // proceeding on half-initialized state.
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

    // MARK: - Status

    /// The `supervise.status` readout.
    public func status(brake: SupervisionBrakeState) async throws -> SupervisionStatus {
        try await ensureLoaded()
        let repos = try await fleet.repos()
        let file = try freshFile()
        let projects = try SupervisionTopology.resolve(file: file, repos: repos)
        let effectivelySupervising = brake == .released && projects.contains { $0.mark }

        var warnings: [SupervisionWarning] = []
        if brake == .released && !effectivelySupervising {
            warnings.append(SupervisionWarning(
                code: .noProjectsOn,
                message: "the brake is released but no project is on — nothing is being supervised."))
        }
        let unusable = SupervisionTopology.projectsWithoutUsableDirectory(in: projects)
        if !unusable.isEmpty {
            warnings.append(SupervisionWarning(
                code: .unusableProjectName, message: Self.unusableNameSentence(unusable)))
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

    /// The heartbeat's view of the same facts (design §14).
    public func statusFileSnapshot(brake: SupervisionBrakeState) async throws
        -> SupervisionStatusFile {
        try await ensureLoaded()
        let repos = try await fleet.repos()
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
        try await ensureLoaded()
        let repos = try await fleet.repos()

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
            let roster = on ? try await rosterSnapshot(for: resolved) : []
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
        try await ensureLoaded()
        let repos = try await fleet.repos()

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

    // MARK: - The brake

    /// Record a fleet brake change, after the config column already took it.
    ///
    /// The line carries no project and no mode, and cannot be given either: the
    /// brake is one bit over the whole fleet, so naming a project on its line
    /// would be a lie. `SupervisionLedgerLine.brakeEngaged` / `.brakeReleased`
    /// take no project, which is what holds this by construction.
    ///
    /// `changed` is the caller's comparison of the resolved brake before and
    /// after: the column is tri-state, so writing `false` over an unset column
    /// is a real gesture on the column but no change to what the brake means,
    /// and a gesture that changes nothing writes no line.
    public func recordBrakeChange(engaged: Bool, changed: Bool) async {
        guard changed else { return }
        let at = now()
        await ledger.append(engaged
            ? SupervisionLedgerLine.brakeEngaged(at: at)
            : SupervisionLedgerLine.brakeReleased(at: at))
    }

    // MARK: - Projects

    public func projectList() async throws -> SuperviseProjectListResult {
        try await ensureLoaded()
        let repos = try await fleet.repos()
        let file = try freshFile()
        return try topologyResult(file: file, repos: repos)
    }

    public func projectCreate(
        name: String, repos identifiers: [String], policy: SupervisionPolicyRequest
    ) async throws -> SuperviseProjectListResult {
        try await ensureLoaded()
        let repos = try await fleet.repos()

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
        // Resolve before saving, not after: it is the check that catches a name
        // colliding with a repo's own project, and running it first is what
        // makes a refused create byte-identical to no create at all.
        let result = try topologyResult(file: updated, repos: repos)
        try persist(updated)
        return result
    }

    /// Delete a declaration, returning its repos to being their own projects.
    ///
    /// The vanished project's mark, mode entry and supervisor binding go with
    /// it — a mark outliving its project would silently turn a later project of
    /// the same name on without an operator gesture. Where the mark stood, the
    /// project's coverage genuinely ends here, so its span is closed on the
    /// record like any other `off`.
    public func projectDelete(name: String) async throws -> SuperviseProjectListResult {
        try await ensureLoaded()
        let repos = try await fleet.repos()

        // Read-modify-write, no suspension inside.
        let file = try freshFile()
        guard file.projects[name] != nil else {
            throw SupervisionStoreError.unknownProject(name)
        }
        let wasMarked = file.isMarked(name)
        let mode = file.activeMode(for: name)

        var updated = file
        updated.projects.removeValue(forKey: name)
        updated.supervised.removeAll { $0 == name }
        updated.modes.removeValue(forKey: name)
        updated.supervisors.removeValue(forKey: name)

        let result = try topologyResult(file: updated, repos: repos)
        try persist(updated)

        if wasMarked { await appendProjectOff(project: name, mode: mode, at: now()) }
        return result
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
        try await ensureLoaded()
        let repos = try await fleet.repos()

        // Read-modify-write, no suspension inside.
        let file = try freshFile()
        let repoID = try resolveRepo(identifier, in: repos)
        let updated = try SupervisionTopology.move(
            repo: repoID, to: target, in: file, repos: repos)
        let result = try topologyResult(file: updated, repos: repos)
        guard updated != file else { return result }

        // A move that empties a declaration deletes it, and takes its mark with
        // it. Where that mark stood, the span it opened ends here.
        let vanished = Set(file.supervised.filter { name in
            file.projects[name] != nil && updated.projects[name] == nil
        })
        let modes = Dictionary(
            vanished.map { ($0, file.activeMode(for: $0)) }, uniquingKeysWith: { first, _ in first })

        try persist(updated)

        for name in vanished.sorted() {
            await appendProjectOff(
                project: name, mode: modes[name] ?? SupervisionModeEntry.defaultMode, at: now())
        }
        return result
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
    /// never guessed — and that refusal is not a new rule, only an earlier one:
    /// `SupervisionTopology.resolve` already rejects the whole topology for
    /// exactly that ambiguity, because both repos' singleton projects would
    /// carry the same name.
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

    // MARK: - Counters the coverage summary reports

    /// Record that a sweep program made contact with a project.
    ///
    /// Unused in this slice — nothing submits a briefing yet, so every counter
    /// reads zero and zero is accurate. **The change that ships delivery must
    /// call this**, or the closing line's `sweepContacts` and the status
    /// readout's `lastSweepContactAt` start lying the moment briefings exist.
    public func noteSweepContact(project: String, at date: Date) {
        sweepContacts[project, default: 0] += 1
        lastSweepContact[project] = SupervisionInstant(date)
    }

    /// Record that a briefing was delivered to a project's supervisor. Unused
    /// in this slice, for the same reason and with the same obligation as
    /// `noteSweepContact`.
    public func noteBriefingDelivered(project: String) {
        briefingsDelivered[project, default: 0] += 1
    }
}
