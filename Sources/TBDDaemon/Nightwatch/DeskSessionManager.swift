import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "nightwatch.desk")

/// Protocol for dependency injection in testing. Allows mocking DeskSessionManager
/// for testing DaywatchRunner's desk-gated branches (ensure-on-start, nudge-on-tick-10, wrap-up-on-stop, etc).
public protocol DeskSessionManaging: Sendable {
    func ensureDeskSession(mode: NightwatchMode) async throws -> Worktree
    func nudgeDeskSession(worktreeID: UUID, act: Bool) async
    func postShiftWrapUp(worktreeID: UUID) async
    func closeDeskSession() async
    func releaseJudgeLease(worktreeID: UUID) async
    func maintainJudgeLease(worktreeID: UUID) async
}

public extension DeskSessionManaging {
    func releaseJudgeLease(worktreeID: UUID) async {}
    func maintainJudgeLease(worktreeID: UUID) async {}
}

/// Manages the persistent "Watch Desk" scratch space for daywatch/nightwatch operations.
/// Idempotent creation: mode switches reuse the existing desk session.
/// Nudges the session when judgment items are queued (tick exit code 10).
public actor DeskSessionManager: DeskSessionManaging {
    // MARK: - Dependencies

    private let db: TBDDatabase
    private let lifecycle: WorktreeLifecycle
    private let tmux: TmuxManager
    /// Broadcasts worktree create/archive deltas so connected app clients update
    /// immediately (matching RPCRouter+ScratchHandlers) instead of waiting for a poll.
    private let subscriptions: StateSubscriptionManager?
    private let skillDir: String
    /// Date seam for the nudge-overlap guard — a compared timestamp, so per
    /// `Tests/CLAUDE.md` this is the `now:` shape, not an injected `Clock`.
    /// Without it the 10-minute window is unreachable in a test, which is why the
    /// guard went so long with no observable beyond "doesn't throw".
    private let now: @Sendable () -> Date
    /// The daemon's actuation record. The desk's pastes bypass the RPC router,
    /// so this rail writes its own rows.
    private let actuationLog: ActuationLog

    // MARK: - State

    // MARK: - Serialization gate
    //
    // Actors are reentrant across suspension points, so ensure/close each have
    // read→await→write windows on `deskWorktreeID` that can interleave (two
    // concurrent first-ensures double-creating a desk; a stale close archiving
    // a desk a newer ensure just made). This FIFO gate makes each public
    // mutating operation atomic with respect to the others.
    private var gateBusy = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    private func gateAcquire() async {
        if gateBusy {
            await withCheckedContinuation { gateWaiters.append($0) }
            // Resumed by gateRelease(); gateBusy intentionally stays true.
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

    /// UUID of the current Watch Desk worktree; nil if none exists.
    /// Cleared when mode transitions to .off. Persists across mode switches between
    /// daywatch and nightwatch.
    private var deskWorktreeID: UUID?

    /// Timestamp of the last nudge; used to skip overlapping nudges (< 10 min apart).
    /// M2: nudge-overlap guard. Phase B upgrade: claim-file (queue/claims) single-driver enforcement.
    private var lastNudgeTime: Date?

    /// Mode carried by the last nudge that actually reached the session.
    ///
    /// The judge is told to read `JUDGE-INSTRUCTIONS.md` once rather than every
    /// tick, so *someone* has to notice when the body it memorized stops matching
    /// the body on disk. The desk is deliberately reused across daywatch ↔
    /// nightwatch without respawning (see `ensureDeskSession`), and the two bodies
    /// differ on exactly the thing that matters — whether an unattended
    /// `gh pr merge` is authorized. `nil` means nothing has been nudged yet, which
    /// is treated the same as changed: a judge with no reads is a judge that must read.
    ///
    /// Internal rather than private so tests can assert the transition; it is state
    /// the manager needs regardless.
    private(set) var lastNudgedMode: NightwatchMode?

    /// Deduplicates the fail-closed notification for one conflicting owner
    /// generation. A new generation is a new incident and notifies again.
    private var notifiedContentionGeneration: Int64?

    /// The agent this rail spawned the last time it found the desk empty.
    ///
    /// Bounds recovery on evidence rather than on a clock. A time-based limit
    /// cannot help here: the desk ticks roughly every fifteen minutes, so any
    /// interval short enough to allow real recovery is also short enough to
    /// allow one abandoned agent per tick. Instead, a second replacement waits
    /// until this one is gone from the database or PROVEN absent — see
    /// `spawnRecoveryTerminalIfWarranted`.
    private var lastRecoveryTerminalID: UUID?

    /// Replacements spawned since a nudge last reached a pane. Bounded by
    /// `maxConsecutiveRecoverySpawnsWithoutNudge` so a launch that dies on every
    /// attempt cannot spawn forever. Cleared only by `resetRecoveryBudget` — a
    /// delivered nudge, a desk built fresh, or a desk closed.
    private var consecutiveRecoverySpawnsWithoutNudge = 0

    /// Deduplicates the give-up notification so the user is told once per
    /// incident rather than every tick. Cleared whenever the counter it guards is.
    private var notifiedRecoveryExhaustion = false

    /// Three, because the two failure modes it sits between are asymmetric and
    /// both real.
    ///
    /// One attempt is too few. A launch can fail for reasons that pass on their
    /// own — a machine too loaded to start an agent, a tmux server mid-restart, a
    /// profile being re-authenticated — and a cap of one would let a single
    /// unlucky minute silence the desk until a human toggled the mode. Three
    /// leaves two retries after the first failure, spread across roughly
    /// forty-five minutes at the desk's fifteen-minute tick.
    ///
    /// Many attempts are too many, and the cost is not the retry but the debris:
    /// every attempt that half-succeeds leaves a real tmux window and a real
    /// agent process behind, and nothing reaps them. Unbounded, an overnight
    /// shift accumulates one per tick — the bug this rail was built to end. Three
    /// bounds the wreckage at three abandoned sessions and then says so out loud.
    ///
    /// What matters for a theory-shaped constant is who chose it and how cheaply
    /// they can change their mind. Adam chose three on 2026-08-17, asked directly
    /// with this rationale and the rejected alternatives in front of him, and
    /// answered directly. That is the whole provenance: a decision in
    /// conversation, not a review comment or a committed artifact — so if you go
    /// looking in the PR record for it, that is why it is not there.
    ///
    /// The bound's design, the alternatives weighed against it, and why the
    /// threshold stays compiled for now:
    /// `docs/specs/2026-08-14-watch-desk-recovery-bound-design.md`.
    private static let maxConsecutiveRecoverySpawnsWithoutNudge = 3

    // MARK: - Init

    public init(
        db: TBDDatabase,
        lifecycle: WorktreeLifecycle,
        tmux: TmuxManager,
        skillDir: String,
        subscriptions: StateSubscriptionManager? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        actuationLog: ActuationLog
    ) {
        self.db = db
        self.lifecycle = lifecycle
        self.tmux = tmux
        self.subscriptions = subscriptions
        self.skillDir = skillDir
        self.now = now
        self.actuationLog = actuationLog
        self.deskWorktreeID = nil
    }

    // MARK: - Public API

    /// Idempotent: ensure a Watch Desk scratch space exists.
    /// Returns existing desk worktree if already created, otherwise creates one.
    /// On recovery, respawns the configured primary agent only if the desk is genuinely
    /// unstaffed (no live agent of any supported kind). Cross-kind incumbent reuse:
    /// an intentional handoff to the non-preferred kind is preserved.
    /// - Parameter mode: The current nightwatch mode (daywatch or nightwatch)
    /// - Returns: The Worktree for the desk session
    public func ensureDeskSession(mode: NightwatchMode) async throws -> Worktree {
        await gateAcquire()
        defer { gateRelease() }

        // Validate cached desk session: the row alone is not enough. Agent
        // processes can exit before their terminal row is removed, so require a
        // live pane of either supported kind (not just the preferred one).
        if let cachedID = deskWorktreeID,
           let existing = try await db.worktrees.getLocal(id: cachedID),
           existing.status == .active {
            if await deskStaffing(worktree: existing.worktree).isStaffed {
                // Fast path: cached desk is staffed by either kind.
                // Mode switches (daywatch ↔ nightwatch) intentionally REUSE the existing desk and terminal.
                // The desk is NOT respawned on mode switch because every tick re-derives the mode and
                // rewrites JUDGE-INSTRUCTIONS.md to match. Since the judge is told to read that file once
                // rather than per tick, reuse-without-respawn is exactly the case where a memorized copy
                // can go stale — `nudgeDeskSession` compares against `lastNudgedMode` and flags the flip.
                // Initial frame is one-time; steady-state mode is driven per-tick.
                // Cross-kind reuse: a Codex judge, even if Claude is the configured preference,
                // is an intentional handoff and must not be respawned.
                return existing.worktree
            }
        }

        // Cached entry was stale (archived or genuinely unstaffed); clear it and fall through to recovery/create
        deskWorktreeID = nil

        // Query by displayName to detect existing desk worktrees (active only).
        // This recovery path excludes archived worktrees so off→on cycles don't
        // resurrect dead desk sessions. (survives daemon restart since displayName is stable).
        let activeWorktrees = try await db.worktrees.listLocal(excludeArchived: true)
        if let existing = activeWorktrees.first(where: { $0.displayName == NightwatchDeskPrompts.deskDisplayName && $0.isScratch }) {
            deskWorktreeID = existing.id

            // Respawn only on proof that the desk has no agent of EITHER kind,
            // and never more than once per unaccounted-for replacement — the
            // whole rule lives in `spawnRecoveryTerminalIfWarranted` so this
            // site and the nudge path cannot drift apart.
            await spawnRecoveryTerminalIfWarranted(
                worktree: existing.worktree,
                mode: mode,
                staffing: await deskStaffing(worktree: existing.worktree))

            logger.info("Reusing existing Watch Desk session: \(existing.id, privacy: .public)")
            return existing.worktree
        }

        // Create a new scratch space
        let fm = FileManager.default
        let scratchDir = TBDConstants.scratchDir
        try fm.createDirectory(at: scratchDir, withIntermediateDirectories: true)

        // Allocate a unique directory name
        var name = "watch-desk"
        var deskPath = scratchDir.appendingPathComponent(name)
        var attempts = 0
        while true {
            let existsOnDisk = fm.fileExists(atPath: deskPath.path)
            let existsInDB = try await db.worktrees.findByPath(path: deskPath.path) != nil
            if !existsOnDisk && !existsInDB {
                break
            }
            name = "watch-desk-\(UUID().uuidString.prefix(8))"
            deskPath = scratchDir.appendingPathComponent(name)
            attempts += 1
            if attempts > 50 {
                throw WorktreeLifecycleError.createFailed("Could not allocate unique desk directory after 50 attempts")
            }
        }

        // Create the directory
        try fm.createDirectory(at: deskPath, withIntermediateDirectories: false)

        let tmuxServer = TmuxManager.serverName(forRepoPath: scratchDir.path)

        // Create DB row
        let wt: Worktree
        do {
            wt = try await db.worktrees.createScratch(
                name: name,
                displayName: NightwatchDeskPrompts.deskDisplayName,
                path: deskPath.path,
                tmuxServer: tmuxServer
            )
        } catch {
            try? fm.removeItem(at: deskPath)
            throw error
        }

        // Spawn the configured primary agent for nightwatch operations. A desk
        // built from scratch carries nothing forward from the last one, so any
        // in-flight replacement incident ends here.
        resetRecoveryBudget()
        do {
            _ = try await spawnDeskTerminal(worktree: wt, mode: mode)
        } catch {
            logger.warning("Failed to spawn desk terminal: \(error.localizedDescription, privacy: .public)")
            // Terminal spawn failure is best-effort; don't fail the worktree creation
        }

        // Cache the worktree ID
        deskWorktreeID = wt.id

        // Mirror handleScratchCreate: tell connected clients immediately.
        subscriptions?.broadcast(delta: .worktreeCreated(WorktreeDelta(
            worktreeID: wt.id, repoID: nil, name: wt.name, path: wt.localPath, status: wt.status)))

        logger.info("Created Watch Desk session: \(wt.id, privacy: .public) at \(wt.localPath, privacy: .public)")
        return wt
    }

    /// What the desk's consultations proved about one candidate row.
    ///
    /// Two questions run over the same evidence and must not share an answer:
    /// *may I paste into this pane?* and *is anyone already sitting at this
    /// desk?* The first is satisfied only by `.live`. The second is satisfied by
    /// `.live` **or** `.unknown`, because spawning is a creating act and may
    /// happen only on proof of an empty desk — never on a consultation that
    /// could not be run. One false negative that licenses a spawn becomes a new
    /// abandoned agent on every tick for as long as the fault lasts.
    private enum CandidateVerdict {
        /// Pane exists, belongs to this row, and an agent of the row's kind is
        /// in its foreground. The only verdict a send may act on.
        case live
        /// PROOF the row's coordinate holds no agent of ours: the window is
        /// gone, tmux says the pane is gone, the pane's process has exited, the
        /// pane now belongs to a different terminal, or it is running something
        /// that is not this kind of agent.
        case absent
        /// A consultation could not be answered. Proof of nothing.
        case unknown
    }

    /// Every candidate row of one kind, split by verdict — the single traversal
    /// both questions read. `live` keeps its original order (newest first).
    private struct CandidateClassification {
        var live: [Terminal] = []
        var absent: [Terminal] = []
        var unknown: [Terminal] = []
        /// The candidate rows themselves could not be read, so this desk has not
        /// been ruled empty either. Separate from `unknown`, which names rows we
        /// did read and could not consult.
        var rowsUnreadable = false

        /// The desk could not be read at all — staffed by the same rule that
        /// governs every other unanswerable question here.
        static var unreadable: CandidateClassification {
            CandidateClassification(rowsUnreadable: true)
        }

        /// True unless every candidate was PROVEN absent. An empty desk with no
        /// rows at all is unstaffed; a desk whose rows could not be consulted is
        /// treated as staffed, which costs a skipped tick and prevents a spawn
        /// nobody can justify.
        var isStaffed: Bool { !live.isEmpty || !unknown.isEmpty || rowsUnreadable }

        mutating func record(_ terminal: Terminal, _ verdict: CandidateVerdict) {
            switch verdict {
            case .live: live.append(terminal)
            case .absent: absent.append(terminal)
            case .unknown: unknown.append(terminal)
            }
        }

        mutating func merge(_ other: CandidateClassification) {
            live.append(contentsOf: other.live)
            absent.append(contentsOf: other.absent)
            unknown.append(contentsOf: other.unknown)
        }

        /// Whether this row was proven absent — the only evidence that justifies
        /// replacing it, or stripping its lease. A row nobody could consult is
        /// not "gone".
        func provenAbsent(_ terminalID: UUID) -> Bool {
            absent.contains { $0.id == terminalID }
        }

        /// Live candidates across both kinds, newest first. Secondary key on id:
        /// Swift's sort is not stable and two rows can share a `createdAt`.
        var liveNewestFirst: [Terminal] {
            live.sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
        }
    }

    /// Classify every candidate row of one kind — the desk's *live* agents,
    /// newest first, plus what was proven about everyone else.
    ///
    /// `TerminalStore.list` orders by `createdAt` ascending, so the previous
    /// `terminals.first(where:)` deterministically returned the OLDEST row —
    /// not a race, a guarantee. Desk terminal rows outlive their
    /// panes: a session that dies, or was killed out-of-band by an older
    /// Nightwatch handoff that bypassed TBD's terminal-close path,
    /// leaves its row behind forever. The oldest row is therefore the one *most* likely
    /// to be dead, and every handoff inserted another corpse ahead of the live desk.
    ///
    /// Observed in production: one desk carried three `Claude Code` rows, the nudge aimed
    /// at the first, and the judge prompt was discarded every fifteen minutes for hours
    /// while ticks kept correctly reporting queued judgment.
    ///
    /// Two guards make that impossible. Prefer the NEWEST row, and confirm its tmux window
    /// still exists before sending. The liveness check is not redundant belt-and-braces:
    /// tmux recycles pane IDs per server — both dead rows in the incident above had been
    /// assigned `%1` — so a stale row can start resolving to a *live pane owned by an
    /// unrelated session*, which would then receive a pasted judge prompt plus Enter. That
    /// is issue #384, and picking the newest row alone would not prevent it.
    ///
    /// Neither guard is sufficient on its own, and neither proves *ownership*.
    /// `windowExists` proves a window id resolves to SOME window;
    /// `paneCurrentCommand` proves an agent of the right kind is in the
    /// foreground of SOME pane. A recycled pane id running a stranger's Claude
    /// satisfies both. So each surviving candidate is asked who it is
    /// (`paneSendTarget`) and dropped when it answers with a different terminal
    /// — see `paneIdentityPermitsSend`.
    ///
    /// Hibernated/suspended rows are excluded even if their tmux window still
    /// exists: their pane contains a shell, not an agent, and pasting a judge
    /// prompt there would execute it as shell input.
    ///
    /// - Returns: The newest matching agent terminal whose tmux window is still alive, or nil.
    private func classifyAgentTerminals(
        worktreeID: UUID,
        server: String,
        kind: TerminalKind
    ) async throws -> CandidateClassification {
        let candidates = try await db.terminals.list(worktreeID: worktreeID)
            .filter {
                $0.suspendedAt == nil
                    && $0.hibernatedAt == nil
                    && terminal($0, matches: kind)
            }
            // Secondary key on id: Swift's sort is not stable, and two rows can share a
            // createdAt, so without it the winner between same-instant rows is arbitrary.
            .sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }

        var classification = CandidateClassification()
        for terminal in candidates {
            classification.record(
                terminal,
                await verdict(server: server, terminal: terminal, kind: kind))
        }
        return classification
    }

    /// Run every consultation against one candidate and reduce them to a verdict.
    ///
    /// The identity question runs first because it is the only consultation that
    /// distinguishes "tmux looked and the pane is gone" from "tmux could not be
    /// asked" — the distinction both callers hang on. The window and
    /// foreground-command checks still gate `.live` exactly as before, so nothing
    /// reaches a paste that would not have reached one previously; all three now
    /// answer that distinction rather than only the first.
    private func verdict(
        server: String,
        terminal: Terminal,
        kind: TerminalKind
    ) async -> CandidateVerdict {
        let identity = await paneIdentityVerdict(server: server, terminal: terminal)
        guard identity == .live else { return identity }

        switch await tmux.windowExistence(server: server, windowID: terminal.tmuxWindowID) {
        case .exists:
            break
        case .gone:
            logger.notice("""
                Skipping stale Watch Desk terminal \(terminal.id, privacy: .public): \
                window \(terminal.tmuxWindowID, privacy: .public) no longer exists
                """)
            return .absent
        case .unverifiable(let error):
            // The same rule as the other two consultations. `windowExists` — the
            // Bool this used to call — folds a wedged or unreachable server into
            // "the window is gone", which is the exact collapse that licenses a
            // spawn beside a healthy judge.
            logger.notice("""
                Skipping Watch Desk terminal \(terminal.id, privacy: .public): could not determine \
                whether window \(terminal.tmuxWindowID, privacy: .public) still exists: \
                \(error, privacy: .public)
                """)
            return .unknown
        }

        if tmux.verifiesPaneCurrentCommand {
            let command: String
            do {
                command = try await tmux.paneCurrentCommand(
                    server: server, paneID: terminal.tmuxPaneID)
            } catch {
                // Same rule as the identity consultation: a query that could not
                // run says nothing. It still bars a send (this returns a
                // non-`live` verdict either way), but it must not be mistaken
                // for an empty pane.
                logger.notice("""
                    Skipping Watch Desk terminal \(terminal.id, privacy: .public): could not read \
                    the foreground process of pane \(terminal.tmuxPaneID, privacy: .public): \
                    \(String(describing: error), privacy: .public)
                    """)
                return .unknown
            }
            guard Self.agentCommand(command, matches: kind) else {
                logger.notice("""
                    Skipping stale Watch Desk terminal \(terminal.id, privacy: .public): \
                    pane exists but no \(kind.rawValue, privacy: .public) process is running
                    """)
                return .absent
            }
        }
        return .live
    }

    /// Ask a candidate's pane who it belongs to, before it can become the target
    /// of a paste nobody asked for.
    ///
    /// The same read-only consultation `handleTerminalSend` and
    /// `LimitResumeActuator` run, on the same rule, and the rule is the whole
    /// point: **refusal requires POSITIVE disagreement, never absence.** A pane
    /// that answers with no identity — spawned before TBD stamped one, or by
    /// something outside TBD — is treated exactly as it was before this check
    /// existed, so no pre-stamp desk regresses into a silent night. Only a pane
    /// that names a *different* terminal is dropped.
    ///
    /// This rail needs it more than the send path does. Both consumers of the
    /// candidate list paste on a timer with no user gesture behind them, and
    /// what they paste is a judge prompt: a stranger agent on a recycled pane id
    /// would not merely receive a stray keystroke, it would read and act on
    /// instructions addressed to another session, with permissions bypassed.
    ///
    /// Excluding rather than throwing is what makes the outcome safe by
    /// default. A dropped candidate is simply not live, so the callers'
    /// existing "no uniquely owned live terminal … skipping" path handles it,
    /// and `leasedJudgeTerminal` gets *more* correct: a stranger can no longer
    /// masquerade as the lease owner, nor pad the candidate count into a
    /// spurious fail-closed contention report.
    ///
    /// - Returns: `.live` when this pane may be sent to; `.absent` when tmux
    ///   proved it holds nothing of ours; `.unknown` when nobody could tell.
    ///   Only `.live` permits a send — the three-way split exists for the
    ///   staffing question, which must not read "I could not look" as "empty".
    private func paneIdentityVerdict(
        server: String, terminal: Terminal
    ) async -> CandidateVerdict {
        let target: PaneSendTarget
        do {
            target = try await tmux.paneSendTarget(server: server, paneID: terminal.tmuxPaneID)
        } catch {
            // The consultation could not be RUN at all (a wedged tmux tripping
            // the subprocess timeout) — no answer about the pane either way.
            // Pasting a judge prompt into a pane we could not look at is exactly
            // what this check exists to stop, and the cost of being wrong is a
            // skipped tick. Replacing that pane on the same non-answer would
            // cost an abandoned agent per tick, which is why this is `.unknown`
            // and not `.absent`.
            logger.notice("""
                Skipping Watch Desk terminal \(terminal.id, privacy: .public): could not verify \
                pane \(terminal.tmuxPaneID, privacy: .public) belongs to it: \
                \(String(describing: error), privacy: .public)
                """)
            return .unknown
        }

        switch target {
        case .missing:
            logger.notice("""
                Skipping stale Watch Desk terminal \(terminal.id, privacy: .public): \
                pane \(terminal.tmuxPaneID, privacy: .public) no longer exists
                """)
            return .absent
        case .dead:
            logger.notice("""
                Skipping stale Watch Desk terminal \(terminal.id, privacy: .public): \
                pane \(terminal.tmuxPaneID, privacy: .public) is dead
                """)
            return .absent
        case .unverifiable(let error):
            // Loud, and carrying tmux's own words: a rail that both refuses to
            // send AND refuses to respawn has gone quiet on purpose, and the
            // only way anyone finds out why is this line.
            logger.warning("""
                Skipping Watch Desk terminal \(terminal.id, privacy: .public): could not consult \
                pane \(terminal.tmuxPaneID, privacy: .public) — \(error, privacy: .public). \
                Nothing will be pasted into it, and nothing will be spawned beside it
                """)
            return .unknown
        case .live(let paneTerminalID):
            guard let paneTerminalID else { return .live }
            guard paneTerminalID.caseInsensitiveCompare(terminal.id.uuidString) != .orderedSame
            else { return .live }
            // Logged distinctly and loudly: to every caller this looks like an
            // ordinary absence, and "no live terminal" is a sentence this rail
            // prints for half a dozen benign reasons. A pane that has changed
            // hands is not benign — it is the row's coordinate gone stale, and
            // it stays stale until something respawns the window.
            logger.warning("""
                Skipping Watch Desk terminal \(terminal.id, privacy: .public): pane \
                \(terminal.tmuxPaneID, privacy: .public) now belongs to terminal \
                \(paneTerminalID, privacy: .public) — nothing will be pasted into it \
                (tmux reuses pane ids, so this coordinate is stale)
                """)
            return .absent
        }
    }

    /// Everything the desk knows about who is sitting at it, across both
    /// supported agent kinds.
    ///
    /// Cross-kind on purpose: a Nightwatch handoff can legitimately replace a
    /// Claude judge with a Codex one (or the reverse), and that successor is the
    /// desk's agent even though it is not the configured primary preference.
    /// Resolving only the preferred kind reads a live incumbent as an empty desk
    /// and spawns a second agent beside it.
    private func deskStaffing(worktree: Worktree) async -> CandidateClassification {
        var staffing = CandidateClassification()
        for kind in [TerminalKind.claude, .codex] {
            do {
                staffing.merge(try await classifyAgentTerminals(
                    worktreeID: worktree.id, server: worktree.tmuxServer, kind: kind))
            } catch {
                // The row read itself failed, so this desk has not been ruled
                // empty — the same rule the per-pane consultations follow. A
                // sentinel `unknown` entry carries that through `isStaffed`
                // without inventing a Terminal nobody read.
                logger.warning("""
                    Watch Desk staffing unknown: could not read \
                    \(kind.rawValue, privacy: .public) terminal rows: \
                    \(error.localizedDescription, privacy: .public)
                    """)
                return CandidateClassification.unreadable
            }
        }
        if staffing.live.isEmpty && !staffing.unknown.isEmpty {
            logger.notice("""
                Watch Desk has no confirmed live agent, but \(staffing.unknown.count) \
                candidate(s) could not be consulted — treating the desk as staffed. \
                Nothing will be spawned until a consultation proves the desk is empty
                """)
        }
        return staffing
    }

    /// Replace the desk's agent — but only on proof that it has none, and never
    /// more than once until that replacement is accounted for.
    ///
    /// Both recovery sites call this, so the rule cannot drift between them.
    /// Three gates, in order:
    ///
    /// 1. **Proof.** `staffing.isStaffed` is false only when every candidate was
    ///    positively ruled absent. An unanswerable consultation leaves the desk
    ///    staffed and nothing is spawned.
    /// 2. **The previous replacement.** A desk terminal row outlives its pane, so
    ///    "did the last recovery work?" cannot be answered by the row's
    ///    existence. It is answered by the same classification: spawn again only
    ///    once that row is gone from the database or proven absent. This is what
    ///    turns a repeating fault into ONE extra terminal instead of one per
    ///    tick, and it still lets a genuinely dead replacement be replaced.
    /// 3. **A backstop count.** A launch that dies every time would satisfy gate
    ///    2 forever. After `maxConsecutiveRecoverySpawnsWithoutNudge` spawns with
    ///    no nudge ever landing, the rail stops and says so — a Watch Desk that
    ///    has quietly given up looks exactly like one that is fine, so this is a
    ///    notification and not only a log line.
    private func spawnRecoveryTerminalIfWarranted(
        worktree: Worktree,
        mode: NightwatchMode,
        staffing: CandidateClassification
    ) async {
        guard !staffing.isStaffed else { return }

        if let previous = lastRecoveryTerminalID {
            let previousRow: Terminal?
            do {
                previousRow = try await db.terminals.get(id: previous)
            } catch {
                // "The table could not be read" is not "the row is gone". A
                // `try?` here would let a database error license the spawn this
                // gate exists to withhold — the same absence-as-evidence mistake
                // the tmux consultations make when they collapse.
                logger.notice("""
                    Not spawning another Watch Desk agent: the terminal table could not be read, \
                    so the previous recovery terminal \(previous, privacy: .public) has not been \
                    accounted for: \(error.localizedDescription, privacy: .public)
                    """)
                return
            }
            if previousRow != nil && !staffing.provenAbsent(previous) {
                logger.notice("""
                    Not spawning another Watch Desk agent: the previous recovery terminal \
                    \(previous, privacy: .public) has not been proven gone
                    """)
                return
            }
        }

        guard consecutiveRecoverySpawnsWithoutNudge < Self.maxConsecutiveRecoverySpawnsWithoutNudge
        else {
            await notifyRecoveryExhausted(worktree: worktree)
            return
        }

        logger.notice("""
            Watch Desk has no live agent; spawning a replacement \
            (attempt \(self.consecutiveRecoverySpawnsWithoutNudge + 1, privacy: .public) \
            of \(Self.maxConsecutiveRecoverySpawnsWithoutNudge, privacy: .public))
            """)
        let spawned: [UUID]
        do {
            spawned = try await spawnDeskTerminal(worktree: worktree, mode: mode)
        } catch {
            logger.warning("""
                Failed to spawn a replacement Watch Desk agent: \
                \(error.localizedDescription, privacy: .public)
                """)
            // A spawn that threw still counts against the backstop: the failure
            // mode this bounds is "keeps trying, never works", and a launch that
            // cannot even start is the purest form of it.
            consecutiveRecoverySpawnsWithoutNudge += 1
            return
        }
        consecutiveRecoverySpawnsWithoutNudge += 1
        // Take the id the spawn itself returned rather than diffing the terminal
        // table around it. The desk is an ordinary sidebar-visible scratch
        // worktree and this actor's gate serializes only its own methods, so a
        // terminal the user opens during the spawn lands inside a before/after
        // diff and would be adopted as the tracked replacement. A shell adopted
        // that way can never be proven absent by an agent-kind consultation,
        // which wedges gate 2 shut and stops recovery for that desk until
        // someone closes the terminal by hand.
        //
        // Newest of the returned ids for the same reason the classification
        // prefers newest: `spawnPrimaryTerminals` mints the primary agent first,
        // and a later row is the more recent coordinate.
        let spawnedRows = ((try? await db.terminals.list(worktreeID: worktree.id)) ?? [])
            .filter { spawned.contains($0.id) }
        lastRecoveryTerminalID = spawnedRows
            .max(by: { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) })?.id
            ?? spawned.last
    }

    /// Clear the replacement budget and everything keyed to the same incident.
    ///
    /// Deliberately not called from `spawnDeskTerminal`: that is the function the
    /// recovery rail calls to make an attempt, so clearing here would undo the
    /// attempt it is about to count. The three callers are the three things that
    /// genuinely end an incident — a nudge that reached a pane, a desk built from
    /// scratch, and a desk closed.
    private func resetRecoveryBudget() {
        consecutiveRecoverySpawnsWithoutNudge = 0
        notifiedRecoveryExhaustion = false
        lastRecoveryTerminalID = nil
    }

    /// Tell the user once that the desk has stopped trying to staff itself.
    /// Deduplicated on the same counter that stopped it, so a desk that recovers
    /// and fails again later is a new incident and notifies again.
    ///
    /// The dedup flag is set only after the write lands, matching
    /// `notifiedContentionGeneration`. Setting it first would let one failed
    /// write silence the incident permanently: the desk has stopped staffing
    /// itself and looks exactly like a desk that is fine, which is the single
    /// thing this notification exists to prevent. Every tick after a failure
    /// therefore tries again, and the first one to succeed stops the retries.
    private func notifyRecoveryExhausted(worktree: Worktree) async {
        logger.error("""
            Watch Desk gave up spawning an agent after \
            \(Self.maxConsecutiveRecoverySpawnsWithoutNudge, privacy: .public) attempts \
            that never took a nudge; no further spawns until one succeeds
            """)
        guard !notifiedRecoveryExhaustion else { return }
        do {
            let notification = try await db.notifications.create(
                worktreeID: worktree.id,
                type: .error,
                message: "Watch Desk could not start an agent after \(Self.maxConsecutiveRecoverySpawnsWithoutNudge) attempts. Nightwatch judgment is paused. Open the desk and start an agent, or turn the mode off and on once the cause is fixed."
            )
            subscriptions?.broadcast(delta: .notificationReceived(NotificationDelta(
                notificationID: notification.id,
                worktreeID: notification.worktreeID,
                type: notification.type,
                message: notification.message,
                terminalID: notification.terminalID,
                activate: false
            )))
            notifiedRecoveryExhaustion = true
        } catch {
            logger.error("""
                Could not record the Watch Desk recovery-exhausted notification, \
                will retry next tick: \(error.localizedDescription, privacy: .public)
                """)
        }
    }

    /// Live judge candidates of either kind, newest first — `deskStaffing`'s
    /// `live` set in the order the lease logic wants it.
    private func liveJudgeCandidates(worktree: Worktree) async -> [Terminal] {
        await deskStaffing(worktree: worktree).liveNewestFirst
    }

    /// Resolve the sole mutable judge. Existing valid ownership wins even when
    /// observers are present. With no lease, multiple candidates are ambiguous
    /// and fail closed rather than selecting by recency.
    private func leasedJudgeTerminal(
        worktree: Worktree,
        staffing: CandidateClassification
    ) async throws -> (Terminal, WatchDeskLease, String)? {
        var candidates = staffing.liveNewestFirst
        let now = now()

        if let lease = try await db.watchDeskLeases.status(worktreeID: worktree.id),
           lease.isValid(at: now) {
            if let owner = candidates.first(where: { $0.id == lease.terminalID }) {
                let renewed = try await db.watchDeskLeases.renew(
                    worktreeID: worktree.id, terminalID: owner.id,
                    token: lease.token, generation: lease.generation, now: now)
                let credentialFile = try WatchDeskLeaseCredentialFile.ensure(WatchDeskLeaseCredential(
                    worktreeID: renewed.worktreeID, terminalID: renewed.terminalID,
                    token: renewed.token, generation: renewed.generation))
                notifiedContentionGeneration = nil
                return (owner, renewed, credentialFile)
            }
            // Revoking is a mutation. It strips a running judge of its authority
            // mid-shift, and the judge cannot undo it or even see it coming —
            // its next renew simply comes back fenced. So revocation takes the
            // same proof spawning takes: the owner's row must be gone, or a
            // consultation must have positively placed its pane absent.
            // "Nobody could reach tmux this tick" is not evidence that the
            // incumbent died. Treating it as such demotes a healthy judge on a
            // timer — and then, finding no judge, spawns a replacement beside
            // it. That pair is one bug, and this guard and the staffing proof
            // are its two halves.
            //
            // A database error is not proof either: `try?` here would turn an
            // unreadable terminal table into "the owner's row is gone" and revoke
            // on it.
            let ownerRow: Terminal?
            do {
                ownerRow = try await db.terminals.get(id: lease.terminalID)
            } catch {
                logger.notice("""
                    Keeping Watch Desk judge lease generation \(lease.generation, privacy: .public): \
                    the terminal table could not be read, which is not proof that owner \
                    \(lease.terminalID, privacy: .public) is gone: \
                    \(error.localizedDescription, privacy: .public)
                    """)
                return nil
            }
            guard ownerRow == nil || staffing.provenAbsent(lease.terminalID) else {
                logger.notice("""
                    Keeping Watch Desk judge lease generation \(lease.generation, privacy: .public): \
                    owner \(lease.terminalID, privacy: .public) could not be consulted this tick, \
                    which is not proof that it is gone — skipping this nudge rather than revoking
                    """)
                return nil
            }
            logger.warning("Revoking Watch Desk judge lease generation \(lease.generation): owner pane is gone")
            try await db.watchDeskLeases.revoke(worktreeID: worktree.id)
            subscriptions?.broadcast(delta: .watchDeskRolesChanged(
                WorktreeIDDelta(worktreeID: worktree.id)))
            candidates = await liveJudgeCandidates(worktree: worktree)
        }

        guard candidates.count <= 1 else {
            // Generation 0 denotes pre-lease ambiguity. Once a real lease has
            // existed, its persisted generation makes subsequent incidents distinct.
            let generation = try await db.watchDeskLeases.status(worktreeID: worktree.id)?.generation ?? 0
            if notifiedContentionGeneration != generation {
                let candidatesList = candidates.map(\.id.uuidString).joined(separator: ", ")
                let notification = try await db.notifications.create(
                    worktreeID: worktree.id,
                    type: .error,
                    message: "Watch Desk has multiple live judge candidates (\(candidatesList)). Mutable Nightwatch actions are paused. Recover with `tbd nightwatch lease acquire --worktree \(worktree.id.uuidString) --terminal <chosen-terminal-id>`."
                )
                subscriptions?.broadcast(delta: .notificationReceived(NotificationDelta(
                    notificationID: notification.id,
                    worktreeID: notification.worktreeID,
                    type: notification.type,
                    message: notification.message,
                    terminalID: notification.terminalID,
                    activate: false
                )))
                notifiedContentionGeneration = generation
            }
            logger.error("Watch Desk judge contention: \(candidates.count) live agent candidates; no nudge sent")
            return nil
        }
        guard let candidate = candidates.first else { return nil }
        let lease = try await db.watchDeskLeases.acquire(
            worktreeID: worktree.id, terminalID: candidate.id, now: now)
        let credentialFile: String
        do {
            credentialFile = try WatchDeskLeaseCredentialFile.ensure(WatchDeskLeaseCredential(
                worktreeID: lease.worktreeID, terminalID: lease.terminalID,
                token: lease.token, generation: lease.generation))
        } catch {
            try? await db.watchDeskLeases.revoke(worktreeID: worktree.id)
            throw error
        }
        subscriptions?.broadcast(delta: .watchDeskRolesChanged(
            WorktreeIDDelta(worktreeID: worktree.id)))
        notifiedContentionGeneration = nil
        return (candidate, lease, credentialFile)
    }

    static func agentCommand(_ command: String, matches kind: TerminalKind) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .claude:
            return ClaudeStateDetector.isClaudeProcess(trimmed)
                || URL(fileURLWithPath: trimmed).lastPathComponent == "claude"
        case .codex:
            return URL(fileURLWithPath: trimmed).lastPathComponent == "codex"
        case .shell:
            return false
        }
    }

    private func preferredAgentKind() async throws -> TerminalKind {
        try await db.config.get().primaryAgentPreference.terminalKind
    }

    private func terminal(_ terminal: Terminal, matches kind: TerminalKind) -> Bool {
        switch kind {
        case .codex:
            return terminal.isCodexTerminal
        case .claude:
            return !terminal.isCodexTerminal
                && (terminal.kind == .claude || terminal.label == TerminalLabel.claudeCode)
        case .shell:
            return false
        }
    }

    /// Post a shift wrap-up prompt to the desk session and fire a completion notification.
    /// Called when daywatch/nightwatch mode is turned OFF to gracefully end the shift.
    /// Sends the wrap-up prompt via tmux (non-destructive), fires a notification, and leaves
    /// the desk active for the user to review/hibernate manually.
    /// - Parameter worktreeID: The Watch Desk worktree ID
    public func postShiftWrapUp(worktreeID: UUID) async {
        await gateAcquire()
        defer { gateRelease() }

        do {
            // Worktree first: resolving a live terminal needs the tmux server to query.
            guard let worktree = try await db.worktrees.getLocal(id: worktreeID) else {
                logger.warning("Watch Desk worktree not found: \(worktreeID, privacy: .public)")
                return
            }

            guard let (agentTerminal, _, _) = try await leasedJudgeTerminal(
                worktree: worktree.worktree,
                staffing: await deskStaffing(worktree: worktree.worktree)
            ) else {
                logger.warning("No uniquely owned live terminal in Watch Desk; skipping wrap-up prompt")
                return
            }

            // Request row before the paste; the paste and the Enter are one
            // send. Fail-closed: an unrecordable wrap-up is not posted — and
            // says so, like every other refusal on this path.
            let actuationID: String
            do {
                actuationID = try await recordDeskSend(
                    worktreeID: worktreeID,
                    terminalID: agentTerminal.id,
                    message: NightwatchDeskPrompts.wrapUpPrompt)
            } catch {
                logger.warning("Skipping Watch Desk wrap-up prompt: \(error, privacy: .public)")
                return
            }

            do {
                // Paste the wrap-up prompt text
                try await tmux.pasteText(
                    server: worktree.tmuxServer,
                    paneID: agentTerminal.tmuxPaneID,
                    bytes: Data(NightwatchDeskPrompts.wrapUpPrompt.utf8)
                )

                // Send Enter to submit
                try await tmux.sendKey(
                    server: worktree.tmuxServer,
                    paneID: agentTerminal.tmuxPaneID,
                    key: "Enter"
                )
            } catch {
                await actuationLog.appendOutcome(
                    confirms: actuationID, result: .transportFailed, error: "\(error)")
                throw error
            }
            await actuationLog.appendOutcome(confirms: actuationID, result: .dispatched)

            // Fire a completion notification
            _ = try await db.notifications.create(
                worktreeID: worktreeID,
                type: .taskComplete,
                message: "Daywatch ended — shift summary posted to the Watch Desk."
            )

            logger.info("Posted shift wrap-up prompt to Watch Desk: \(worktreeID, privacy: .public)")
        } catch {
            logger.error("Failed to post shift wrap-up: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Nudge the desk session to process queued judgment items.
    /// Uses pasteText + sendKey pattern (mirrors handleTerminalSend).
    /// M2: nudge-overlap guard — skips if last nudge was < 10 min ago (prevent overlapping judge runs).
    /// Phase B upgrade: implement claim-file (queue/claims) single-driver enforcement to replace time-based guard.
    /// - Parameters:
    ///   - worktreeID: The Watch Desk worktree ID
    ///   - act: true for nightwatch (auto-act), false for daywatch (dry-run/batch only)
    public func nudgeDeskSession(worktreeID: UUID, act: Bool) async {
        // Same FIFO gate as ensure/close: the overlap-guard's check-then-act
        // (lastNudgeTime read → awaits → write) is not atomic under actor
        // reentrancy without it.
        await gateAcquire()
        defer { gateRelease() }
        // M2: Skip nudge if previous nudge was < 10 min ago (prevent overlapping judge runs)
        if let last = lastNudgeTime {
            let elapsed = now().timeIntervalSince(last)
            if elapsed < 10 * 60 {
                logger.debug("Skipping nudge: last nudge was \(Int(elapsed))s ago (< 10 min)")
                return
            }
        }

        let mode: NightwatchMode = act ? .nightwatch : .daywatch

        do {
            // Worktree first: resolving a live terminal needs the tmux server to query.
            guard let worktree = try await db.worktrees.getLocal(id: worktreeID) else {
                logger.warning("Watch Desk worktree not found: \(worktreeID, privacy: .public)")
                return
            }

            var preferredKind = try await preferredAgentKind()
            // One traversal per tick, shared by both questions it answers:
            // who may be nudged, and whether the desk is empty enough to staff.
            let staffing = await deskStaffing(worktree: worktree.worktree)
            var judge = try await leasedJudgeTerminal(
                worktree: worktree.worktree, staffing: staffing)
            if judge == nil {
                // A terminal row can survive a process/pane exit. Recover in the
                // nudge path itself so one failed launch does not turn into a
                // silent all-night outage waiting for a mode toggle or daemon
                // restart. spawnPrimaryTerminals uses the same configured
                // primary-agent preference and production launch path as normal
                // worktrees.
                //
                // Having no *judge* is not the same as having no *agent*: the
                // lease can be unresolved while a live incumbent sits right
                // there, so what gates the spawn is the staffing proof, not this
                // branch.
                let spawnedCount = consecutiveRecoverySpawnsWithoutNudge
                await spawnRecoveryTerminalIfWarranted(
                    worktree: worktree.worktree, mode: mode, staffing: staffing)
                if consecutiveRecoverySpawnsWithoutNudge != spawnedCount {
                    // Re-read in case the preference changed while spawning.
                    preferredKind = try await preferredAgentKind()
                    judge = try await leasedJudgeTerminal(
                        worktree: worktree.worktree,
                        staffing: await deskStaffing(worktree: worktree.worktree))
                }
            }

            guard let (agentTerminal, lease, credentialFile) = judge else {
                // Deliberately does NOT stamp lastNudgeTime: a nudge that never
                // reached a pane must not start the 10-minute overlap cooldown,
                // or one dead desk would suppress the next recovery attempt.
                logger.warning("No live \(preferredKind.rawValue, privacy: .public) terminal in Watch Desk after retry; skipping nudge")
                return
            }

            // The ~5 KB instructions go to a file; only the one-line pointer goes
            // into the session. Rewritten every tick rather than once at spawn
            // because it is mode-specific and a local write costs nothing — that
            // also makes the file self-healing across daemon restarts, mode
            // switches, and a desk whose directory was cleaned out under it.
            //
            // Fallback, deliberately: if the write fails there is no file to point
            // at, so we paste the full prompt exactly as before. A judge holding
            // stale instructions is a bad night; a judge holding a pointer to
            // nothing is a silent one.
            let prompt: String
            if let instructionsPath = writeJudgeInstructions(
                deskPath: worktree.path, mode: mode, lease: lease,
                credentialFile: credentialFile) {
                // A mode flip rewrites the file under a judge that was told to read
                // it once. Nothing on the judge's side can see that happen, so the
                // daemon — the only party that knows both the old and new mode —
                // has to say so. First nudge (nil) counts as changed: a judge that
                // has read nothing must read.
                prompt = NightwatchDeskPrompts.judgeNudge(
                    mode: mode,
                    instructionsPath: instructionsPath,
                    instructionsChanged: lastNudgedMode != mode
                )
            } else {
                logger.warning("Could not write judge instructions to \(worktree.path, privacy: .public); falling back to the inline prompt")
                prompt = NightwatchDeskPrompts.judgePrompt(mode: mode, skillDir: skillDir)
            }

            // Request row before the paste; the paste and the Enter are one
            // send. Fail-closed: an unrecordable nudge is not sent, and
            // `lastNudgeTime` below is left alone so the next tick retries.
            let actuationID: String
            do {
                actuationID = try await recordDeskSend(
                    worktreeID: worktreeID,
                    terminalID: agentTerminal.id,
                    message: prompt)
            } catch {
                logger.warning("Skipping Watch Desk nudge: \(error, privacy: .public)")
                return
            }

            do {
                // Paste the prompt text (matches handleTerminalSend pattern for reliability)
                try await tmux.pasteText(
                    server: worktree.tmuxServer,
                    paneID: agentTerminal.tmuxPaneID,
                    bytes: Data(prompt.utf8)
                )

                // Send Enter to submit
                try await tmux.sendKey(
                    server: worktree.tmuxServer,
                    paneID: agentTerminal.tmuxPaneID,
                    key: "Enter"
                )
            } catch {
                await actuationLog.appendOutcome(
                    confirms: actuationID, result: .transportFailed, error: "\(error)")
                throw error
            }
            await actuationLog.appendOutcome(confirms: actuationID, result: .dispatched)

            // Record nudge time for overlap guard. `lastNudgedMode` is set only
            // here, after the paste actually went out — a nudge that failed to
            // reach the session must not count as "the judge has seen this mode",
            // or the next tick would tell it nothing changed when everything did.
            lastNudgeTime = now()
            lastNudgedMode = mode

            // A nudge landed, so the desk is staffed by something that took it:
            // the replacement budget and its give-up notice reset here. A reset at
            // spawn time instead would count a launch that never came up as a
            // success — which is exactly how the backstop was first defeated.
            resetRecoveryBudget()

            logger.debug("Nudged Watch Desk session: act=\(act, privacy: .public)")
        } catch {
            logger.error("Failed to nudge desk session: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One request row for a desk paste, carrying the payload verbatim.
    /// Returns the minted id; throws when the record is unwritable even after
    /// the writer's reopen-retry, in which case the caller must not paste.
    private func recordDeskSend(
        worktreeID: UUID, terminalID: UUID, message: String
    ) async throws -> String {
        var row = ActuationRow(
            actor: .daemon(rail: ActuationRail.nightwatchDesk), kind: .send)
        row.target = .local(worktree: worktreeID, terminal: terminalID)
        row.message = message
        row.submit = true
        return try await actuationLog.appendRequest(row)
    }

    /// Gracefully close the desk session (archive it).
    /// Direct archive (vs. promote-and-close) is intentional: desk sessions are transient scratch spaces
    /// scoped to a single mode run. Archiving preserves the session history on disk while removing it
    /// from active management. The next mode change (off→on) will detect the archived desk and exclude it
    /// from recovery (ensuring a fresh session if desired). Promotion not applicable here since desk is
    /// never user-facing as a persistent worktree.
    public func closeDeskSession() async {
        await gateAcquire()
        defer { gateRelease() }
        guard let worktreeID = deskWorktreeID else { return }

        do {
            guard let wt = try await db.worktrees.getLocal(id: worktreeID) else {
                logger.warning("Watch Desk worktree not found during close: \(worktreeID, privacy: .public)")
                deskWorktreeID = nil
                return
            }

            let terminals = try await db.terminals.list(worktreeID: wt.id)

            // This rail kills the desk's windows itself rather than through a
            // lifecycle an RPC handler already rowed, so it writes its own —
            // one dispose naming the desk worktree, the shape `worktree.archive`
            // uses, because the per-terminal kills below are how this one intent
            // is carried out. Fail-closed like the wrap-up and the nudge: an
            // unrecordable close does not happen, and `deskWorktreeID` is left
            // set (this returns before the reset at the end) so the next close
            // still knows which desk to tear down.
            var row = ActuationRow(
                actor: .daemon(rail: ActuationRail.nightwatchDesk), kind: .dispose)
            row.target = ActuationTarget(worktree: wt.id.uuidString)
            let actuationID: String
            do {
                actuationID = try await actuationLog.appendRequest(row)
            } catch {
                logger.warning("Skipping Watch Desk close: \(error, privacy: .public)")
                return
            }

            // Kill tmux windows
            for t in terminals {
                try? await tmux.killWindow(server: wt.tmuxServer, windowID: t.tmuxWindowID)
            }
            await actuationLog.appendOutcome(confirms: actuationID, result: .dispatched)

            // Delete terminal rows
            try await db.terminals.deleteForWorktree(worktreeID: wt.id)
            try await db.tabs.deleteForWorktree(worktreeID: wt.id)

            // Archive the worktree (preserve the folder on disk)
            try await db.worktrees.archive(id: wt.id)

            // Mirror handleScratchArchive: tell connected clients immediately.
            subscriptions?.broadcast(delta: .worktreeArchived(WorktreeIDDelta(worktreeID: wt.id)))

            logger.info("Archived Watch Desk session: \(wt.id, privacy: .public)")
        } catch {
            logger.error("Failed to close desk session: \(error.localizedDescription, privacy: .public)")
        }

        deskWorktreeID = nil
        // The desk this budget was counting against no longer exists; the next
        // one starts its own incident.
        resetRecoveryBudget()
    }

    public func releaseJudgeLease(worktreeID: UUID) async {
        do {
            guard let lease = try await db.watchDeskLeases.status(worktreeID: worktreeID) else { return }
            try await db.watchDeskLeases.release(
                worktreeID: worktreeID, terminalID: lease.terminalID,
                token: lease.token, generation: lease.generation)
            WatchDeskLeaseCredentialFile.remove(terminalID: lease.terminalID)
            notifiedContentionGeneration = nil
            subscriptions?.broadcast(delta: .watchDeskRolesChanged(
                WorktreeIDDelta(worktreeID: worktreeID)))
            logger.info("Released Watch Desk judge lease generation \(lease.generation)")
        } catch {
            logger.error("Failed to release Watch Desk judge lease: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fifteen-minute scheduler heartbeat. It renews/reconciles ownership
    /// without sending a model prompt, so the lease cannot expire behind the
    /// ten-minute nudge overlap guard during an otherwise quiet shift.
    public func maintainJudgeLease(worktreeID: UUID) async {
        await gateAcquire()
        defer { gateRelease() }
        do {
            guard let worktree = try await db.worktrees.getLocal(id: worktreeID) else { return }
            _ = try await leasedJudgeTerminal(
                worktree: worktree.worktree,
                staffing: await deskStaffing(worktree: worktree.worktree))
        } catch {
            logger.error("Failed to maintain Watch Desk judge lease: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private Helpers

    /// Write the mode-specific judge instructions into the desk worktree.
    ///
    /// Returns the absolute path on success, `nil` on any failure — callers treat
    /// `nil` as "fall back to the inline prompt" rather than proceeding with a
    /// pointer to a file that may not exist. Deliberately non-throwing: a desk
    /// that cannot write a file must still get nudged.
    private func writeJudgeInstructions(
        deskPath: String, mode: NightwatchMode, lease: WatchDeskLease? = nil,
        credentialFile: String? = nil
    ) -> String? {
        let url = URL(fileURLWithPath: deskPath)
            .appendingPathComponent(NightwatchDeskPrompts.judgeInstructionsFileName)
        var body = NightwatchDeskPrompts.judgePrompt(mode: mode, skillDir: skillDir)
        if let lease, let credentialFile {
            body += """


            ## Exclusive judge lease (mandatory)

            You are the sole mutable judge only while this lease validates:
            - worktree: `\(lease.worktreeID.uuidString)`
            - terminal: `\(lease.terminalID.uuidString)`
            - generation: `\(lease.generation)`
            - capability file: `\(credentialFile)`

            Immediately before every merge/enqueue, infrastructure apply, archive,
            wake/nudge, or worker spawn, renew the lease. Renewal also validates
            the exact terminal, token, generation, and unexpired authority:

            `tbd nightwatch lease renew --credential-file \(credentialFile)`

            If renewal fails, stop mutating. Read-only inspection and reporting remain allowed.
            """
        }
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            logger.warning("Failed to write judge instructions: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Spawn the configured primary agent in the desk worktree using
    /// lifecycle.spawnPrimaryTerminals.
    /// This reuses the production spawn path which handles trust seeding, overlay injection, etc.
    /// Note: Model selection (daywatch=Sonnet, nightwatch=Opus) requires per-profile configuration.
    /// The resolved profile's model is what gets used; mode affects behavior (conservative vs. free-acting),
    /// not the LLM model directly (that's a user's profile choice).
    @discardableResult
    private func spawnDeskTerminal(
        worktree: Worktree, mode: NightwatchMode
    ) async throws -> [UUID] {
        // Get initial prompt for mode (includes absolute skillDir paths and field learnings)
        let initialPrompt = NightwatchDeskPrompts.initialPrompt(mode: mode, skillDir: skillDir)

        // A new session has read nothing, so nothing it could have memorized is
        // still valid. `lastNudgedMode` is keyed on the MODE, not on which session
        // is running, so without this reset a crash-respawn with the mode
        // unchanged computes `lastNudgedMode != mode` == false and tells a
        // brand-new judge "you already read the instructions — don't re-read".
        // It hasn't. It doesn't. (Caught in review of PR #551.)
        //
        // `lastNudgeTime` goes with it for the same reason: a rate-limit window
        // opened by a session that no longer exists should not silence the first
        // tick of its replacement. Both are per-session facts that were living on
        // the actor, and this is the one chokepoint both spawn paths — fresh
        // create and crash recovery — pass through.
        //
        // Reset unconditionally, before the spawn can throw: over-signalling
        // costs one extra file Read, under-signalling costs a judge running an
        // unattended shift on instructions it never opened.
        //
        // The recovery budget deliberately does NOT reset here. This function is
        // what `spawnRecoveryTerminalIfWarranted` calls to make its attempt, so a
        // reset on this line would run before that caller's increment and pin
        // `consecutiveRecoverySpawnsWithoutNudge` at 1 for every attempt — the
        // backstop would never reach its cap. The budget belongs to the incident,
        // not to the spawn: only a delivered nudge, a fresh desk, or a desk close
        // clears it. See `resetRecoveryBudget`.
        lastNudgedMode = nil
        lastNudgeTime = nil

        // Lay the instructions down before the session exists, so a judge that
        // reads them on its own initiative — before its first tick ever fires —
        // finds them there. Best-effort: the nudge path rewrites this every tick
        // and falls back to the inline prompt if it can't.
        writeJudgeInstructions(deskPath: worktree.localPath, mode: mode).map { path in
            logger.debug("Wrote judge instructions to \(path, privacy: .public)")
        }

        // The rail spawns an agent session here with nobody having asked, so it
        // writes its own row — one naming the desk worktree and no terminal, the
        // shape `worktree.revive` uses, because the terminals are minted inside
        // `spawnPrimaryTerminals`. This is the one chokepoint all three spawn
        // paths pass through (fresh create, recovery, pre-nudge respawn), so a
        // row here counts each spawn exactly once. Fail-closed: the throw
        // reaches the same callers that already treat a failed spawn as
        // best-effort, so an unrecordable spawn simply does not happen.
        var row = ActuationRow(
            actor: .daemon(rail: ActuationRail.nightwatchDesk), kind: .spawn)
        row.target = ActuationTarget(worktree: worktree.id.uuidString)
        let actuationID = try await actuationLog.appendRequest(row)

        // Use production spawn path which handles trust, overlay, and all lifecycle concerns
        let spawned: [(id: UUID, label: String)]
        do {
            spawned = try await lifecycle.spawnPrimaryTerminals(
                worktree: worktree,
                repo: nil,
                skipClaude: false,
                initialPrompt: initialPrompt,
                preSessionTerminalID: nil,
                // Marks the spawn as a desk session, which is what installs the
                // statusline tee — a desk's context-recycling thresholds are
                // fractions of its effective window, and the tee is the only
                // source that reports one. Fleet sessions never get it: TBD's
                // per-session settings outrank the operator's own statusline in
                // every scope they can write. `.readOnlyCoordinator` is the role
                // a desk terminal holds before any judge lease exists.
                watchDeskRole: .readOnlyCoordinator
            )
        } catch {
            await actuationLog.appendOutcome(
                confirms: actuationID, result: .transportFailed, error: "\(error)")
            throw error
        }
        await actuationLog.appendOutcome(confirms: actuationID, result: .dispatched)
        // Model follows the profile spawnPrimaryTerminals resolves internally —
        // resolving here too would just double the keychain-backed lookup.
        logger.info("Spawned desk terminal in \(worktree.id, privacy: .public)")
        return spawned.map(\.id)
    }

}
