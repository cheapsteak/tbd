import Foundation

/// Serializes `remote.sendMessage` per remote session, so two messages submitted
/// to one session never overlap in its input box.
///
/// The same decision `TerminalSendSerializer` makes for local terminals, one
/// hop further away: a `send <id> --submit` is a paste followed by a separate
/// Enter on the provider's side, and two of those interleaving in one session
/// would splice one message into the other or submit a half-pasted one. So a
/// second send **queues behind** the first rather than being refused — the
/// caller asked for delivery, and delivery a moment later is still delivery.
///
/// Per `(provider, sessionID)`, not global: two sessions are two composers and
/// still send concurrently. Each session gets a chained `Task` lane that awaits
/// its predecessor and hands the body's value and errors back to its caller.
///
/// No timeout here: each send is already bounded by the 30-second provider
/// timeout it runs under, so a lane can be held for that long and no longer.
actor RemoteSendMessageSerializer {
    private struct Key: Hashable {
        let provider: String
        let sessionID: String
    }

    private var lanes: [Key: Task<Void, Never>] = [:]
    /// Test-only inspection: how many sends have reached the serializer, so a
    /// test can tell a second send has queued before it releases the first.
    private(set) var admittedCount = 0

    /// Run `send` once every send already queued for this session has
    /// finished. Returns what `send` returned and rethrows what it threw.
    func run<T: Sendable>(
        provider: String, sessionID: String,
        _ send: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        admittedCount += 1
        let key = Key(provider: provider, sessionID: sessionID)
        let predecessor = lanes[key]
        let task = Task<T, Error> { [predecessor] in
            await predecessor?.value
            return try await send()
        }
        // The tail erases both value and failure: a send that failed still
        // released the session, so its successor runs rather than inheriting
        // the error.
        let tail = Task<Void, Never> { _ = await task.result }
        lanes[key] = tail
        // Prune once this tail finishes unless a later send replaced it, so
        // `lanes` does not grow one entry per session ever sent to.
        Task { [weak self] in
            await tail.value
            await self?.removeIfTail(key: key, task: tail)
        }
        return try await task.value
    }

    private func removeIfTail(key: Key, task: Task<Void, Never>) {
        if lanes[key] == task {
            lanes[key] = nil
        }
    }

    /// Test-only inspection: number of sessions with a live lane.
    var trackedSessionCount: Int { lanes.count }
}
