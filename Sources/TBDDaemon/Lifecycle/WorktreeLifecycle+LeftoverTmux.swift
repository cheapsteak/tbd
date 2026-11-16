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

    /// Park a live tmux row whose server the probe found gone, and return the
    /// parked row, or nil when it was not parked for any reason
    /// `parkLeftoverTmuxRowReportingOutcome` reports. For a caller that only
    /// needs to know whether the row is parked now.
    func parkLeftoverTmuxRow(_ terminal: Terminal) async throws -> Terminal? {
        if case .parked(let row) = try await parkLeftoverTmuxRowReportingOutcome(terminal) {
            return row
        }
        return nil
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
    /// nothing left to keep. Any other failure is thrown.
    func parkLeftoverTmuxRowReportingOutcome(
        _ terminal: Terminal
    ) async throws -> LeftoverTmuxParkOutcome {
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
        } catch {
            guard try await db.terminals.get(id: terminal.id) == nil else { throw error }
            logger.info("leftover tmux park: terminal \(terminal.id, privacy: .public) was closed before it could be parked")
            return .closed
        }
        guard let incarnation else {
            logger.info("leftover tmux park: terminal \(terminal.id, privacy: .public) changed before it could be parked; left as it is")
            return .leftAlone
        }
        let fenced: UUID?
        do {
            fenced = try await db.terminals.finalizeHibernatedShellRespawn(
                id: terminal.id, expectedIncarnation: incarnation, at: now())
        } catch {
            // Closed between the halves, or woken between them, which leaves
            // a row that is no longer parked for the fence to finish.
            guard let current = try await db.terminals.get(id: terminal.id) else {
                logger.info("leftover tmux park: terminal \(terminal.id, privacy: .public) was closed while it was being parked")
                return .closed
            }
            guard current.isParked else {
                logger.info("leftover tmux park: terminal \(terminal.id, privacy: .public) was parked and then woken before the park finished; left as the wake made it")
                return .superseded
            }
            throw error
        }
        guard fenced != nil else {
            logger.info("leftover tmux park: terminal \(terminal.id, privacy: .public) was parked and then changed before the park finished; left as that change made it")
            return .superseded
        }
        await pendingQuestions.clear(terminalID: terminal.id)
        await subscriptions?.broadcastPendingPrompts(
            terminalID: terminal.id, from: pendingQuestions)
        logger.notice("leftover tmux park: parked terminal \(terminal.id, privacy: .public) — its tmux server is gone; session preserved, it wakes after `tbd terminal migrate`")
        let parked = try await db.terminals.get(id: terminal.id)
        return .parked(parked)
    }
}

/// What `WorktreeLifecycle.parkLeftoverTmuxRowReportingOutcome` did with a
/// row. The four are kept apart because the actuation record says different
/// things about each: only `leftAlone` declined the act, and `superseded` is
/// a park that was written.
enum LeftoverTmuxParkOutcome: Sendable, Equatable {
    /// Parked, with the ended agent's process token fenced. Carries the row as
    /// it reads now, nil when it was closed in the moment after.
    case parked(Terminal?)
    /// Nothing was written: the row is not a live tmux row with a session to
    /// resume, or it changed after the caller read it.
    case leftAlone
    /// The row was closed before the park could be written, or between its
    /// two halves. Nothing of it is left to keep.
    case closed
    /// The park was written, but the row changed again before the fence:
    /// whatever changed it decides what it is now.
    case superseded
}
