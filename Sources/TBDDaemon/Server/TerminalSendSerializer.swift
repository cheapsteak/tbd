import Foundation

/// Serializes `terminal.send` per terminal, so two payloads can never interleave
/// in one composer.
///
/// A send is not one tmux command: it is a `load-buffer`, a `paste-buffer`, and
/// often a separate `Enter`. Two of those sequences overlapping in one pane
/// splices one caller's text into another's — a transport bug, since neither
/// caller asked for the message that arrives. So a second send **queues behind**
/// the first rather than being refused: the caller asked for delivery, and
/// delivery a moment later is still delivery. (`RefusedReason.inFlight` names
/// the opposite decision — an act declined because a twin is already running —
/// and is deliberately not what happens here.)
///
/// Per terminal, not global: two different terminals are two different composers
/// and must still send concurrently. Each terminal gets a chained `Task` lane
/// that awaits its predecessor, the shape `RepoSerializer` already uses for
/// per-repo git work; the difference is that this one hands the body's value and
/// its errors back to the caller, because an RPC handler's response is the
/// thing being serialized.
///
/// No timeout. Every step inside a send is already bounded by
/// `TmuxManager.commandTimeout`, so a lane can be held for a bounded interval by
/// a wedged tmux and no longer; a timeout here would only add a second, worse
/// deadline that abandons a half-typed payload.
actor TerminalSendSerializer {
    private var lanes: [UUID: Task<Void, Never>] = [:]

    /// Run `send` once every send already queued for `terminalID` has finished.
    /// Returns what `send` returned and rethrows what it threw.
    func run<T: Sendable>(
        terminalID: UUID, _ send: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let predecessor = lanes[terminalID]
        let task = Task<T, Error> { [predecessor] in
            await predecessor?.value
            return try await send()
        }
        // The lane's tail erases both the value and the failure: a send that
        // threw still released the pane, so its successor must run, not inherit
        // its error. Awaiting `.result` never rethrows and never cancels.
        let tail = Task<Void, Never> { _ = await task.result }
        lanes[terminalID] = tail
        // Prune once this tail finishes, unless a later send has replaced it —
        // otherwise `lanes` grows one entry per terminal ever sent to.
        Task { [weak self] in
            await tail.value
            await self?.removeIfTail(terminalID: terminalID, task: tail)
        }
        return try await task.value
    }

    private func removeIfTail(terminalID: UUID, task: Task<Void, Never>) {
        if lanes[terminalID] == task {
            lanes[terminalID] = nil
        }
    }

    /// Test-only inspection: number of terminals with a live lane.
    var trackedTerminalCount: Int { lanes.count }
}
