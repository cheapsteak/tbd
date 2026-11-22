import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "LeftoverTmux")

/// The two facts every caller that meets a live tmux row needs: whether its
/// tmux server is still running, and, once it is gone, the park that keeps the
/// session's identity.
///
/// Reconcile, `terminal.recreateWindow` (the app's Check Again) and the
/// transport migration each reach a live tmux row and each act on the same
/// answer, so the answer is read here, once. See `LeftoverTmuxServerProbe`,
/// which is a transition measure with a replacement date.
extension WorktreeLifecycle {
    /// The tmux server `terminal`'s worktree names, and what the probe
    /// says about it. Nil when the worktree row could not be read, so there is
    /// no server to name; a caller treats that as knowing nothing and touches
    /// nothing.
    func leftoverTmuxServerSighting(for terminal: Terminal) async -> LeftoverTmuxServerSighting? {
        let worktree: LocalWorktree?
        do {
            worktree = try await db.worktrees.getLocal(id: terminal.worktreeID)
        } catch {
            logger.warning("could not read worktree \(terminal.worktreeID, privacy: .public) of tmux terminal \(terminal.id, privacy: .public) to name its tmux server: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let server = worktree?.tmuxServer else { return nil }
        return LeftoverTmuxServerSighting(
            server: server, state: await leftoverTmuxProbe.state(server))
    }

    /// Park a live tmux row whose server the probe found gone, keeping the
    /// identity a wake resumes from — the Claude session id and transcript, or
    /// the Codex thread id and launch options — and say what happened.
    ///
    /// A compare-and-set against the row as the caller read it, in two halves:
    /// the park, then the fence on the process token the ended agent held.
    /// Nothing is stopped: the server is gone, and every process it ran went
    /// with it. The reason is `.recovery`, the same reason reconcile's park of
    /// a session nothing can reach records.
    ///
    /// A row closed before either half is `.closed`, not an error: a tab
    /// closed while the probe ran is an ordinary race, and the park has
    /// nothing left to keep. When a half fails, the row is read again to tell
    /// a close or a wake from a real failure; a failure is thrown as the half
    /// raised it, also when that second read fails.
    func parkLeftoverTmuxRow(_ terminal: Terminal) async throws -> LeftoverTmuxParkOutcome {
        guard terminal.transport == .tmux, !terminal.isParked,
              terminal.recoveryResumePlan != nil else {
            return .leftAlone
        }
        let incarnation: TerminalSessionIncarnation?
        do {
            incarnation = try await db.terminals.beginHibernatedShellRespawn(
                id: terminal.id,
                expectedState: TerminalHibernationSnapshot(terminal: terminal),
                reason: .recovery,
                at: now())
        } catch let parkError {
            guard try await rowAfterFailedHalf(terminal.id, failure: parkError) == nil else {
                throw parkError
            }
            logger.info("leftover tmux park: terminal \(terminal.id, privacy: .public) was closed before it could be parked")
            return .closed
        }
        guard let incarnation else {
            logger.info("leftover tmux park: terminal \(terminal.id, privacy: .public) changed before it could be parked; left as it is")
            return .leftAlone
        }
        await leftoverParkBetweenHalvesForTesting?(terminal.id)
        let fenced: UUID?
        do {
            fenced = try await db.terminals.finalizeHibernatedShellRespawn(
                id: terminal.id, expectedIncarnation: incarnation, at: now())
        } catch let fenceError {
            // Closed between the halves, or woken between them, which leaves
            // a row that is no longer parked for the fence to finish.
            guard let current = try await rowAfterFailedHalf(terminal.id, failure: fenceError) else {
                logger.info("leftover tmux park: terminal \(terminal.id, privacy: .public) was closed while it was being parked")
                return .closed
            }
            guard current.isParked else {
                logger.info("leftover tmux park: terminal \(terminal.id, privacy: .public) was parked and then woken before the park finished; left as the wake made it")
                return .superseded
            }
            throw fenceError
        }
        guard fenced != nil else {
            logger.info("leftover tmux park: terminal \(terminal.id, privacy: .public) was parked and then changed before the park finished; left as that change made it")
            return .superseded
        }
        await pendingQuestions.clear(terminalID: terminal.id)
        await subscriptions?.broadcastPendingPrompts(
            terminalID: terminal.id, from: pendingQuestions)
        logger.notice("leftover tmux park: parked terminal \(terminal.id, privacy: .public) — its tmux server is gone; session preserved, a person's wake moves it to the pty holder")
        // The park is written, so a read back that fails reports a park, not
        // a failure, and not a tab that is gone.
        do {
            return .parked(try await db.terminals.get(id: terminal.id))
        } catch {
            logger.warning("leftover tmux park: parked terminal \(terminal.id, privacy: .public), but could not read it back: \(error.localizedDescription, privacy: .public)")
            return .parkedUnreadable(error: String(describing: error))
        }
    }

    /// The row as it reads after one of the park's halves threw `failure`, nil
    /// when it is gone. A read that itself fails throws `failure`, not its own
    /// error: the half's failure is the one the caller has to see.
    private func rowAfterFailedHalf(_ id: UUID, failure: any Error) async throws -> Terminal? {
        do {
            return try await db.terminals.get(id: id)
        } catch {
            throw failure
        }
    }

    /// The tmux half of every teardown that deletes a tmux row: closing its
    /// tab (`terminal.delete`, and `server.stop`'s tab close), archiving its
    /// worktree, reconcile's archive of a vanished worktree, closing a hook
    /// tab, tearing down a scratch space and forgetting a worktree. It runs no
    /// tmux command, and the caller deletes the row afterwards unless it
    /// throws.
    ///
    /// **A live row's session keeps running.** So may the session of a row
    /// parked with its park still in flight (`pendingSessionIncarnationID`
    /// set): an earlier build's tmux hibernate signalled the agent and left
    /// the row so when its respawn failed, and the agent may not have exited.
    /// Both are closed as live rows. The tmux server may still be running a
    /// session an earlier build started there, and TBD can neither reach nor
    /// stop it, so deleting the row leaves that session running. The close
    /// goes ahead regardless: refusing it would leave a tab TBD can neither
    /// show nor end with no way to close it. What the daemon does is
    /// say so, at `.notice`, with the command that ends the server, and keep
    /// the session in the record: a row with a session id gets a Closed
    /// Terminals entry with no screen, marked with the server
    /// (`TerminalHistoryStore.recordLiveTmuxClose`). Every resume of that
    /// session id asks about the mark first (`TmuxResumeGate`), so the entry
    /// brings the session back on the pty holder once the server is gone, and
    /// never while it may still be running it. A row with no session id has
    /// nothing to resume and no screen to keep, so it gets no entry.
    ///
    /// **A parked row's entry comes from the row** when its park is complete
    /// (`WorktreeLifecycle.sessionHasEnded`). Its agent was ended when it was
    /// parked, and the screen the park saved, `suspendedSnapshot`, is what its
    /// Closed Terminals entry keeps, with its session id.
    ///
    /// Either entry is written only when `history` is given: the hard-delete
    /// paths (forget, scratch delete) remove the worktree's history right
    /// after, and with it every session that could be resumed from there.
    ///
    /// **A mark that cannot be written keeps the row.** Once the row is
    /// deleted the mark is the only record that its session may still be
    /// running, so a failed write throws `LeftoverTmuxMarkUnwritable` and the
    /// caller keeps the row, which names the session to the resume gate as
    /// the mark would (`TerminalStore.liveTmuxServers`). Closing the tab
    /// fails and says why; an archive of its worktree, repo worktree or
    /// scratch space, is refused with the worktree, its sessions and every
    /// row as they were, keeping the entries already written for the tmux
    /// rows closed ahead of it (`beginArchiveWorktree`); reconcile's archive
    /// leaves the worktree for its next sweep; a hook tab's close keeps the
    /// tab. The notice is logged only once the mark is written. A
    /// parked row's entry carries no mark, so a failure to write it is logged
    /// and the close goes ahead, as any other close's is.
    ///
    /// **An unknown server leaves nothing to keep.** A row the caller has no
    /// local worktree row for, because the worktree is gone or remote, names
    /// no server, so neither record could ever be asked about its session:
    /// the gate's open-row lookup reads the server from the row's worktree,
    /// and a mark is a server to probe. A kept row would guard nothing and
    /// leave a tab nobody could close, and a mark that always refused would
    /// bar the session for good on evidence that names no server. So the
    /// close goes ahead with the notice and no entry; the one caller that
    /// passes no server passes no `history` either.
    ///
    /// - Parameter server: the tmux server the row's worktree names, nil when
    ///   the caller has no local worktree row for it.
    static func closeLeftoverTmuxRow(
        _ terminal: Terminal, server: String?, history: TerminalHistoryStore?
    ) async throws {
        if sessionHasEnded(terminal, teardownStoppedIt: false) {
            if let history {
                await history.recordOnClose(terminal: terminal, capture: terminal.suspendedSnapshot)
            }
            return
        }
        guard let server else {
            logger.notice("closed terminal \(terminal.id, privacy: .public) on tmux without running tmux; there is no local worktree row for it, gone or remote, so its tmux server is unknown, and its session may still be running there")
            return
        }
        if let history, terminal.claudeSessionID != nil {
            do {
                try await history.recordLiveTmuxClose(terminal: terminal, server: server)
            } catch {
                logger.error("keeping terminal \(terminal.id, privacy: .public) on tmux: its session may still be running in tmux server \(server, privacy: .public), and its Closed Terminals entry could not be marked with it: \(error.localizedDescription, privacy: .public)")
                throw LeftoverTmuxMarkUnwritable(
                    terminalID: terminal.id, server: server,
                    reason: error.localizedDescription)
            }
        }
        logger.notice("closed terminal \(terminal.id, privacy: .public) on tmux without running tmux; its session may still be running in tmux server \(server, privacy: .public). \(LeftoverTmuxSession.endingAdvice(server: server), privacy: .public)")
    }

    /// The resume gate (`TmuxResumeGate`) over this lifecycle's records and
    /// probe: the refusal when one of `sessionIDs` is carried by a tmux row
    /// whose session may still run, or was carried by a live tmux row TBD
    /// deleted, and that row's tmux server may still be running it, or when
    /// `worktreeServer`, a revived worktree's own server, may still be
    /// running; nil otherwise, and nil without a probe when `sessionIDs` is
    /// empty.
    func tmuxResumeRefusal(
        resuming sessionIDs: [String], worktreeServer: String? = nil
    ) async throws -> TmuxResumeRefusal? {
        try await TmuxResumeGate(
            history: db.terminalHistory, terminals: db.terminals, probe: leftoverTmuxProbe
        ).refusal(resuming: sessionIDs, worktreeServer: worktreeServer)
    }
}

/// The one question every start of an existing session on the pty holder
/// asks first: may that session still be running in a tmux server an earlier
/// build started?
///
/// Two records name such a session. A tmux row carries it, in its worktree's
/// tmux server, while the row is unparked: the row's tab shows that the
/// session is still on tmux, but the History pane's session list offers the
/// same session id, and resuming it there starts it beside the tmux agent. A
/// parked tmux row carries it too while its park is in flight
/// (`pendingSessionIncarnationID` set): an earlier build's tmux hibernate
/// recorded the park and signalled the agent, and left the row so when its
/// respawn failed, with the agent perhaps still running. And TBD deletes a
/// live tmux row without running tmux
/// (`WorktreeLifecycle.closeLeftoverTmuxRow`): closing its tab, archiving its
/// worktree, reconcile's archive of a worktree whose checkout is gone. The
/// session the row carried may keep running in that server, and the row's
/// Closed Terminals entry records the server
/// (`TerminalHistoryEntry.liveOnTmuxServer`). A start of the same session id
/// anywhere else would put a second agent on it while the first still runs: a
/// revive that relaunches the worktree's archived tabs, a History pane
/// resume, a Closed Terminals reopen, a fresh-branch revive of a Codex
/// thread, a wake of another tab on that session. So each asks this first,
/// keyed by the session ids it would start, and is refused until the server
/// is gone. A parked tmux row with no park in flight is no reason to ask: its
/// session ended when it was parked (`WorktreeLifecycle.sessionHasEnded`).
/// Nor is a fork: Claude's `--fork-session`, which a profile switch's fork
/// tab, a carryover and a fresh-branch revive of a Claude conversation start
/// with, writes a new session id and never a second agent on this one.
///
/// What it covers is a session an open tmux row names, one whose row was
/// closed with a mark — closing its tab, archiving its worktree or scratch
/// space, reconcile's archive — and every session a revive of an archived
/// worktree resumes. An archive by an earlier build wrote no mark, and could
/// leave a tab's agent running in the worktree's tmux server: it killed each
/// tab's tmux window, but skipped the kill when it could not confirm the pane
/// was the tab's own, and left the agent running when the kill failed and the
/// pane's pid could not be read to signal it. No record names such a session.
/// So a revive that resumes a session also asks about the worktree's own
/// server (`worktreeServer`), whatever the records say, and is refused while
/// that server may run: a revive in place, a retry of one (which an adopted
/// archived row takes too), with the History pane's preferred session or
/// without, and a fresh-branch revive of a Codex thread. A revive that
/// resumes nothing asks no probe, and neither does a fresh-branch revive of a
/// Claude conversation, which forks it. A repo's worktrees share one server,
/// so while a leftover server runs, every such revive in its repo is refused;
/// ending the server, or a restart, lets them through.
///
/// Three cases leave a session that may still run in tmux with neither a row
/// nor a mark, outside any revive, and this gate lets a start of it through:
///
/// - Removing a repo deletes its main worktree's rows with the worktree row
///   (`WorktreeStore.deleteForRepo`) rather than closing them, so they get
///   no entry.
/// - Forgetting a worktree and deleting a scratch space remove every Closed
///   Terminals entry the worktree had, a mark included.
/// - A row whose worktree the daemon has no local row for names no server, so
///   its close writes no mark (`closeLeftoverTmuxRow`).
///
/// In each, a start of the session without this gate puts the same second
/// agent on it: the gate neither adds these cases nor removes them.
///
/// Keyed by session id rather than by row or worktree, because the paths
/// that resume a session reach it by id from different records — the
/// archived tabs, the History pane's session list, Closed Terminals — and the
/// tmux row or its mark may sit in any worktree. The lookup is one read of
/// each of two partial indexes, the tmux rows' whose session may still run
/// and the marked entries', across every worktree; the probe is asked only
/// about a server they name and, on a revive, its worktree's server, so
/// outside a revive a session neither names costs a start those two reads and
/// nothing else. A start that resumes no session reads nothing. A refusal
/// writes nothing.
///
/// A transition measure, like the probe it asks: on 2027-01-15 parking on
/// sight replaces it. See
/// `docs/specs/2026-10-11-holder-transport-migration-design.md`, "Resuming a
/// session a tmux row carries".
struct TmuxResumeGate: Sendable {
    let history: TerminalHistoryStore
    let terminals: TerminalStore
    let probe: LeftoverTmuxServerProbe

    /// The refusal naming the first server, in name order, that the probe
    /// says may still be running among those a tmux row whose session may
    /// still run or a mark of one of `sessionIDs` names, and `worktreeServer`
    /// when it is not empty; nil when every such server is gone or none is
    /// named. Each server is asked once. With no `sessionIDs` nothing is
    /// started, so nothing is read or asked, `worktreeServer` included.
    /// Throws when either record cannot be read, so a caller never starts a
    /// session it could not check.
    func refusal(
        resuming sessionIDs: [String], worktreeServer: String? = nil
    ) async throws -> TmuxResumeRefusal? {
        guard !sessionIDs.isEmpty else { return nil }
        let marked = try await history.liveOnTmuxServers(sessionIDs: sessionIDs)
        let live = try await terminals.liveTmuxServers(sessionIDs: sessionIDs)
        var servers = Set(marked).union(live)
        if let worktreeServer, !worktreeServer.isEmpty { servers.insert(worktreeServer) }
        for server in servers.sorted() {
            guard await probe.state(server) == .running else { continue }
            logger.notice("resume refused: tmux server \(server, privacy: .public) may still be running this session: a tab on tmux carries it, a tab TBD closed on tmux carried it, or the revived worktree's tabs ran in that server")
            return TmuxResumeRefusal(server: server)
        }
        return nil
    }
}

/// A start the resume gate refused (`TmuxResumeGate`): the session it would
/// start is carried by a tmux row whose session may still run, or was carried
/// by a live tmux row TBD deleted, and that row's tmux server may still be
/// running it; or the start is a revive, and its worktree's own tmux server
/// may still be running. Thrown before the caller writes anything, so every
/// record is as it was.
struct TmuxResumeRefusal: Error, Equatable, LocalizedError, CustomStringConvertible {
    /// The tmux server, as `tmux -L` takes it.
    let server: String

    /// What the person is told, with the command that ends the server.
    var message: String { LeftoverTmuxSession.resumeRefusal(server: server) }

    /// The refusal as a handler answers it, with the code every refusal over
    /// a session still running in tmux carries.
    var coded: CodedRefusal { CodedRefusal(text: message, code: .terminalOnTmux) }

    var errorDescription: String? { message }
    var description: String { message }
}

/// A tmux row's close that could not mark its Closed Terminals entry with the
/// server its session may still be running in
/// (`WorktreeLifecycle.closeLeftoverTmuxRow`). Thrown before the caller
/// deletes anything, so the row stays and keeps naming its session to the
/// resume gate.
struct LeftoverTmuxMarkUnwritable: Error, Equatable, LocalizedError, CustomStringConvertible {
    let terminalID: UUID
    /// The tmux server, as `tmux -L` takes it.
    let server: String
    /// Why the write failed.
    let reason: String

    /// What the person is told.
    var message: String {
        "Terminal \(terminalID) was not closed. Its session may still be running in tmux "
            + "server \(server), and the record that keeps a second agent from being started "
            + "on it could not be saved (\(reason)), so the tab stays open. Try again."
    }

    var errorDescription: String? { message }
    var description: String { message }
}

/// What `WorktreeLifecycle.parkLeftoverTmuxRow` did with a row. The cases are
/// kept apart because each caller reports them differently: only `leftAlone`
/// declined the act, `closed` leaves no row to report on, whether or not its
/// park's first half was written, and `parkedUnreadable` and `superseded` are
/// parks that were written.
enum LeftoverTmuxParkOutcome: Sendable, Equatable {
    /// Parked, with the ended agent's process token fenced. Carries the row as
    /// it reads now, nil when it was closed in the moment after.
    case parked(Terminal?)
    /// Parked and fenced, but reading the row back failed, so there is no row
    /// to show. Carries that read's failure. The park stands; only the read
    /// failed.
    case parkedUnreadable(error: String)
    /// Nothing was written: the row is not a live tmux row with a session to
    /// resume, or it changed after the caller read it.
    case leftAlone
    /// The row was closed before the park could be written, or between its
    /// two halves, after the first half had parked it. Either way the row is
    /// gone, and nothing of it is left to keep.
    case closed
    /// The park was written, but the row changed again before the fence:
    /// whatever changed it decides what it is now.
    case superseded
}
