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
    /// The tmux server `terminal`'s worktree names, and what the socket probe
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
    /// the Codex thread id and launch options — and return the parked row.
    ///
    /// A compare-and-set against the row as the caller read it, so a row that
    /// changed in between is left as it is and nil comes back. Nil too for a
    /// row with nothing to resume, which a park cannot keep. Nothing is
    /// stopped: the server is gone, and every process it ran went with it.
    /// The reason is `.recovery`, the same reason reconcile's park of a
    /// session nothing can reach records.
    func parkLeftoverTmuxRow(_ terminal: Terminal) async throws -> Terminal? {
        guard terminal.transport == .tmux, !terminal.isParked,
              terminal.recoveryResumePlan != nil else {
            return nil
        }
        guard let incarnation = try await db.terminals.beginHibernatedShellRespawn(
            id: terminal.id,
            expectedState: TerminalHibernationSnapshot(terminal: terminal),
            reason: .recovery,
            at: now()) else {
            logger.info("leftover tmux park: terminal \(terminal.id, privacy: .public) changed before it could be parked; left as it is")
            return nil
        }
        guard try await db.terminals.finalizeHibernatedShellRespawn(
            id: terminal.id, expectedIncarnation: incarnation, at: now()) != nil else {
            logger.info("leftover tmux park: terminal \(terminal.id, privacy: .public) changed while it was being parked; left as it is")
            return nil
        }
        await pendingQuestions.clear(terminalID: terminal.id)
        await subscriptions?.broadcastPendingPrompts(
            terminalID: terminal.id, from: pendingQuestions)
        logger.notice("leftover tmux park: parked terminal \(terminal.id, privacy: .public) — its tmux server is gone; session preserved, it wakes after `tbd terminal migrate`")
        return try await db.terminals.get(id: terminal.id)
    }
}
