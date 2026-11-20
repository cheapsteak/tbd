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
        logger.notice("leftover tmux park: parked terminal \(terminal.id, privacy: .public) — its tmux server is gone; session preserved, it wakes after `tbd terminal migrate`")
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
    /// tmux command, and the caller deletes the row either way.
    ///
    /// **A live row's session keeps running.** Its tmux server may still be
    /// running a session an earlier build started there, and TBD can neither
    /// reach nor stop it, so deleting the row leaves that session running with
    /// nothing in TBD naming it. The close goes ahead regardless: refusing it
    /// would leave a tab TBD can neither show nor end with no way to close it.
    /// What the daemon does is say so, at `.notice`, with the command that ends
    /// the server. A live row gets no Closed Terminals entry: there is no
    /// screen to keep, and an entry would carry the id of a session that may
    /// still be running, so reopening it would start a second agent on the
    /// same session.
    ///
    /// **A parked row's entry comes from the row.** Its agent was ended when
    /// it was parked, and the screen the park saved, `suspendedSnapshot`, is
    /// what its Closed Terminals entry keeps, with its session id. Only when
    /// `history` is given: the hard-delete paths (forget, scratch delete)
    /// remove the worktree's history right after.
    ///
    /// - Parameter server: the tmux server the row's worktree names, nil when
    ///   the worktree row could not be read.
    static func closeLeftoverTmuxRow(
        _ terminal: Terminal, server: String?, history: TerminalHistoryStore?
    ) async {
        if terminal.isParked {
            if let history {
                await history.recordOnClose(terminal: terminal, capture: terminal.suspendedSnapshot)
            }
            return
        }
        guard let server else {
            logger.notice("closed terminal \(terminal.id, privacy: .public) on tmux without running tmux; its worktree row could not be read, so its tmux server is unknown, and its session may still be running there")
            return
        }
        logger.notice("closed terminal \(terminal.id, privacy: .public) on tmux without running tmux; its session may still be running in tmux server \(server, privacy: .public). \(LeftoverTmuxSession.endingAdvice(server: server), privacy: .public)")
    }
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
