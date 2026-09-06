import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "Hibernation")

/// What the park's pending-input rail got when it asked for a holder session's
/// screen: a screen it may judge, or the refusal that stands in its place.
///
/// A type rather than an optional because the three ways to have no judgeable
/// screen — no reader, a source the daemon is not the live store for, a
/// projection that refused — carry different remedies and so different words,
/// and collapsing them would hand the user a sentence that fits none of them.
enum HolderScreenReading: Sendable {
    case readable(TerminalScreen)
    case refused(String)
}

/// What the park's escalation ladder may do to the pid a holder row records —
/// the whole decision table, in one type, because each rung asks the same
/// question and the answers must not drift between them.
///
/// Three facts feed it: whether the row named a pid at all, whether that pid is
/// a corpse, and `ProcessIdentityCheck` — the check every other signalling site
/// in this daemon consults. The mapping is deliberately asymmetric, because the
/// two mistakes are not: a refused park is recoverable on the next sweep, and a
/// signal sent to a stranger's process is not.
///
/// - a corpse (`ps` says `Z…`) → `.gone`. Past its last instruction, and its
///   number cannot be reissued while the entry stands.
/// - `.same` → `.ours`. The one verdict that licenses a signal.
/// - `.notRunning` → `.gone`. Nothing holds the pid, so the child this park set
///   out to end is already past its last instruction. This is a *positive*
///   answer about a real pid and may therefore lead to a finalize, exactly like
///   the registry's `.exited`.
/// - `.startTimeMismatch` / `.foreignExecutable` → `.unverifiable`. The pid
///   names a stranger. In the narrow sense our child IS gone — nothing that
///   survives is ours — but "gone" here would mean finalizing a park whose
///   child this daemon never saw exit, over a row it can no longer describe. So
///   the park refuses instead, and only `.notRunning` (and the registry's own
///   `.exited`) are allowed to complete one.
/// - `.startTimeUnreadable` / `.commandUnreadable` → `.unverifiable`. The
///   kernel would not say. "Keep when uncertain" is the doctrine every
///   signalling site here follows, and an unreadable answer is uncertainty, not
///   absence.
/// - no recorded pid → `.unrecorded`. There is nothing to verify and nothing to
///   signal by number, but the holder is still reachable over its socket.
enum HolderChildDisposition: Sendable, Equatable {
    /// A live process this daemon verified as this session's own child.
    case ours
    /// The recorded pid names nothing.
    case gone
    /// The row records no usable child pid.
    case unrecorded
    /// Alive, and not provably this session's child.
    case unverifiable(ProcessIdentityVerdict)
}

/// Park and wake for the pty-holder transport.
///
/// Split from `HibernationCoordinator` so the diff to that file is a set of
/// branch points rather than a second mechanic interleaved with the first. The
/// two transports share every decision about WHETHER to act — the singleflight
/// claim, the refusal cascade, the transcript rail, the resume argv — and share
/// nothing about HOW: tmux parks by `respawn-window`ing a pane it owns, while a
/// holder session is parked by ending the job the holder forked and clearing
/// the pids that named it.
///
/// **The invariant the whole feature is judged on: a row never finalizes parked
/// while its child is still running.** Every failure below rolls the park
/// intent back rather than completing it, because a row that claims parked over
/// a live process is unreclaimable — nothing sweeps it, the app offers a wake
/// that would spawn a second agent onto the same session, and the process is
/// invisible to every reconciler that reads rows.
extension HibernationCoordinator {

    /// How deep a tail of a holder session's screen the pending-input rail
    /// judges.
    ///
    /// The depth `terminal.output` answers by default, and about a screen's
    /// worth. The rail scans upward for the composer and stops at the first
    /// prompt line it finds, so what it needs is the tail; asking for the whole
    /// retained scrollback would put lines nobody is looking at under a check
    /// that reads only the last of them.
    static let holderScreenLines = 50

    /// The refusal for a holder session whose screen the daemon is not the
    /// live source of.
    ///
    /// Fail-closed, per the transport design's two-store rule, and decided from
    /// the typed screen's own `source` rather than from a second question about
    /// who holds the pty. A viewer's attach suspends the daemon's drain, and a
    /// suspended reader's screen answers `.staleDaemon` — the daemon's emulator
    /// frozen at the moment of that attach. Asking a frozen screen whether
    /// there is unsent typed input is exactly the wrong answer the rail exists
    /// to prevent. Refusing is recoverable; eating a half-composed prompt is
    /// not.
    ///
    /// `.viewer` — a screen the viewer itself answered a pull with — refuses
    /// here for a different reason that lands in the same place: that screen is
    /// live, but somebody is sitting at the keyboard of the session about to be
    /// parked. It is not reachable from a `HolderReader`, which answers only
    /// `.daemon` or `.staleDaemon`; the arm exists because a source is the
    /// question this rail asks, and a new source must be answered rather than
    /// defaulted.
    ///
    /// It names an action the user can take, which is why it is a separate
    /// string from `holderNoReaderRefusal` below: closing the tab makes this
    /// park possible, and telling somebody to close a tab they have not got
    /// would be worse than saying nothing.
    static let holderViewerAttachedRefusal =
        "The daemon's screen for this session is not the live one — a viewer "
        + "holds its pty — so it cannot check for unsent input; close the tab "
        + "or wait for it to leave the viewer before hibernating"

    /// The refusal for a holder session this daemon is not reading at all.
    ///
    /// The same fail-closed rail, reached from the opposite direction: nobody
    /// holds the pty, and the daemon still has no emulator to judge — the
    /// session was never adopted, or its reader is gone. Nothing the user does
    /// to a tab changes that, so the text says what is true rather than
    /// prescribing a gesture that would not help. The distinction is worth a
    /// string of its own precisely because the remedies differ: one is a tab
    /// to close, the other is a session the daemon has lost track of.
    static let holderNoReaderRefusal =
        "The daemon is not reading this session's terminal, so it cannot check "
        + "for unsent input before hibernating"

    /// The refusal for a screen that could not be projected at all.
    ///
    /// `TerminalScreen` refuses a line carrying a control character, and its
    /// own documentation argues why that is a bug in whatever rendered the line
    /// rather than a state a session can put itself in. This rail cannot repair
    /// it and must not guess past it: a screen it could not read is a screen it
    /// cannot clear of unsent input, so it fails closed like every other half
    /// of this rail. The third string exists because the remedy is neither a
    /// tab to close nor a session to re-adopt — it is a defect to fix, and a
    /// refusal that said "close the tab" would send somebody chasing the wrong
    /// thing.
    static let holderScreenProjectionRefusal =
        "The daemon could not read this session's screen to check for unsent "
        + "input before hibernating"

