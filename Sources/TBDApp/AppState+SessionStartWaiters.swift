import Foundation

/// One suspended caller waiting for one spawn to report in.
///
/// Scoped by the incarnation rather than by the terminal alone, because the
/// terminal is not the question: a competing wake, a post-`--fork-session`
/// recapture, and a person typing `claude --resume` in the pane all raise a
/// `SessionStart` on the same terminal, and none of them is the message's own
/// session.
@MainActor
struct SessionStartWaiter {
    /// Identifies this registration so cancellation can withdraw exactly it.
    let token: UUID
    let incarnationID: UUID
    let resume: (Bool) -> Void
}

extension AppState {
    /// Resolves true when this terminal reports a `SessionStart` carrying
    /// exactly `incarnationID`, and false on cancellation.
    ///
    /// **No deadline of its own, on purpose.** `ComposerSendCoordinator` races
    /// this against its injected clock and cancels the loser, which is where the
    /// timeout belongs and the only place a test can advance it.
    ///
    /// The cancellation handling is not defensive bookkeeping: the coordinator's
    /// task group awaits all of its children on exit, so a continuation nobody
    /// resumes would hang the send forever rather than time out.
    func awaitSessionStart(terminalID: UUID, incarnationID: UUID) async -> Bool {
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                // Cancelled before we could register: resume here, or nothing
                // ever will.
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                sessionStartWaiters[terminalID, default: []].append(
                    SessionStartWaiter(
                        token: token, incarnationID: incarnationID,
                        resume: { continuation.resume(returning: $0) }))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.withdrawSessionStartWaiter(terminalID: terminalID, token: token)
            }
        }
    }

    /// A `SessionStart` was accepted for this terminal. Release the waiters that
    /// were waiting for THIS spawn.
    ///
    /// **A delta carrying no incarnation releases nobody.** A worktree's first
    /// spawn and an archive restore plant no id, so "no id" is a real state
    /// rather than a gap — and a hold that released on it would release on a
    /// session the composer never started.
    func noteSessionStart(terminalID: UUID, incarnationID: UUID?) {
        guard let incarnationID, let waiters = sessionStartWaiters[terminalID] else { return }
        let matched = waiters.filter { $0.incarnationID == incarnationID }
        guard !matched.isEmpty else { return }
        let remaining = waiters.filter { $0.incarnationID != incarnationID }
        sessionStartWaiters[terminalID] = remaining.isEmpty ? nil : remaining
        for waiter in matched { waiter.resume(true) }
    }

    private func withdrawSessionStartWaiter(terminalID: UUID, token: UUID) {
        guard let waiters = sessionStartWaiters[terminalID],
              let waiter = waiters.first(where: { $0.token == token })
        else { return }
        let remaining = waiters.filter { $0.token != token }
        sessionStartWaiters[terminalID] = remaining.isEmpty ? nil : remaining
        waiter.resume(false)
    }
}
