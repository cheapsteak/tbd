import Foundation
import os
import TBDShared

private let deskLogger = Logger(subsystem: "com.tbd.daemon", category: "supervision.desk")

// MARK: - What a desk needs to exist

/// Everything `ensureDesk` needs, read once by the one component that owns
/// `supervision.json`.
///
/// The desk manager deliberately resolves no topology of its own:
/// `SupervisionStore` is the single reader of the operator's file, and a second
/// resolution would be a second answer to a question with one.
public struct SupervisionDeskInputs: Sendable, Equatable {
    public let project: String
    /// The project's active mode at the moment of the gesture — carried onto
    /// the lifecycle line, never interpreted.
    public let mode: String
    /// The project's resolved playbook: installed verbatim as the desk's
    /// standing conduct layer, and hashed onto the desk's record.
    public let playbook: SupervisionPlaybook
    /// The operator's appointed supervisor, when one is bound. Its presence
    /// stands the hosted default down entirely (design §9).
    public let appointed: SupervisionSupervisorBinding?

    public init(project: String, mode: String, playbook: SupervisionPlaybook,
                appointed: SupervisionSupervisorBinding?) {
        self.project = project
        self.mode = mode
        self.playbook = playbook
        self.appointed = appointed
    }
}

/// What one `ensureDesk` did. Every case is a fact about the world afterwards,
/// not a status code: callers log it, and the ledger line was already written
/// by the time it is returned.
public enum SupervisionDeskOutcome: Sendable, Equatable {
    /// An appointed binding stands and its session is live. Nothing was
    /// spawned — a mark is coverage, a binding is selection, and `on` never
    /// touches the second.
    case appointed(terminal: UUID)
    /// An appointed binding stands and names a session that is gone. Reported
    /// loudly and left alone: the operator chose that supervisor, and TBD does
    /// not unchoose it (design §9). The resolution is the operator's relieve
    /// gesture, which is not in this slice.
    case danglingBinding(terminal: String, detail: String)
    /// A recorded desk is live; it resumes as it stands and nothing was
    /// spawned. The quiet path, and the common one.
    case resumed(SupervisionDeskEntry)
    /// A project that had no desk got one.
    case spawned(SupervisionDeskEntry)
    /// A recorded desk had died and was replaced, with a lifecycle line linking
    /// successor to predecessor.
    case replaced(successor: SupervisionDeskEntry, predecessor: SupervisionDeskEntry)
}

/// Why a desk could not be ensured. A spawn failure is an anomaly, never a
/// refusal of the mark: `on <project>` sets the mark first and the caller
/// reports this without failing the gesture (design §9, `docs/cli-supervise.md`).
public enum SupervisionDeskError: Error, CustomStringConvertible, LocalizedError {
    case couldNotAllocateDirectory(project: String)
    case spawnFailed(project: String, detail: String)
    case recordFailed(project: String, detail: String)

    public var description: String {
        switch self {
        case .couldNotAllocateDirectory(let project):
            return "Could not allocate a scratch directory for \"\(project)\"'s hosted desk."
        case .spawnFailed(let project, let detail):
            return "The hosted desk for \"\(project)\" could not be spawned: \(detail)"
        case .recordFailed(let project, let detail):
            return "The hosted desk for \"\(project)\" was spawned but could not be recorded: "
                + "\(detail)"
        }
    }

    public var errorDescription: String? { description }
}

/// How a desk's session comes into being: `WorktreeLifecycle`'s
/// primary-terminal spawn in production, and an injection seam everywhere else.
///
/// It exists as a seam because the two failing exits the spawn path cleans up
/// after are not both reachable through the real one. A thrown spawn is — tmux
/// refusing the `new-window` produces it — but `spawnPrimaryTerminals` always
/// returns at least the primary terminal, so "the spawn created no terminal" is
/// reachable from no input at all. That branch guards against a future
/// refactor of the spawn path, and this seam is how it is held to its
/// behaviour.
public typealias SupervisionDeskSpawn = @Sendable (
    _ worktree: Worktree, _ inputs: SupervisionDeskInputs
) async throws -> [(id: UUID, label: String)]