    /// The refusal a screen's `source` implies, or nil when the daemon may
    /// judge it.
    ///
    /// The whole policy, in one place, so the park and the idle sweep cannot
    /// hold different opinions about which sources are judgeable. Both ask this
    /// question; they differ only in how much of the screen they pay for to get
    /// the answer.
    static func holderRefusal(forScreenSource source: TerminalScreen.Source) -> String? {
        switch source {
        case .daemon: return nil
        case .staleDaemon, .viewer: return holderViewerAttachedRefusal
        }
    }

    /// The typed screen the park's rail judges, or the refusal that stands in
    /// its place.
    ///
    /// One method so the two fail-closed halves and the projection failure are
    /// stated once and the park reads a single answer.
    func holderScreenReading(
        terminalID: UUID, registry: HolderRegistry
    ) async -> HolderScreenReading {
        let screen: TerminalScreen?
        do {
            screen = try await holderScreen(terminalID: terminalID, registry: registry)
        } catch {
            logger.error(
                """
                hibernate: could not project \(terminalID, privacy: .public)'s screen for the \
                pending-input rail: \(error.localizedDescription, privacy: .public)
                """)
            return .refused(Self.holderScreenProjectionRefusal)
        }
        guard let screen else { return .refused(Self.holderNoReaderRefusal) }
        if let refusal = Self.holderRefusal(forScreenSource: screen.source) {
            return .refused(refusal)
        }
        return .readable(screen)
    }

    /// Whether the screen the park's pending-input rail would have to judge is
    /// one this daemon may not judge — a viewer holds the pty, or no reader was
    /// ever adopted for the session.
    ///
    /// The same question `performHolderHibernate` asks before its fail-closed
    /// refusals, lifted out so the sweep can ask it *first*.
    /// `HibernationGate` is pure — it decides from the row, the config and the
    /// clock, and has no way to see who holds a pty — so the sweep is the only
    /// place with the registry in hand.
    ///
    /// **It reads the mode half of the oracle, not the whole screen.** `source`
    /// is one fact taken from one reader under one lock, and
    /// `HolderReader.modeReading` carries it without the whole-buffer walk that
    /// `screen(maxLines:)` pays for — the same trade the send path's oracle
    /// makes, and for the same reason: this runs on every sweep, for every idle
    /// holder row, and the walk holds the emulator lock a live session's drain
    /// thread needs. The two therefore agree on the question that decides the
    /// refusal. They can differ on exactly one thing, a screen that will not
    /// project at all: the sweep cannot foresee it, so such a row is armed here
    /// and refused at the park. That is a producer bug rather than a session
    /// state, and paying a request-and-refusal pair per sweep for one is better
    /// than hiding it.
    ///
    /// A daemon with no registry at all answers false: that is the tmux-only
    /// configuration, where a holder row is a leftover and the park's own
    /// no-registry refusal is the right place to say so once.
    func holderScreenIsUnreadable(terminalID: UUID) async -> Bool {
        guard let registry = holderRegistry else { return false }
        if let oracle = holderScreenOracle {
            do {
                guard let screen = try await oracle(terminalID) else { return true }
                return Self.holderRefusal(forScreenSource: screen.source) != nil
            } catch {
                // A refused projection, and the seam answers it the way the
                // production path below does rather than better: that path
                // reads only the source and never walks a line, so it cannot
                // see one. The sweep arms, the park refuses. A seam that
                // answered `true` here would make a test agree where the
                // shipped code does not.
                return false
            }
        }
        guard let reader = await registry.reader(for: terminalID) else { return true }
        let source = await reader.modeReading().source
        return Self.holderRefusal(forScreenSource: source) != nil
    }

    /// The screen this daemon holds for a session, or nil when it holds none.
    ///
    /// The test seam first, so a park can be driven against each source without
    /// a real holder, a real pty and a real attach; otherwise the registry's
    /// own reader, which is the single source the design names. Both throw only
    /// what `TerminalScreen`'s construction refuses.
    private func holderScreen(
        terminalID: UUID, registry: HolderRegistry
    ) async throws -> TerminalScreen? {
        if let holderScreenOracle {
            return try await holderScreenOracle(terminalID)
        }
        guard let reader = await registry.reader(for: terminalID) else { return nil }
        return try await reader.screen(maxLines: Self.holderScreenLines)
    }

    // MARK: - Park

