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
/// **Who reclaims an orphan** (repo `CLAUDE.md`): `SupervisionDeskCollector`,
/// run as a leg of `OrphanGC`. A desk is a scratch worktree plus a live process,
/// and this type creates both before it can record either — so a crash between
/// the spawn and the `desks.json` write leaves a scratch space nobody owns. The
/// collector prunes the record and hands the worktree to the archive path the
/// sweep already runs, and never touches a live desk.
public actor SupervisionDeskManager {
    private let db: TBDDatabase
    private let lifecycle: WorktreeLifecycle
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
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.db = db
        self.lifecycle = lifecycle
        self.tmux = tmux
        self.desks = desks
        self.ledger = ledger
        self.actuationLog = actuationLog
        self.subscriptions = subscriptions
        self.now = now
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
            let successor = try await spawn(inputs: inputs, file: file, predecessor: entry)
            return .replaced(successor: successor, predecessor: entry)
        }

        let entry = try await spawn(inputs: inputs, file: file, predecessor: nil)
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

    /// Whether a recorded desk is really there: a terminal row that is not
    /// parked, its worktree still active, and a tmux window that still exists.
    ///
    /// **Read from TBD's records and tmux's own metadata**, never from anything
    /// rendered in the pane. A screen is a display surface, not an API (root
    /// `CLAUDE.md`).
    ///
    /// Every failure direction is toward *not live*, which costs a replacement
    /// desk. The opposite direction costs a project with no supervisor and
    /// nothing to say so.
    private func isLive(_ entry: SupervisionDeskEntry) async -> Bool {
        guard let terminal = try? await db.terminals.get(id: entry.terminal),
              terminal.hibernatedAt == nil, terminal.suspendedAt == nil,
              let worktree = try? await db.worktrees.getLocal(id: entry.worktree),
              worktree.status == .active else {
            return false
        }
        return await tmux.windowExists(
            server: worktree.tmuxServer, windowID: terminal.tmuxWindowID)
    }

    // MARK: - Spawn

    /// Create the scratch space and the desk session in it, record the desk,
    /// and append the lifecycle line.
    ///
    /// The order is deliberate and matches the store's: the external resource is
    /// created first because it cannot be created transactionally, then the
    /// record, then the line. A crash in the middle leaves a scratch space with
    /// no desk entry — which is precisely what `SupervisionDeskCollector`
    /// reclaims.
    private func spawn(
        inputs: SupervisionDeskInputs, file: SupervisionDesksFile,
        predecessor: SupervisionDeskEntry?
    ) async throws -> SupervisionDeskEntry {
        let worktree = try await createScratchSpace(project: inputs.project)

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
            created = try await lifecycle.spawnPrimaryTerminals(
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
                // at all and nothing would say so.
                primaryAgentPreference: .claude,
                supervisionProject: inputs.project,
                supervisionPlaybook: inputs.playbook.text)
        } catch {
            await actuationLog.appendOutcome(
                confirms: actuationID, result: .transportFailed, error: "\(error)")
            throw SupervisionDeskError.spawnFailed(
                project: inputs.project, detail: String(describing: error))
        }
        await actuationLog.appendOutcome(confirms: actuationID, result: .dispatched)

        guard let primary = created.first else {
            throw SupervisionDeskError.spawnFailed(
                project: inputs.project, detail: "the spawn created no terminal")
        }

        let at = now()
        let entry = SupervisionDeskEntry(
            terminal: primary.id, worktree: worktree.id,
            spawnedAt: SupervisionInstant(at), conductHash: inputs.playbook.conductHash)
        do {
            try desks.save(file.recording(entry, for: inputs.project))
        } catch {
            throw SupervisionDeskError.recordFailed(
                project: inputs.project, detail: String(describing: error))
        }

        subscriptions?.broadcast(delta: .worktreeCreated(WorktreeDelta(
            worktreeID: worktree.id, repoID: nil, name: worktree.name,
            path: worktree.localPath, status: worktree.status)))

        let ref = SupervisionDeskRef(terminal: entry.terminal, worktree: entry.worktree)
        if let predecessor {
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

    private func notify(_ message: String, worktree: UUID) {
        let db = self.db
        let subscriptions = self.subscriptions
        Task {
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
}