// MARK: - The manager

/// Ensures each supervised project has a live supervisor, per design §9's
/// hosted-desk lifecycle.
///
/// **The whole of the policy, in the order it is applied.**
///
/// 1. *An appointed binding wins, always.* Where one stands, no hosted desk is
///    spawned and none is silently substituted. A binding naming a session that
///    is gone is a **dangling binding**: reported loudly, never taken over.
/// 2. *A live recorded desk resumes as it stands.* Liveness is the terminal row
///    plus its tmux window, read from TBD's own records and tmux's metadata —
///    never from anything rendered on a screen.
/// 3. *A recorded desk that died is replaced*, and the lifecycle line links
///    successor to predecessor so a project's desks read as a chain.
/// 4. *A project with no desk gets one.*
///
/// **A spawn delivers nothing.** No message, no nudge, no opening prompt: the
/// opening material rides the first briefing, so a quiet project's desk idles at
/// zero token cost. That is a property this type is tested for, not a detail.
///
/// **Who reclaims an orphan** (repo `CLAUDE.md`), in two halves, because a desk
/// is a scratch worktree plus a live process and this type creates both before
/// it can record either.
///
/// - *A recorded desk that died* is `SupervisionDeskCollector`'s, run as a leg
///   of `OrphanGC`: it prunes the `desks.json` entry and hands the worktree to
///   the archive path the sweep already runs, and never touches a live desk.
/// - *An ensure that ended with no entry written* — the spawn threw, produced
///   no terminal, or ran and could not be recorded — is invisible to that
///   collector, which walks `desks.json` and finds nothing. So this type
///   archives the scratch row itself on every such exit (`abandon`), which puts
///   it under `OrphanGC`'s deletion-queue leg instead.
///
/// One residual is deliberate rather than covered: a predecessor whose liveness
/// recheck refuses to call it gone is left `.active` and reclaimed by nobody,
/// because handing back a space whose session is alive costs that session its
/// terminal on the next reconcile pass. `abandonPredecessor` states the whole
/// tradeoff, and the operator is told rather than left to find it.
public actor SupervisionDeskManager {
    private let db: TBDDatabase
    private let spawnSession: SupervisionDeskSpawn
    private let tmux: TmuxManager
    private let desks: SupervisionDesksStore
    private let ledger: SupervisionLedgerWriter
    private let actuationLog: ActuationLog
    private let subscriptions: StateSubscriptionManager?
    /// A persisted, compared timestamp — the date seam, never a `Clock`.
    /// Nothing here sleeps, debounces, polls, or times out.
    private let now: @Sendable () -> Date

    /// Serializes the whole read-decide-spawn-record sequence. Actor isolation
    /// alone is not enough: `ensureDesk` awaits the database and the spawn, and
    /// an actor releases itself across every suspension, so two concurrent
    /// ensures for one project would both read "no desk" and both spawn one.
    private var gateBusy = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    private func gateAcquire() async {
        if gateBusy {
            await withCheckedContinuation { gateWaiters.append($0) }
            // Resumed by gateRelease(); `gateBusy` stays true.
        } else {
            gateBusy = true
        }
    }

    private func gateRelease() {
        if gateWaiters.isEmpty {
            gateBusy = false
        } else {
            gateWaiters.removeFirst().resume()
        }
    }

    public init(
        db: TBDDatabase,
        lifecycle: WorktreeLifecycle,
        tmux: TmuxManager,
        desks: SupervisionDesksStore,
        ledger: SupervisionLedgerWriter,
        actuationLog: ActuationLog,
        subscriptions: StateSubscriptionManager? = nil,
        spawnSession: SupervisionDeskSpawn? = nil,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.db = db
        self.spawnSession = spawnSession ?? Self.lifecycleSpawn(lifecycle)
        self.tmux = tmux
        self.desks = desks
        self.ledger = ledger
        self.actuationLog = actuationLog
        self.subscriptions = subscriptions
        self.now = now
    }

    /// The production spawn: one agent session in the desk's scratch space.
    private static func lifecycleSpawn(
        _ lifecycle: WorktreeLifecycle
    ) -> SupervisionDeskSpawn {
        { worktree, inputs in
            try await lifecycle.spawnPrimaryTerminals(
                worktree: worktree,
                repo: nil,
                skipClaude: false,
                // **Nothing is delivered at spawn.** No opening prompt, no
                // nudge, no briefing: the opening material rides the first
                // briefing, so a quiet project's desk costs nothing to have.
                initialPrompt: nil,
                preSessionTerminalID: nil,
                // Forced rather than read from the operator's primary-agent
                // preference: supervisor capability is a per-adapter
                // qualification (design §9), and the standing conduct layer
                // below rides `--append-system-prompt`, which only the Claude
                // spawn path carries. A Codex desk would launch with no conduct
                // at all and nothing would say so — `spawn` logs the
                // substitution so a Codex-preferring fleet is told rather than
                // left to read a tab label.
                primaryAgentPreference: .claude,
                supervisionProject: inputs.project,
                supervisionPlaybook: inputs.playbook.text)
        }
    }

    // MARK: - Ensure

    /// Ensure a live supervisor for one project, spawning a hosted desk only
    /// when that is what the four rules above call for.
    @discardableResult
    public func ensureDesk(project inputs: SupervisionDeskInputs) async throws
        -> SupervisionDeskOutcome {
        await gateAcquire()
        defer { gateRelease() }

        if let binding = inputs.appointed {
            return await evaluateAppointment(binding, project: inputs.project)
        }

        let file = try desks.load()
        if let entry = file.desk(for: inputs.project) {
            if await isLive(entry) {
                deskLogger.debug(
                    """
                    Hosted desk for "\(inputs.project, privacy: .public)" is live; resuming as it \
                    stands.
                    """)
                return .resumed(entry)
            }
            // A desk that died while stood down — a death nothing was watching
            // for, because a stood-down project's sweep is not running — is
            // detected exactly here and nowhere else.
            let successor = try await spawn(inputs: inputs, predecessor: entry)
            return .replaced(successor: successor, predecessor: entry)
        }

        let entry = try await spawn(inputs: inputs, predecessor: nil)
        return .spawned(entry)
    }

    // MARK: - Appointment

    /// An appointed binding stands. Verify the session is really there, and say
    /// so loudly when it is not — the hosted default does **not** step in.
    private func evaluateAppointment(
        _ binding: SupervisionSupervisorBinding, project: String
    ) async -> SupervisionDeskOutcome {
        guard let terminalID = binding.terminalID else {
            return dangling(
                binding.terminal, project: project, worktree: nil,
                detail: "the binding does not name a terminal id")
        }
        let terminal: Terminal?
        do {
            terminal = try await db.terminals.get(id: terminalID)
        } catch {
            // A read that never answered says nothing about the session, so it
            // is not evidence of a dangling binding. Report it and change
            // nothing: the keep-favoring direction, matching the sweeps.
            deskLogger.warning(
                """
                Could not check "\(project, privacy: .public)"'s appointed supervisor \
                \(terminalID.uuidString, privacy: .public): \
                \(String(describing: error), privacy: .public). Nothing was spawned.
                """)
            return .appointed(terminal: terminalID)
        }
        guard let terminal else {
            return dangling(
                binding.terminal, project: project, worktree: nil,
                detail: "that terminal no longer exists")
        }
        guard terminal.hibernatedAt == nil, terminal.suspendedAt == nil else {
            return dangling(
                binding.terminal, project: project, worktree: terminal.worktreeID,
                detail: "that session is parked, so nothing can be delivered to it")
        }
        guard let worktree = try? await db.worktrees.getLocal(id: terminal.worktreeID) else {
            return dangling(
                binding.terminal, project: project, worktree: nil,
                detail: "TBD no longer has the worktree that session lived in")
        }
        guard await tmux.windowExists(
            server: worktree.tmuxServer, windowID: terminal.tmuxWindowID) else {
            return dangling(
                binding.terminal, project: project, worktree: terminal.worktreeID,
                detail: "that session's window is gone")
        }
        deskLogger.debug(
            """
            "\(project, privacy: .public)" has an appointed supervisor \
            (\(terminalID.uuidString, privacy: .public)); no hosted desk was spawned.
            """)
        return .appointed(terminal: terminalID)
    }

    /// The loud half of a dangling binding: an error in the log and an operator
    /// notification. **Never a silent takeover** — the hosted default does not
    /// step into a role the operator assigned to someone else (design §9).
    ///
    /// The matching `anomaly` ledger line is not written here because this build
    /// has no anomaly payload to write; it arrives with the anomaly kind.
    /// Nothing about the reporting is silent in the meantime.
    /// `worktree` is the bound session's, when TBD still has one. A TBD
    /// notification is worktree-scoped, so a binding whose terminal row is gone
    /// entirely raises none — the `.error` log line above is written either way,
    /// and inventing a worktree to hang the notification on would be a fact TBD
    /// does not have.
    private func dangling(
        _ terminal: String, project: String, worktree: UUID?, detail: String
    ) -> SupervisionDeskOutcome {
        let message = """
            Supervision: "\(project)" is bound to supervisor \(terminal), but \(detail). \
            No hosted desk was spawned in its place — relieve the binding to fall back to the \
            hosted default.
            """
        deskLogger.error("\(message, privacy: .public)")
        if let worktree { notify(message, worktree: worktree) }
        return .danglingBinding(terminal: terminal, detail: detail)
    }

    // MARK: - Liveness

    /// What one read of a recorded desk found.
    ///
    /// The three cases exist because two different decisions act on this answer
    /// in **opposite** directions, and each needs its own failure direction.
    /// Deciding whether to *spawn* a replacement fails toward "not live" — a
    /// spare desk costs tokens, a project with no supervisor costs coverage.
    /// Deciding whether to *archive* the predecessor fails toward keeping — an
    /// archived worktree loses its tmux window to the next reconcile pass, so
    /// getting that one wrong destroys a live agent session. Collapsing "no
    /// evidence" into "gone", which a `Bool` forces, is precisely how the
    /// second decision goes wrong; `SupervisionDeskCollector.WorktreeLookup`
    /// keeps the same two apart for the same reason.
    private enum DeskLiveness: Equatable {
        /// The session is there and can be delivered to.
        case live
        /// Affirmative evidence the desk is not there: a terminal row that is
        /// gone, a worktree row that is gone or already archived, or a tmux
        /// window that is not there.
        case gone
        /// Nothing was established. A read that did not answer, or a session
        /// that is parked — asleep but wakeable, so a record of a session that
        /// is coming back rather than evidence of one that is not.
        case undetermined
    }

    /// Read a recorded desk: a terminal row that is not parked, its worktree
    /// still active, and a tmux window that still exists.
    ///
    /// **Read from TBD's records and tmux's own metadata**, never from anything
    /// rendered in the pane. A screen is a display surface, not an API (root
    /// `CLAUDE.md`).
    ///
    /// One limitation is worth stating, because it bounds what `.gone` proves:
    /// `TmuxManager.windowExists` answers `false` both for a window that is not
    /// there and for a tmux it could not reach, so an unreachable tmux reads as
    /// `.gone`. That is the same evidence this type has always decided on, and
    /// narrowing it needs a distinguishable answer from `TmuxManager` itself.
    private func liveness(_ entry: SupervisionDeskEntry) async -> DeskLiveness {
        let terminal: Terminal?
        do {
            terminal = try await db.terminals.get(id: entry.terminal)
        } catch {
            return .undetermined
        }
        guard let terminal else { return .gone }
        guard terminal.hibernatedAt == nil, terminal.suspendedAt == nil else {
            return .undetermined
        }
        let worktree: LocalWorktree?
        do {
            worktree = try await db.worktrees.getLocal(id: entry.worktree)
        } catch {
            return .undetermined
        }
        guard let worktree, worktree.status == .active else { return .gone }
        let windowExists = await tmux.windowExists(
            server: worktree.tmuxServer, windowID: terminal.tmuxWindowID)
        return windowExists ? .live : .gone
    }

    /// Whether a recorded desk is really there.
    ///
    /// Every failure direction is toward *not live*, which costs a replacement
    /// desk. The opposite direction costs a project with no supervisor and
    /// nothing to say so.
    private func isLive(_ entry: SupervisionDeskEntry) async -> Bool {
        let state = await liveness(entry)
        return state == .live
    }

    // MARK: - Spawn

    /// Create the scratch space and the desk session in it, record the desk,
    /// and append the lifecycle line.
    ///
    /// The order is deliberate and matches the store's: the external resource is
    /// created first because it cannot be created transactionally, then the
    /// record, then the line.
    ///
    /// **Every failing exit after the scratch space exists hands it back** —
    /// the spawn that threw, the spawn that produced no terminal, and the desk
    /// that could not be written to the record.
    /// `SupervisionDeskCollector` walks `desks.json`, so a failure
    /// before the entry is written is invisible to it — and to every other leg
    /// of the sweep, because a scratch row has no repo and the archived legs
    /// only touch rows already archived. `abandon` archives the row, which is
    /// exactly the shape `OrphanGC`'s deletion-queue leg reclaims. A crash
    /// (rather than a thrown error) in the same window still leaves an
    /// unreferenced scratch space, and that one nothing reclaims; the doctrine's
    /// answer is that a crash there is not silent — the row is `.active` and
    /// visible in the sidebar.
    private func spawn(
        inputs: SupervisionDeskInputs, predecessor: SupervisionDeskEntry?
    ) async throws -> SupervisionDeskEntry {
        let worktree = try await createScratchSpace(project: inputs.project)

        // Say so when the desk's forced adapter is not the operator's pick.
        // A Codex-preferring fleet would otherwise discover its supervisors are
        // Claude sessions only by reading a tab label.
        if let preference = try? await db.config.get().primaryAgentPreference,
           preference != .claude {
            deskLogger.notice(
                """
                The hosted desk for "\(inputs.project, privacy: .public)" launches Claude, not \
                \(preference.rawValue, privacy: .public): a supervisor's standing conduct rides \
                --append-system-prompt, which only the Claude spawn path carries. The fleet's \
                primary-agent preference is unchanged and still applies to every other session.
                """)
        }

        // The rail spawns an agent session with nobody having asked for a
        // session by name, so it writes its own row: one naming the scratch
        // worktree and no terminal, the shape `worktree.revive` uses, because
        // the terminal is minted inside `spawnPrimaryTerminals`.
        var row = ActuationRow(
            actor: .daemon(rail: ActuationRail.supervisionDesk), kind: .spawn)
        row.target = ActuationTarget(worktree: worktree.id.uuidString)
        let actuationID = try await actuationLog.appendRequest(row)

        let created: [(id: UUID, label: String)]
        do {
            created = try await spawnSession(worktree, inputs)
        } catch {
            await actuationLog.appendOutcome(
                confirms: actuationID, result: .transportFailed, error: "\(error)")
            await abandon(worktree, project: inputs.project, because: "its session never started")
            throw SupervisionDeskError.spawnFailed(
                project: inputs.project, detail: String(describing: error))
        }
        await actuationLog.appendOutcome(confirms: actuationID, result: .dispatched)

        guard let primary = created.first else {
            await abandon(
                worktree, project: inputs.project, because: "the spawn created no terminal")
            throw SupervisionDeskError.spawnFailed(
                project: inputs.project, detail: "the spawn created no terminal")
        }

        let at = now()
        let entry = SupervisionDeskEntry(
            terminal: primary.id, worktree: worktree.id,
            spawnedAt: SupervisionInstant(at), conductHash: inputs.playbook.conductHash)
        do {
            // **Re-read, never write back the copy read before the spawn.**
            // Spawning a session takes seconds, and `SupervisionDeskCollector`
            // rewrites this same file per reap while the hourly sweep runs. A
            // save built on the pre-spawn copy would resurrect an entry the
            // sweep had just dropped — and a resurrected entry whose worktree
            // the sweep already archived is kept by every later sweep
            // (`desk-already-archived`), so it would never be reclaimed again.
            // `SupervisionStore` guards the identical shape by re-reading
            // before it commits.
            let latest = try desks.load()
            try desks.save(latest.recording(entry, for: inputs.project))
        } catch {
            // A desk that ran and was never written down is the worst of the
            // three failing exits, not the mildest: the session is live, so the
            // next `on` reads no entry and spawns a second one beside it, and
            // the pile grows one agent per gesture. Nothing else reclaims it —
            // `SupervisionDeskCollector` enumerates the record this write did
            // not reach, and the sweep's other legs walk repo-backed or
            // already-archived rows. So this exit hands the space back too, and
            // the archived row is what carries the session's own teardown to
            // `WorktreeLifecycle+Reconcile`.
            await abandon(
                worktree, project: inputs.project,
                because: "its desk could not be written to the record")
            throw SupervisionDeskError.recordFailed(
                project: inputs.project, detail: String(describing: error))
        }

        subscriptions?.broadcast(delta: .worktreeCreated(WorktreeDelta(
            worktreeID: worktree.id, repoID: nil, name: worktree.name,
            path: worktree.localPath, status: worktree.status)))
        for created in created {
            // The sidebar shows the desk's scratch space the moment the row
            // broadcast above lands; without this it would sit there tabless
            // until the next full state refresh. Same pair `scratch.create`
            // sends, for the same reason.
            subscriptions?.broadcast(delta: .terminalCreated(TerminalDelta(
                terminalID: created.id, worktreeID: worktree.id, label: created.label)))
        }

        let ref = SupervisionDeskRef(terminal: entry.terminal, worktree: entry.worktree)
        if let predecessor {
            // The desk this one succeeds keeps a scratch space that the record
            // no longer names, and that nothing else reclaims: the collector
            // enumerates `desks.json`, where this project's key now holds the
            // successor. Handing it back here is what keeps a project's
            // replacements from piling up one dead space per replacement.
            await abandonPredecessor(predecessor, project: inputs.project)
            await ledger.append(SupervisionLedgerLine.deskReplaced(
                project: inputs.project, mode: inputs.mode, desk: ref,
                predecessor: SupervisionDeskRef(
                    terminal: predecessor.terminal, worktree: predecessor.worktree),
                conductHash: entry.conductHash, at: at))
            deskLogger.notice(
                """
                Replaced the hosted desk for "\(inputs.project, privacy: .public)": \
                \(predecessor.terminal.uuidString, privacy: .public) had died; its successor is \
                \(entry.terminal.uuidString, privacy: .public).
                """)
        } else {
            await ledger.append(SupervisionLedgerLine.deskSpawned(
                project: inputs.project, mode: inputs.mode, desk: ref,
                conductHash: entry.conductHash, at: at))
            deskLogger.notice(
                """
                Spawned a hosted desk for "\(inputs.project, privacy: .public)": terminal \
                \(entry.terminal.uuidString, privacy: .public) in \
                \(worktree.localPath, privacy: .public).
                """)
        }
        return entry
    }

    /// A fresh scratch worktree for one desk: a `repoID == nil` row under
    /// `TBDConstants.scratchDir`, exactly like every other scratch space.
    ///
    /// The directory name is derived from the project only as a courtesy to a
    /// human reading `ls`. **Nothing ever looks a desk up by it** — the record
    /// is keyed by id, so a rename is free.
    private func createScratchSpace(project: String) async throws -> Worktree {
        let fm = FileManager.default
        let scratchDir = TBDConstants.scratchDir
        try fm.createDirectory(at: scratchDir, withIntermediateDirectories: true)

        // **Creating the directory IS the allocation.** A check-then-create
        // would leave a window in which two ensures pick the same free name and
        // the second one's `createDirectory` throws; `withIntermediateDirectories:
        // false` fails with `fileWriteFileExists` on an already-taken name, so
        // the loser simply tries the next candidate. The database check stays,
        // because a name can be taken by a row whose directory is gone.
        var path: URL?
        var name = ""
        for attempt in 0..<50 {
            let candidate = attempt == 0
                ? "supervision-desk"
                : "supervision-desk-\(UUID().uuidString.prefix(8))"
            let url = scratchDir.appendingPathComponent(candidate)
            if try await db.worktrees.findByPath(path: url.path) != nil { continue }
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
            } catch CocoaError.fileWriteFileExists {
                continue
            }
            name = candidate
            path = url
            break
        }
        guard let deskPath = path else {
            throw SupervisionDeskError.couldNotAllocateDirectory(project: project)
        }

        do {
            return try await db.worktrees.createScratch(
                name: name,
                // A display string for the sidebar and nothing else. The record
                // is keyed by id precisely so this can be renamed at will.
                displayName: "Supervisor · \(project)",
                path: deskPath.path,
                tmuxServer: TmuxManager.serverName(forRepoPath: scratchDir.path))
        } catch {
            // Best-effort, as creation-time rollback always is here. The
            // standing guarantee is the collector, not this line.
            try? fm.removeItem(at: deskPath)
            throw error
        }
    }

    /// Hand a scratch space back when the desk that was to live in it never
    /// started.
    ///
    /// Archiving the row is the whole act, and it is deliberately not a
    /// delete: an archived scratch row is exactly the shape `OrphanGC`'s
    /// deletion-queue leg already reclaims, so this moves the directory from
    /// "covered by no reconciler" to "covered by one that has run hourly for
    /// months". Nothing here removes the directory itself — that sweep does,
    /// after its own grace and liveness gates.
    ///
    /// Best-effort, as creation-time cleanup always is (repo `CLAUDE.md`): if
    /// the archive does not land, the row stays `.active` and an operator sees
    /// a stray scratch space, which is the visible failure rather than the
    /// silent one.
    private func abandon(_ worktree: Worktree, project: String, because reason: String) async {
        do {
            try await db.worktrees.archive(id: worktree.id)
            deskLogger.notice(
                """
                Handed back the scratch space for "\(project, privacy: .public)"'s hosted desk at \
                \(worktree.localPath, privacy: .public) — \(reason, privacy: .public). It is \
                archived, and the orphan sweep reclaims it from there.
                """)
        } catch {
            deskLogger.error(
                """
                The hosted desk for "\(project, privacy: .public)" could not be spawned \
                (\(reason, privacy: .public)) and its scratch space at \
                \(worktree.localPath, privacy: .public) could not be archived either: \
                \(String(describing: error), privacy: .public). It is left for a human.
                """)
        }
    }

    /// Hand back the scratch space of the desk a replacement just succeeded.
    ///
    /// Recording the successor overwrites the project's key, so from that
    /// moment the predecessor's space is referenced by nothing: the collector
    /// enumerates `desks.json` and reads the successor there, the
    /// agent-worktree leg walks only repo-backed worktrees, and the archived
    /// legs only touch rows already archived. Without this it would leak one
    /// scratch space per replacement, forever.
    ///
    /// Done only **after** the successor is recorded, so a record write that
    /// failed leaves the predecessor exactly as it was rather than letting go
    /// of the one desk the project still has. A row that is already archived,
    /// or gone, is left alone — there is nothing to hand back.
    ///
    /// **The predecessor is read again here, and only affirmative evidence that
    /// it is gone archives it.** The judgement that started this replacement was
    /// made before a whole spawn — a worktree created, a session started, a
    /// record written — and it was made by `isLive`, which answers "not live" to
    /// a read that merely failed. Two paths therefore reach a session that is
    /// alive: a transient read that glitched the first judgement, and a desk
    /// that was stood down at the decision and woken before this line (a
    /// stood-down desk stays wakeable by design). Archiving either is not
    /// cosmetic: `WorktreeLifecycle+Reconcile` computes its tracked tmux windows
    /// from non-archived rows, so an archived-but-live desk loses its window on
    /// the next reconcile pass — a live agent session destroyed through ordinary
    /// control flow. This recheck is the same shape and the same direction as
    /// `SupervisionDeskCollector`'s fresh-liveness pass immediately before a
    /// reap, and it is why every reap direction in this subsystem fails toward
    /// keeping.
    ///
    /// **The tradeoff when the recheck declines is real, and is not papered
    /// over.** The successor already holds the project's key in `desks.json`, so
    /// the predecessor is enumerated by nothing: `SupervisionDeskCollector`
    /// walks that record and reads the successor there, the agent-worktree leg
    /// walks only repo-backed rows, and the archived legs only touch rows
    /// already archived. A predecessor kept here is therefore a scratch space no
    /// reconciler will reclaim later. It is left `.active`, logged, and
    /// announced to the operator on its own worktree, which makes it the same
    /// shape as the crash-window residual the spawn path already carries: a
    /// visible row an operator can see and close. That is strictly better than
    /// the alternative, which is killing a live agent session.
    private func abandonPredecessor(
        _ predecessor: SupervisionDeskEntry, project: String
    ) async {
        guard let row = ((try? await db.worktrees.get(id: predecessor.worktree)) ?? nil),
              row.status == .active else { return }
        let state = await liveness(predecessor)
        guard state == .gone else {
            let detail = state == .live
                ? "its session is still live"
                : "its session could not be confidently read as gone"
            let message = """
                Supervision: "\(project)" replaced its hosted desk, and the desk it replaced kept \
                its scratch space — \(detail). That space at \(row.localPath) is left active, and \
                no sweep will reclaim it, because the project's record now names the replacement. \
                Close it by hand once you have confirmed nothing is running in it. Handing it back \
                would have cost a live session its terminal on the next reconcile pass.
                """
            deskLogger.error("\(message, privacy: .public)")
            await announce(message, worktree: row.id)
            return
        }
        await abandon(row, project: project, because: "the desk it held was replaced")
    }

    /// Raise an operator notification from a synchronous caller. Detached
    /// because the callers that need it return a decision rather than awaiting
    /// one, and a notification is a report, never a gate.
    private func notify(_ message: String, worktree: UUID) {
        let db = self.db
        let subscriptions = self.subscriptions
        Task {
            await Self.announce(message, worktree: worktree, db: db, subscriptions: subscriptions)
        }
    }

    /// The same report, awaited. An async caller uses this so the notification
    /// has landed by the time the call returns — one less escaping task, and the
    /// fact is observable at the point it is made.
    private func announce(_ message: String, worktree: UUID) async {
        await Self.announce(
            message, worktree: worktree, db: db, subscriptions: subscriptions)
    }

    private static func announce(
        _ message: String, worktree: UUID, db: TBDDatabase,
        subscriptions: StateSubscriptionManager?
    ) async {
        guard let notification = try? await db.notifications.create(
            worktreeID: worktree, type: .error, message: message) else { return }
        subscriptions?.broadcast(delta: .notificationReceived(NotificationDelta(
            notificationID: notification.id,
            worktreeID: notification.worktreeID,
            type: notification.type,
            message: notification.message,
            terminalID: notification.terminalID,
            activate: false)))
    }
}