    /// Park a holder-backed session: end the job its holder forked, then record
    /// the row as parked with no pids on it.
    ///
    /// Entered from `performHibernate` with `hibernatesInFlight` already
    /// claimed, and with NO tmux server lock — a holder session has no server,
    /// so there is nothing for a server lock to exclude. `hibernatesInFlight`
    /// is the whole exclusion here, and it is enough: every mutation below
    /// addresses one terminal row and one holder.
    func performHolderHibernate(
        terminal: Terminal,
        worktree: LocalWorktree,
        reason: HibernateReason,
        policy: HibernateEligibilityPolicy
    ) async -> HibernateResult {
        // Re-read and re-check, in the same order and with the same refusal
        // strings the tmux path uses under its server lock. This method is
        // actor-reentrant across the polite-exit poll below, so the row it
        // decided on must be the row it acts on.
        guard let currentTerminal = try? await db.terminals.get(id: terminal.id) else {
            return .notFound
        }
        guard TerminalReplacementSnapshot(terminal: terminal).matches(currentTerminal) else {
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return .notEligible(reason: "Terminal process changed before hibernation")
        }
        if case .automatic = policy,
           !TerminalHibernationSnapshot(terminal: terminal).matchesActivity(currentTerminal) {
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return .notEligible(reason: "Session activity changed before hibernation")
        }
        guard let sessionID = currentTerminal.claudeSessionID else {
            return .notEligible(reason: "No session id to resume later")
        }
        if let refusal = hibernationRefusal(terminal: currentTerminal, policy: policy) {
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return refusal
        }

        // Every refusal below clears `idleSince` and `pendingKillSince` like
        // every other refusal in this method. Each names a condition that will
        // still hold on the next sweep — no registry on this daemon, a viewer
        // that owns the pty until its tab closes, a session this daemon never
        // adopted, a screen whose projection is broken — so leaving the markers
        // armed would re-fire the identical refusal every pass. Clearing them
        // makes the row start its idle clock again from the moment the
        // condition clears.

        // No registry means no reader, no way to write `/exit`, and no way to
        // abandon the holder afterwards. Say so by name rather than parking a
        // row whose process nothing in this daemon can end.
        guard let registry = holderRegistry else {
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return .notEligible(reason: "this daemon has no holder registry")
        }

        // Rail: typed-but-unsent input, read off the typed screen oracle.
        // Fail-closed on every answer that is not a live daemon-rendered
        // screen — a source the daemon is not the live store for, no reader at
        // all, a projection that refused — because each one means the screen
        // this rail would judge is not the screen the session is showing. Each
        // answers with its own name: they differ in what the person reading the
        // refusal can do next.
        //
        // One dependency this rail has and cannot check: after a daemon restart
        // the emulator it reads is one that has seen only what arrived since
        // re-adoption, so what it shows of the composer is whatever the
        // attach-edge jiggle's repaint produced. The rail is relying on a real
        // geometry change forcing an Ink-style TUI to redraw its composer, and
        // so on a half-composed prompt being visible again. That is inferred
        // from how such TUIs redraw on `SIGWINCH`, not measured.
        let capturedSnapshot: String?
        switch await holderScreenReading(terminalID: terminal.id, registry: registry) {
        case .refused(let refusal):
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            logger.debug("hibernate: refusing \(terminal.id, privacy: .public) — \(refusal, privacy: .public)")
            return .notEligible(reason: refusal)
        case .readable(let screen):
            if HibernationSafetyChecks.hasPendingInput(paneCapture: screen.output) {
                logger.debug("hibernate: skipping \(terminal.id, privacy: .public) — pending typed input in prompt")
                return .notEligible(reason: "Terminal has unsent typed input")
            }
            capturedSnapshot = screen.output.isEmpty ? nil : screen.output
        }

        // The reader the polite `/exit` below is written through. Read after
        // the rail rather than inside it: the rail's subject is the screen, and
        // a reader that answered a live screen a moment ago is the one this
        // park writes to.
        guard let reader = await registry.reader(for: terminal.id) else {
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            logger.debug("hibernate: refusing \(terminal.id, privacy: .public) — the daemon holds no reader for this session")
            return .notEligible(reason: Self.holderNoReaderRefusal)
        }

        // Rail: transcript-tail validity, identical to the tmux path. Killing
        // mid-write can leave an unresumable jsonl.
        if let transcriptPath = currentTerminal.transcriptPath,
           let body = try? String(contentsOfFile: transcriptPath, encoding: .utf8),
           !HibernationSafetyChecks.isTranscriptTailValid(jsonlBody: body) {
            logger.warning("hibernate: skipping \(terminal.id, privacy: .public) — transcript tail not parseable, would be unresumable")
            return .notEligible(reason: "Transcript is mid-write; try again shortly")
        }

        // Park INTENT, before anything touches the process. A crash between
        // here and the finalize below leaves a parked row that still names its
        // pids, which `reconcileOnStartup` un-parks on the next start after
        // proving the child is alive.
        let expectedState = TerminalHibernationSnapshot(terminal: currentTerminal)
        let inertIncarnation: TerminalSessionIncarnation
        do {
            guard let prepared = try await db.terminals.beginHibernatedShellRespawn(
                id: terminal.id,
                expectedState: expectedState,
                snapshot: capturedSnapshot,
                reason: reason,
                at: now()) else {
                idleSince[terminal.id] = nil
                pendingKillSince[terminal.id] = nil
                return .notEligible(reason: "Terminal process changed before hibernation")
            }
            inertIncarnation = prepared
        } catch {
            logger.warning("hibernate: failed to prepare parked state for \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return .notEligible(reason: "Failed to persist hibernation")
        }

        let childPID = currentTerminal.childPID ?? 0
        // Rung 1 — polite park: `/exit` in band, so Claude flushes its
        // transcript, shuts down MCP children and fires Stop hooks. Written to
        // the pty the daemon is already reading — the same descriptor
        // `terminal.send` uses — rather than through tmux `send-keys`, which
        // addresses a pane this row has not got.
        //
        // A refused write is not a failure of the park; it is the reason the
        // ladder below exists. It is logged rather than swallowed because it
        // names the one thing the rungs after it cannot: that the session never
        // got the chance to shut itself down, so a `SIGTERM` it did not deserve
        // is about to arrive. `HolderReader.write` is all-or-nothing — it
        // either delivers the whole buffer within its budget or throws — so
        // there is no partial-write value to inspect here; if that ever becomes
        // a short count, it belongs in this same log line.
        do {
            try await reader.write(Data("/exit\r".utf8))
        } catch {
            logger.warning("hibernate: could not write the polite /exit for \(terminal.id, privacy: .public), so the escalation is what will end its job: \(error.localizedDescription, privacy: .public)")
        }
        var gone = await pollUntilChildIsGone(
            childPID: childPID, terminalID: terminal.id, registry: registry,
            attempts: exitPollAttempts)
        // Whether the holder has already been told to let go. Only the forced
        // rung does that, and only as part of killing the job; every other way
        // out of the ladder still owes the holder its `forget`.
        var abandoned = false

        if !gone {
            // Rung 2 — `SIGTERM` to the child, and to the child alone.
            //
            // The tmux ladder is `/exit` → Escape → C-c C-c → SIGTERM →
            // forced replacement, and this is the rung the holder park was
            // missing: without it a session whose Stop hooks or MCP teardown
            // outlast the three-second polite window went straight to a
            // `SIGKILL` of its process group, which is where a transcript gets
            // cut mid-write. `terminateProcessOnly` is deliberate — widening to
            // the group is the forced rung's job, and on a recycled pid
            // `getpgid` resolves to a stranger's group entirely.
            switch holderChildDisposition(childPID: childPID, terminal: currentTerminal) {
            case .gone:
                gone = true
            case .unverifiable(let verdict):
                return await refuseUnverifiableHolderChild(
                    currentTerminal, childPID: childPID, verdict: verdict, registry: registry)
            case .ours:
                logger.debug("hibernate: /exit did not end the job for \(terminal.id, privacy: .public) within the poll window — sending SIGTERM to child \(childPID, privacy: .public)")
                signaller.terminateProcessOnly(childPID)
                gone = await pollUntilChildIsGone(
                    childPID: childPID, terminalID: terminal.id, registry: registry,
                    attempts: holderTerminateAttempts)
            case .unrecorded:
                // Nothing to signal by pid, so this rung has nothing to do.
                // The forced rung still does: it reaches the holder over its
                // socket, which needs no pid at all.
                break
            }
        }

        if !gone {
            // Rung 3 — forced. `abandon` is the escalation: the holder is told
            // to let go (closing the pty master), the job is killed by process
            // group, and the holder's corpse is collected. Identity-checked
            // again rather than on the strength of the check above, because the
            // `SIGTERM` rung's own poll window sits between them and a pid
            // freed inside it is a pid the kernel may already have reissued.
            switch holderChildDisposition(childPID: childPID, terminal: currentTerminal) {
            case .gone:
                gone = true
            case .unverifiable(let verdict):
                return await refuseUnverifiableHolderChild(
                    currentTerminal, childPID: childPID, verdict: verdict, registry: registry)
            case .ours, .unrecorded:
                logger.debug("hibernate: SIGTERM did not end the job for \(terminal.id, privacy: .public) within the poll window — abandoning the holder")
                if let unfinished = await registry.abandon(terminal: currentTerminal) {
                    logger.warning("hibernate: holder teardown for \(terminal.id, privacy: .public) was incomplete: \(unfinished, privacy: .public)")
                }
                abandoned = true
                gone = await pollUntilChildIsGone(
                    childPID: childPID, terminalID: terminal.id, registry: registry,
                    attempts: holderEscalationAttempts)
            }
        }

        if gone, !abandoned {
            // The job ended without the forced rung, so the holder was never
            // told to let go — and a holder whose child has exited winds itself
            // down, which is a race this call does not need to win.
            await letHolderGoWithoutKilling(currentTerminal, registry: registry)
        }

        guard gone else {
            // THE invariant. The row must not claim parked over a process that
            // is still running: nothing would ever reclaim it, and a wake would
            // spawn a second agent onto the same session. Roll the intent back
            // — `clearHibernated` nils both park columns and the pending
            // incarnation — and report the pid so an operator can act.
            //
            // "Left awake" is the row's state, not the session's, and the
            // difference matters to whoever reads this. Reaching here means the
            // escalation already ran: the holder was torn down and the job was
            // signalled, so what is left is a child that survived `SIGKILL` or
            // could not be confirmed gone. Leaving the row awake is the only
            // honest record of that — it names live pids, so the reconcile arm
            // and the reaper's holder leg can both judge it — but it is not a
            // claim that the session is still usable.
            do {
                try await db.terminals.clearHibernated(id: terminal.id)
            } catch {
                logger.error("hibernate: the job for \(terminal.id, privacy: .public) survived and the park intent could not be rolled back: \(error.localizedDescription, privacy: .public)")
            }
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            logger.error("hibernate: holder child \(childPID, privacy: .public) for terminal \(terminal.id, privacy: .public) survived the escalation; its holder was torn down and the row is left awake for reconciliation to judge")
            return .notEligible(
                reason: "holder child \(childPID) survived the escalation; its holder was torn "
                    + "down and this session is left awake for reconciliation to judge")
        }

        // The transcript rail, asked a second time now that the child is gone.
        //
        // The first ask was before `/exit`, which is the only moment it can
        // stop a park; this one cannot and must not. The process is gone, and
        // the row parked is the truthful record of that — rolling back here
        // would leave an awake row over a session that no longer exists, which
        // is a worse lie than a transcript that needs repair. So it reports and
        // continues: a tail that was parseable before the shutdown and is not
        // parseable after it means the write was cut, and the resume that finds
        // it will need to know why.
        if let transcriptPath = currentTerminal.transcriptPath,
           let body = try? String(contentsOfFile: transcriptPath, encoding: .utf8),
           !HibernationSafetyChecks.isTranscriptTailValid(jsonlBody: body) {
            logger.warning("hibernate: the transcript for \(terminal.id, privacy: .public) is not parseable after its child exited — it may have been cut mid-write; parking anyway, because the process is gone")
        }

        do {
            guard try await db.terminals.finalizeHibernatedShellRespawn(
                id: terminal.id,
                expectedIncarnation: inertIncarnation,
                at: now()) != nil else {
                idleSince[terminal.id] = nil
                pendingKillSince[terminal.id] = nil
                return .notEligible(reason: "Terminal process changed during hibernation")
            }
        } catch {
            logger.warning("hibernate: failed to fence replaced agent for \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return .notEligible(reason: "Failed to finalize hibernation")
        }

        // A parked holder row names no processes. Leaving the pids on it would
        // point `AgentReaper`'s holder leg and every identity check at numbers
        // the kernel has already handed to somebody else.
        do {
            try await db.terminals.setHolderProcess(
                id: terminal.id, holderPID: nil, childPID: nil, startedAt: nil)
        } catch {
            logger.warning("hibernate: parked \(terminal.id, privacy: .public) but failed to clear its holder pids: \(error.localizedDescription, privacy: .public)")
        }
        inputActivity.forget(paneID: InputActivityTracker.key(for: currentTerminal))

        guard let persisted = try? await db.terminals.get(id: terminal.id),
              persisted.isParked else {
            logger.warning("hibernate: prepared row disappeared or changed during the holder park for \(terminal.id, privacy: .public)")
            idleSince[terminal.id] = nil
            pendingKillSince[terminal.id] = nil
            return .notEligible(reason: "Failed to verify hibernation")
        }
        idleSince[terminal.id] = nil
        pendingKillSince[terminal.id] = nil
        broadcastHibernation(
            terminal: currentTerminal, hibernated: true, keepWarm: currentTerminal.keepWarm,
            suspendedSnapshot: capturedSnapshot, hibernateReason: reason)
        logger.info("hibernated holder-backed terminal \(terminal.id, privacy: .public) in worktree \(worktree.id, privacy: .public) (session \(sessionID, privacy: .public))")
        return .ok
    }

    /// Poll `attempts` times, sleeping `exitPollInterval` on the injected clock
    /// between checks, for the holder's job to be gone.
    ///
    /// Two independent facts count as gone, because they answer from opposite
    /// ends. The process table says the pid names nothing, or names a corpse
    /// nobody has collected — a zombie is past its last instruction, and only
    /// its parent's `waitpid` is outstanding. And the holder itself may have
    /// already reported the exit, which is the one answer that survives a pid
    /// the kernel has already recycled.
    private func pollUntilChildIsGone(
        childPID: Int32, terminalID: UUID, registry: HolderRegistry, attempts: Int
    ) async -> Bool {
        for _ in 0..<max(0, attempts) {
            try? await clock.sleep(for: exitPollInterval)
            if await childIsGone(childPID: childPID, terminalID: terminalID, registry: registry) {
                return true
            }
        }
        return await childIsGone(
            childPID: childPID, terminalID: terminalID, registry: registry)
    }

    /// Whether the holder's job can be treated as gone.
    ///
    /// Two positive facts count as gone, and one silence deliberately does not.
    ///
    /// **A verdict must never rest on evidence the escalation itself erased.**
    /// `abandon(terminal:)` sets this session's remembered status back to nil,
    /// so the poll that runs *after* the escalation reads no status at all. On
    /// a row whose `child_pid` column is NULL there is then nothing else to
    /// read — the process table has no answer to give for a pid this daemon may
    /// not signal — and treating that silence as an exit is precisely how a row
    /// finalizes parked over a live child.
    ///
    /// **It answers "did our child exit", not "who holds this number now".**
    /// The second question is `holderChildDisposition`'s, and the two agree
    /// where they overlap: both read a `Z…` stat as gone, and neither lets a
    /// stranger on a recycled pid complete a park — this one because the
    /// stranger is alive, that one because it refuses to signal what it cannot
    /// identify. The full table is on `HolderChildDisposition`.
    ///
    /// So when the pid is unusable, only a POSITIVE `.exited` /
    /// `.exitedStatusUnknown` from the registry counts as gone; nil and
    /// `.alive` alike answer "not gone". The consequence is that a NULL-pid
    /// park rolls back after its escalation rather than completing, which is
    /// the safe direction: the row is left awake, where the reconcile arm and
    /// the reaper's holder leg can judge it. Every path that recorded a real
    /// child pid is unchanged, because the process table answers there.
    private func childIsGone(
        childPID: Int32, terminalID: UUID, registry: HolderRegistry
    ) async -> Bool {
        switch await registry.lastKnownStatus(for: terminalID) {
        case .exited, .exitedStatusUnknown: return true
        case .alive, nil: break
        }
        // Reaching here means the registry reported the job alive, or has
        // nothing to report because the escalation cleared what it knew.
        // Neither is evidence of an exit, and with no pid to check there is no
        // second source to ask.
        guard childPID > 1 else { return false }
        guard signaller.isAlive(childPID) else { return true }
        // `ps -o stat=` reports a corpse as `Z...`. It answers `kill(pid, 0)`,
        // so liveness alone cannot tell it from a running process — and the
        // distinction matters here: the job has finished, and the `waitpid`
        // still owed to it belongs to the holder, not to this park.
        return signaller.stat(childPID)?.hasPrefix("Z") ?? false
    }

    /// What the escalation ladder may do to this row's recorded child pid.
    ///
    /// Asked before every signal, and asked again between rungs, because the
    /// poll window between them is exactly long enough for a pid to be freed
    /// and reissued. The verdict-to-disposition mapping and the reasoning for
    /// each arm live on `HolderChildDisposition`.
    ///
    /// The anchor is the row's own `holderChildStartedAt`, falling back to
    /// `createdAt` for a row written before that column existed — the same pair
    /// the reaper's holder leg and the wake's adopt guard measure against, so a
    /// pid that passes here passes there.
    func holderChildDisposition(
        childPID: Int32, terminal: Terminal
    ) -> HolderChildDisposition {
        guard childPID > 1 else { return .unrecorded }
        // A corpse is gone, and it is asked about FIRST so this agrees with
        // `childIsGone`, which reads the same fact. It also has to come first
        // to be right: `ps` prints a zombie's command in parentheses, which the
        // executable check below would read as a stranger's — so a child that
        // exited a moment after the poll gave up would be refused as a foreign
        // process rather than recognized as the exit it is. A zombie is past
        // its last instruction and its number cannot be reissued while the
        // entry stands, so this is a positive answer either way: if some
        // stranger's corpse holds the number, our child left it long ago.
        if signaller.stat(childPID)?.hasPrefix("Z") == true { return .gone }
        let verdict = ProcessIdentityCheck.verify(
            pid: childPID,
            startedWithin: AgentReaper.defaultHolderIdentityWindow,
            of: terminal.holderChildStartedAt ?? terminal.createdAt,
            executableIsAcceptable: AgentReaper.isHolderChildExecutable,
            signaller: signaller)
        switch verdict {
        case .same: return .ours
        case .notRunning: return .gone
        case .startTimeUnreadable, .startTimeMismatch, .commandUnreadable, .foreignExecutable:
            return .unverifiable(verdict)
        }
    }

    /// Abandon a park whose child pid this daemon cannot prove is its own.
    ///
    /// "Keep when uncertain", spelled out on the park path: nothing is
    /// signalled — not the pid, not its group — because the process at that
    /// number may be a stranger's work on a machine running dozens of agent
    /// sessions, and a wrong kill there is unrecoverable while a refused park
    /// is not.
    ///
    /// The holder is still told to let go, without a kill. That is not a
    /// contradiction: the `forget` addresses the holder over its own socket and
    /// signals nothing, and leaving the daemon reading a pty whose job it can
    /// no longer identify would keep a reader alive over a session nobody can
    /// describe. What is left behind is a row that is awake and still names its
    /// pids — the state the reconcile arm and the reaper's holder leg are built
    /// to judge, both of which apply the same identity check and will keep for
    /// the same reason.
    private func refuseUnverifiableHolderChild(
        _ terminal: Terminal,
        childPID: Int32,
        verdict: ProcessIdentityVerdict,
        registry: HolderRegistry
    ) async -> HibernateResult {
        await letHolderGoWithoutKilling(terminal, registry: registry)
        do {
            try await db.terminals.clearHibernated(id: terminal.id)
        } catch {
            logger.error("hibernate: could not verify the child of \(terminal.id, privacy: .public) and could not roll the park intent back either: \(error.localizedDescription, privacy: .public)")
        }
        idleSince[terminal.id] = nil
        pendingKillSince[terminal.id] = nil
        logger.warning("hibernate: refusing to signal child \(childPID, privacy: .public) for terminal \(terminal.id, privacy: .public) — its identity is \(String(describing: verdict), privacy: .public); the row is left awake with its pids intact")
        return .notEligible(
            reason: "the process holding child pid \(childPID) could not be verified as this "
                + "session's own (\(verdict)), so nothing was signalled and this session is "
                + "left awake")
    }

    /// Tell the holder to let go of the pty without killing anything.
    ///
    /// `childPID: 0` is the sentinel `dispose` refuses to signal, and that is
    /// the point on both paths that reach here: after a confirmed exit the
    /// recorded pid is free and the next process to take that number is
    /// somebody else's, and after an unverifiable identity the number was never
    /// ours to signal in the first place.
    private func letHolderGoWithoutKilling(
        _ terminal: Terminal, registry: HolderRegistry
    ) async {
        do {
            let socketPath = try HolderRendezvous.socketPath(
                sessionID: terminal.id, environment: registry.environment)
            await registry.abandon(
                terminalID: terminal.id,
                handle: HolderHandle(
                    holderPID: terminal.holderPID ?? 0,
                    childPID: 0,
                    socketPath: socketPath))
        } catch {
            // The processes are not the concern: nothing here was going to be
            // signalled anyway. What does outlive this call is bookkeeping
            // `abandon` would have cleared — this session's registry slot and
            // its remembered status — and the collector for that is
            // `reclaimIfSessionEnded`, which the reader's end-of-output
            // notifier fires once the drain runs dry.
            //
            // Worth naming rather than glossing: that reclaimer derives the
            // SAME rendezvous path, and the only thing that makes this throw is
            // a path over `sun_path` — a persistent fact about this install's
            // `TBD_HOME` and this session's id, not a transient. So the pairing
            // is real but not a guarantee here; it is also the reason this
            // branch is close to unreachable, since a session whose path cannot
            // be represented could neither have been spawned nor adopted by
            // this daemon.
            logger.warning("hibernate: could not derive the rendezvous path for \(terminal.id, privacy: .public), so its holder was not told to let go: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Startup reconciliation

    /// Reconcile one PARKED holder row against the process table.
    ///
    /// **It must not consult the registry, and that is a startup-ordering
    /// fact rather than a preference**: `reconcileOnStartup` runs before
    /// `HolderRegistry.adoptAll`, so at this moment the registry holds no
    /// readers and knows no statuses — asking it would answer "gone" for every
    /// session on the machine and un-park nothing while looking authoritative.
    /// The recorded child pid is the only ground truth available this early,
    /// read through the same `ProcessIdentityCheck` the reaper's holder leg
    /// consults.
    ///
    /// Two verdicts move the row and every other one leaves it alone:
    ///
    /// - `.same` — the daemon died mid-park, after the intent was written and
    ///   before the child was confirmed gone. The child is alive and is this
    ///   row's; un-park it, and adoption will pick the session up moments later.
    ///   The tmux recovery in the same method has exactly this shape.
    /// - `.notRunning` — the child is gone but the row still names it. Clear the
    ///   pids so nothing later signals a number the kernel has recycled.
    ///
    /// Everything else — an unreadable start time, a mismatch, a foreign
    /// executable — is an uncertain identity, and an uncertain identity is not
    /// evidence in either direction.
    ///
    /// **It is deliberately ungated, and that is not an oversight.**
    /// `holder_hibernation_enabled` decides whether a row may be parked; this
    /// arm judges rows that already are, including the ones the soak parked
    /// before the flag was turned off. Gating it would make turning the flag
    /// off strand exactly the rows an abort most needs healed. Both of its
    /// mutations are safety-only in the direction a disabled feature wants:
    /// one un-parks a row over a child that is verifiably alive, the other
    /// clears pids that verifiably name nothing. Neither ends a process,
    /// neither parks anything, and neither can be undone into a worse state
    /// than the row was already in.
    func reconcileParkedHolderRow(_ terminal: Terminal) async {
        guard let childPID = terminal.childPID, childPID > 1 else { return }
        let verdict = ProcessIdentityCheck.verify(
            pid: childPID,
            startedWithin: AgentReaper.defaultHolderIdentityWindow,
            of: terminal.holderChildStartedAt ?? terminal.createdAt,
            executableIsAcceptable: AgentReaper.isHolderChildExecutable,
            signaller: signaller)
        switch verdict {
        case .same:
            do {
                try await db.terminals.clearHibernated(id: terminal.id)
                logger.info("startup: holder-backed terminal \(terminal.id, privacy: .public) was parked while its child \(childPID, privacy: .public) was still running — un-parking; adoption will pick it up")
            } catch {
                logger.warning("startup: failed to un-park holder-backed terminal \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        case .notRunning:
            do {
                try await db.terminals.setHolderProcess(
                    id: terminal.id, holderPID: nil, childPID: nil, startedAt: nil)
                logger.info("startup: cleared the stale holder pids on parked terminal \(terminal.id, privacy: .public) — its recorded child \(childPID, privacy: .public) is gone")
            } catch {
                logger.warning("startup: failed to clear the stale holder pids on \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        case .startTimeUnreadable, .startTimeMismatch, .commandUnreadable, .foreignExecutable:
            logger.debug("startup: leaving parked holder-backed terminal \(terminal.id, privacy: .public) alone — child identity is uncertain (\(String(describing: verdict), privacy: .public))")
        }
    }

    // MARK: - Wake

    /// What a wake aimed at an UNPARKED holder row should answer.
    ///
    /// The tmux answer to this question probes a pane; a holder row has none.
    /// The equivalent evidence is the recorded child pid, read through the same
    /// `ProcessIdentityCheck` the reaper's holder leg consults before it
    /// signals anything — so a pid the kernel has recycled is recognized here
    /// the same way it is there.
    ///
    /// Only `.notRunning` downgrades the answer. Every other verdict is an
    /// uncertain identity, and an uncertain identity is not evidence that a
    /// session died — the same asymmetry the tmux classification applies to a
    /// probe that merely threw. Like it, this reports and does not repair.
    func classifyUnparkedHolderWake(_ terminal: Terminal) async -> WakeResult {
        guard let childPID = terminal.childPID, childPID > 1 else { return .notHibernated }
        let verdict = ProcessIdentityCheck.verify(
            pid: childPID,
            startedWithin: AgentReaper.defaultHolderIdentityWindow,
            of: terminal.holderChildStartedAt ?? terminal.createdAt,
            executableIsAcceptable: AgentReaper.isHolderChildExecutable,
            signaller: signaller)
        guard verdict == .notRunning else { return .notHibernated }
        logger.warning("""
            wake: terminal \(terminal.id, privacy: .public) is unparked but the job its \
            holder forked (pid \(childPID, privacy: .public)) is gone — reporting sessionGone \
            instead of "already awake"
            """)
        // No pane id to name, and the empty string is what the row carries.
        // `RPCRouter.unparkedWakeMessage` phrases an empty one as "its
        // holder-backed session" rather than as a pane that does not exist.
        return .sessionGone(paneID: "", detail: .processExited)
    }

    /// The mutate half of a holder wake: spawn a fresh holder running the
    /// resume command, record what it started, then un-park the row.
    ///
    /// The ordering is the same one `WorktreeLifecycle+Create` uses and for the
    /// same reason: the pids are persisted BEFORE the row stops being parked,
    /// so a failure in between leaves a parked row that names live processes —
    /// which `reconcileOnStartup` un-parks — rather than an awake row that
    /// names nothing, which nothing would ever reconcile. Both orders can fail
    /// in the middle; only this one fails into a state something owns.
    ///
    /// **What makes that order converge rather than compound is the adopt
    /// guard below.** Without it, the window between the pid write and the
    /// cleared park marker is not merely untidy, it multiplies: the row still
    /// reads parked, so the app's next focus-wake re-enters this method,
    /// `registry.spawn` runs unconditionally, `setHolderProcess` overwrites the
    /// pids with a third generation, and the second generation — live, and no
    /// longer named by any row — is beyond every reconciler, because the
    /// reaper's holder leg sweeps by the pids a row carries. Healing the row
    /// instead means the retry that used to widen the damage is now what
    /// repairs it, and `reconcileOnStartup` stops being the only cure.
    func wakeHolderSection(
        terminal: Terminal,
        worktree: LocalWorktree,
        sessionID: String,
        expectedReplacementState: TerminalReplacementSnapshot,
        spawnCommand: String,
        env: [String: String],
        sensitiveEnv: [String: String],
        cols: Int?,
        rows: Int?
    ) async -> WakeResult {
        guard let registry = holderRegistry else {
            return .respawnFailed(
                reason: "this daemon has no holder registry, so the session cannot be resumed on the pty-holder transport")
        }

        guard let currentTerminal = try? await db.terminals.get(id: terminal.id),
              expectedReplacementState.matches(currentTerminal) else {
            return .respawnFailed(reason: "terminal changed while wake was preparing; retry")
        }

        // The row said parked, but its holder may already be running — an
        // earlier wake of this same row that got as far as the pids. Heal it
        // rather than starting a second one.
        if let adopted = await adoptLiveHolderInsteadOfRespawning(
            currentTerminal, registry: registry) {
            return adopted
        }

        // "Registry present" is not "can spawn": a daemon whose `TBDHolder`
        // binary has moved still builds a registry, because adoption of a
        // running holder needs no executable. Only this fact may gate a spawn.
        //
        // Asked here rather than at the top of the method because it gates a
        // SPAWN, and the branch above does not spawn: a daemon whose helper has
        // moved can still un-park a row over the holder it already adopted, and
        // refusing that would strand exactly the row this method just proved is
        // healthy. Everything between here and the guard is read-only, so
        // moving the question down costs the refusal nothing.
        guard registry.canSpawn else {
            return .respawnFailed(
                reason: "the TBDHolder helper is missing beside the daemon, so no holder can be started for this session; the row stays parked")
        }

        let incarnationID: UUID
        do {
            guard let prepared = try await db.terminals.prepareHibernatedAgentRespawn(
                id: terminal.id,
                expectedState: expectedReplacementState,
                at: now()) else {
                return .respawnFailed(reason: "terminal changed before wake could launch; retry")
            }
            incarnationID = prepared
        } catch {
            logger.warning("wake: failed to prepare the replacement agent for \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .respawnFailed(
                reason: "preparing the replacement agent failed: \(error.localizedDescription)")
        }
        let replacementEnv = AgentProcessEnvironment.replacement(
            base: env, incarnationID: incarnationID)

        let handle: HolderHandle
        do {
            handle = try await registry.spawn(
                terminalID: terminal.id,
                launch: WorktreeLifecycle.holderLaunch(
                    shellCommand: spawnCommand,
                    env: replacementEnv,
                    sensitiveEnv: sensitiveEnv,
                    workingDirectory: worktree.path,
                    cols: cols ?? TmuxManager.defaultCols,
                    rows: rows ?? TmuxManager.defaultRows,
                    environment: registry.environment))
        } catch {
            // The row stays parked, so the next focus or menu retry can wake it.
            logger.warning("wake: could not start a holder for \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .respawnFailed(
                reason: "starting a holder for this session failed: \(error.localizedDescription)")
        }

        do {
            try await db.terminals.setHolderProcess(
                id: terminal.id,
                holderPID: handle.holderPID,
                childPID: handle.childPID,
                startedAt: now())
        } catch {
            // A holder and a job no row names would be reclaimable by nothing,
            // so undo the spawn from the failing call itself.
            await registry.abandon(terminalID: terminal.id, handle: handle)
            logger.warning("wake: started a holder for \(terminal.id, privacy: .public) but could not record its pids, so it was abandoned: \(error.localizedDescription, privacy: .public)")
            return .respawnFailed(
                reason: "the replacement agent started, but recording its process ids failed: \(error.localizedDescription)")
        }

        do {
            try await db.terminals.clearHibernated(id: terminal.id)
        } catch {
            // Keep the live replacement parked. The row names live pids, and
            // startup reconciliation clears the marker off a parked row whose
            // child is identity-verified alive.
            logger.error("wake: launched the replacement agent for \(terminal.id, privacy: .public), but failed to clear its parked marker: \(error.localizedDescription, privacy: .public)")
            return .respawnFailed(
                reason: "replacement agent launched, but clearing the parked marker failed: \(error.localizedDescription)")
        }

        idleSince[terminal.id] = nil
        // Empty tmux coordinates, because that is what a holder row carries and
        // what the app's cached row must keep: a non-empty pair here would send
        // the terminal view looking for a window that does not exist.
        broadcastHibernation(
            terminal: currentTerminal, hibernated: false, keepWarm: currentTerminal.keepWarm,
            tmuxWindowID: "", tmuxPaneID: "")
        // No `SessionRecaptureScheduler`: it re-reads the session id off a tmux
        // pane's screen, and this row has no pane. A holder session's resumed
        // id is recaptured the way every other fact about it is — from hooks.
        logger.info("woke holder-backed terminal \(terminal.id, privacy: .public) (resume \(sessionID, privacy: .public), holder \(handle.holderPID, privacy: .public), child \(handle.childPID, privacy: .public))")
        // The incarnation this wake minted for the replacement agent, the same
        // fact the tmux arm reports: it is what scopes a caller's wait to the
        // session THIS call started rather than to whatever starts next.
        return .ok(sessionIncarnationID: incarnationID)
    }

    /// Un-park a parked row whose holder is already running, or answer nil so
    /// the wake spawns as usual.
    ///
    /// The state this recognizes is a wake that half-finished: `setHolderProcess`
    /// landed and `clearHibernated` did not, so the row names a live holder and
    /// a live child while still claiming parked. `reconcileOnStartup` heals it,
    /// but only at the next daemon start, and the periodic reconcile sweep skips
    /// parked rows by design — so between those two events every retry used to
    /// spawn again and abandon the generation before it.
    ///
    /// Two independent facts count as "already running", because they answer
    /// from opposite ends and either one alone is enough:
    ///
    /// - **The registry still holds a reader for the session.** That means this
    ///   daemon is draining that session's pty right now — whichever daemon
    ///   started the holder, since `adoptAll` adopts rows this one never
    ///   spawned — which is first-hand evidence that the holder is alive rather
    ///   than an inference about a number. A re-adopted row may carry no pids
    ///   at all, so this leg restores them from what the registry itself
    ///   observed before the park marker is cleared; that is what
    ///   `restoreHolderPIDsFromRegistry` is doing here. It is also what makes
    ///   this a guard rather than a nicety: `HolderRegistry.spawn` refuses a
    ///   session that already occupies a slot (`sessionAlreadyRegistered`), so
    ///   without the guard the retry's spawn throws and the row stays parked
    ///   forever — the guard is what turns that throw into a heal.
    /// - **The recorded child pid is identity-verified alive**, through the same
    ///   `ProcessIdentityCheck` the reaper's holder leg consults before it
    ///   signals anything: alive, started within
    ///   `AgentReaper.defaultHolderIdentityWindow` of the row's recorded child
    ///   start, and running an executable a holder's job could be. A pid the
    ///   kernel has recycled fails it exactly as it fails there.
    ///
    /// **What the second leg is actually for**, since the obvious answer is
    /// wrong: it is not "a daemon restart, where no reader exists". `adoptAll`
    /// filters on transport alone and adopts parked rows too, so after a
    /// restart such a session normally *does* get a reader and the first leg
    /// fires. The second leg is what is left when adoption itself failed — a
    /// holder that would not answer the hand-over — and the recorded pid is
    /// nonetheless certain. When identity is uncertain as well, this returns
    /// nil, the wake proceeds to `registry.spawn`, and the holder's creation
    /// lock refuses a second holder for a session that already has one: the row
    /// then stays parked until that holder dies. Fail-safe, in that no second
    /// agent is ever started, but the outcome is a session stuck parked, and it
    /// is named here rather than left to be rediscovered.
    ///
    /// Every other verdict — `.notRunning`, an unreadable start time or command
    /// line, a mismatch, a foreign executable — returns nil and lets the spawn
    /// proceed. That is the safe direction on this side: an uncertain identity
    /// must not silently un-park a row over a session nobody is running, and a
    /// spawn that turns out to be unnecessary is refused by the registry rather
    /// than duplicated.
    private func adoptLiveHolderInsteadOfRespawning(
        _ terminal: Terminal, registry: HolderRegistry
    ) async -> WakeResult? {
        let evidence: String
        if await registry.reader(for: terminal.id) != nil {
            evidence = "this daemon is still reading its holder"
            // Before the row stops being parked, and this is the ordering that
            // matters: a row un-parked without pids on it is invisible to every
            // reclaimer this transport has, all of which sweep by the numbers a
            // row carries.
            await restoreHolderPIDsFromRegistry(terminal, registry: registry)
        } else if let childPID = terminal.childPID, childPID > 1,
                  ProcessIdentityCheck.verify(
                    pid: childPID,
                    startedWithin: AgentReaper.defaultHolderIdentityWindow,
                    of: terminal.holderChildStartedAt ?? terminal.createdAt,
                    executableIsAcceptable: AgentReaper.isHolderChildExecutable,
                    signaller: signaller) == .same {
            evidence = "its recorded child \(childPID) is identity-verified alive"
        } else {
            return nil
        }

        do {
            try await db.terminals.clearHibernated(id: terminal.id)
        } catch {
            // Nothing was started and nothing is abandoned: the row is exactly
            // as it was, still parked over its own live holder, and the next
            // retry or the next daemon start reaches this same branch again.
            logger.error("wake: \(terminal.id, privacy: .public) is parked over a holder that is already running, but the parked marker could not be cleared: \(error.localizedDescription, privacy: .public)")
            return .respawnFailed(
                reason: "this session's holder is already running, but clearing its parked "
                    + "marker failed: \(error.localizedDescription)")
        }

        idleSince[terminal.id] = nil
        // The same empty tmux coordinates the spawn path broadcasts, for the
        // same reason: a holder row carries none, and a non-empty pair would
        // send the terminal view looking for a window that does not exist.
        broadcastHibernation(
            terminal: terminal, hibernated: false, keepWarm: terminal.keepWarm,
            tmuxWindowID: "", tmuxPaneID: "")
        logger.info("wake: adopted the holder already running for \(terminal.id, privacy: .public) instead of spawning a second one — \(evidence, privacy: .public); the row was parked over it")
        // No incarnation: adopting a holder that was already running spawns
        // nothing, so there is no new session for a caller's wait to scope to.
        return .ok(sessionIncarnationID: nil)
    }

    /// Put the registry's own view of a session's processes back onto its row.
    ///
    /// The state this repairs is narrow and real: `HolderRegistry.spawn`
    /// publishes its reader before `wakeHolderSection` persists the pids, and a
    /// daemon that dies in that window — SIGKILL, OOM, a panic; not a thrown
    /// error, which the spawn path already undoes itself — leaves a parked row
    /// naming no processes behind a holder that is alive. `reconcileParkedHolderRow`
    /// cannot repair it, because it has no pid to verify. `adoptAll` re-adopts
    /// the holder regardless, so the next wake reaches the reader leg above and
    /// would un-park the row with no pid on it — and from then on the reaper's
    /// holder leg, the startup arm, and any later park's own escalation are all
    /// blind to that session, permanently.
    ///
    /// The registry is the right source precisely because it is first-hand: the
    /// child pid comes from the hand-over that produced the live reader, and
    /// the holder pid from the socket that carried it. A registry that answers
    /// nothing is logged and left alone rather than guessed at — this runs
    /// under a live reader, so it should always answer, and inventing a pid
    /// would be worse than recording none.
    ///
    /// The start time is the identity anchor every reclaimer measures that pid
    /// against, so it is taken from the most trustworthy source available and
    /// the log says which one: the row's own value when it still describes this
    /// child, else the kernel's start time for the pid, else the current time —
    /// which is a fallback rather than a fact, and is honest in the direction
    /// that matters, since a wrong anchor makes the identity check refuse to
    /// signal rather than signal wrongly.
    private func restoreHolderPIDsFromRegistry(
        _ terminal: Terminal, registry: HolderRegistry
    ) async {
        guard let observed = await registry.adoptedProcess(for: terminal.id) else {
            logger.warning("wake: \(terminal.id, privacy: .public) is parked over a holder this daemon is reading, but the registry names no processes for it, so the row's pids cannot be repaired")
            return
        }
        // A holder pid the kernel would not name is recorded as nil rather than
        // faked. Nothing needs it: the child pid is the anchor every reclaimer
        // sweeps by, `HolderRegistry.abandon(terminal:)` reaches the holder over
        // its socket, and `AgentReaper.decideHolderChild` keeps — never kills —
        // when the holder pid is missing.
        let holderPID = observed.holderPID ?? terminal.holderPID
        let startedAt: Date
        let anchorSource: String
        if let recorded = terminal.holderChildStartedAt, terminal.childPID == observed.childPID {
            startedAt = recorded
            anchorSource = "the row's own recorded start"
        } else if let measured = signaller.startTime(observed.childPID) {
            startedAt = measured
            anchorSource = "the kernel's start time for the child"
        } else {
            startedAt = now()
            anchorSource = "this moment, because the kernel would not say when the child started"
        }
        guard terminal.childPID != observed.childPID
                || terminal.holderPID != holderPID
                || terminal.holderChildStartedAt != startedAt else { return }
        do {
            try await db.terminals.setHolderProcess(
                id: terminal.id, holderPID: holderPID, childPID: observed.childPID,
                startedAt: startedAt)
            // Hoisted rather than folded into the interpolation: `0` here is
            // "the kernel would not name the holder", not a pid.
            let loggedHolderPID = holderPID ?? 0
            logger.info("wake: restored the holder pids on \(terminal.id, privacy: .public) from the registry — holder \(loggedHolderPID, privacy: .public), child \(observed.childPID, privacy: .public), anchored on \(anchorSource, privacy: .public)")
        } catch {
            // The un-park below still proceeds. A row that is awake and pid-less
            // is the state this method exists to prevent, but refusing the wake
            // over it would leave the session parked over a holder that is
            // already running — which nothing else repairs either, and which the
            // user cannot get out of.
            logger.error("wake: could not restore the holder pids on \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
