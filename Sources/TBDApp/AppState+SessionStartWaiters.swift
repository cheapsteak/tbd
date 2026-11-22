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
    /// **Checks the latch before registering.** `wakeTerminalForComposer`
    /// mints the incarnation and returns before the daemon's refresh round
    /// trip completes, so the caller registering a waiter here can race a
    /// `SessionStart` that already landed. `noteSessionStart` latches every
    /// incarnation it sees regardless of whether a waiter existed at the time,
    /// so a latch already holding this incarnation answers `true` immediately
    /// — no continuation, no registration, no wait.
    ///
    /// **No deadline of its own, on purpose.** `ComposerSendCoordinator` races
    /// this against its injected clock and cancels the loser, which is where the
    /// timeout belongs and the only place a test can advance it.
    ///
    /// The cancellation handling is not defensive bookkeeping: the coordinator's
    /// task group awaits all of its children on exit, so a continuation nobody
    /// resumes would hang the send forever rather than time out.
    ///
    /// A terminal a tab close holds (`closingTerminals`) does not answer from
    /// the latch: the waiter registers, and the close's outcome answers it
    /// (see `noteSessionStart`).
    func awaitSessionStart(terminalID: UUID, incarnationID: UUID) async -> Bool {
        if closingTerminals[terminalID] == nil,
           lastStartedIncarnation[terminalID] == incarnationID {
            return true
        }
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

    /// A `SessionStart` was accepted for this terminal. Latch the incarnation
    /// and release the waiters that were waiting for THIS spawn.
    ///
    /// **A delta carrying no incarnation releases nobody, and latches nothing.**
    /// A worktree's first spawn and an archive restore plant no id, so "no id"
    /// is a real state rather than a gap — and a hold that released on it
    /// would release on a session the composer never started.
    ///
    /// **The latch is written even when nobody is waiting yet.** That is the
    /// whole point of it: a `SessionStart` can land before
    /// `wakeTerminalForComposer`'s caller has registered its
    /// `awaitSessionStart` waiter, and without a latch that start is simply
    /// lost — nothing was there to release. Recording it here lets the waiter,
    /// once it does register (or checks in `awaitSessionStart` before
    /// registering), find it retroactively.
    ///
    /// **A terminal a tab close holds releases nobody yet** (`closingTerminals`).
    /// The person closed its tab, so a send held on it must not report
    /// delivered into a terminal its delete is about to end. The start is
    /// latched and recorded with every other start during the close
    /// (`sessionStartsDuringClose`), and the close answers the waiters: a
    /// terminal the daemon deleted fails them with the rest of its composer
    /// state (`forgetComposerState`), and one it kept releases each waiter a
    /// recorded start matches as it comes back (`bringBackClosedTerminals`).
    func noteSessionStart(terminalID: UUID, incarnationID: UUID?) {
        guard let incarnationID else { return }
        lastStartedIncarnation[terminalID] = incarnationID
        guard closingTerminals[terminalID] == nil else {
            sessionStartsDuringClose[terminalID, default: []].insert(incarnationID)
            return
        }
        resumeSessionStartWaiters(terminalID: terminalID, started: [incarnationID])
    }

    /// Answers the sends a tab close held on a terminal the daemon kept:
    /// every waiter for an incarnation that started, whether before the close
    /// (the latch) or while it held the terminal (`sessionStartsDuringClose`).
    /// Every other waiter keeps waiting.
    func releaseSessionStartWaitersHeldByClose(terminalID: UUID) {
        var started = sessionStartsDuringClose.removeValue(forKey: terminalID) ?? []
        if let latched = lastStartedIncarnation[terminalID] {
            started.insert(latched)
        }
        resumeSessionStartWaiters(terminalID: terminalID, started: started)
    }

    /// Release this terminal's waiters for the incarnations named in
    /// `started`, leaving every other waiter waiting.
    private func resumeSessionStartWaiters(terminalID: UUID, started: Set<UUID>) {
        guard let waiters = sessionStartWaiters[terminalID] else { return }
        let matched = waiters.filter { started.contains($0.incarnationID) }
        guard !matched.isEmpty else { return }
        let remaining = waiters.filter { !started.contains($0.incarnationID) }
        sessionStartWaiters[terminalID] = remaining.isEmpty ? nil : remaining
        for waiter in matched { waiter.resume(true) }
    }

    /// Fail every waiter on this terminal, because the terminal has stopped
    /// existing and the spawn they are holding for can no longer report in.
    /// The starts a tab close recorded for it go too.
    ///
    /// Resumed `false` rather than dropped: the entry is a suspended
    /// continuation, and a continuation nobody resumes hangs its send for the
    /// life of the app rather than timing out.
    func releaseSessionStartWaiters(terminalID: UUID) {
        sessionStartsDuringClose.removeValue(forKey: terminalID)
        guard let waiters = sessionStartWaiters.removeValue(forKey: terminalID) else { return }
        for waiter in waiters { waiter.resume(false) }
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
