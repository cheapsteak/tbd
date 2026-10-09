import Foundation
import os
import TBDShared

private let backgroundLogger = Logger(subsystem: "com.tbd.daemon", category: "remote-transcript")

/// Keeps unopened remote sessions' transcript caches current
/// (`docs/specs/2026-09-25-remote-session-transcript-design.md` § Background
/// sync).
///
/// Runs no timers. Its only input is the sightings `RemoteProviderManager`
/// already processes, handed over through `observe` with their hints intact.
/// Every sighting's hint goes into `RemoteTranscriptHints` first, whatever the
/// flag says. Then, while `remote_transcript_live_sync_enabled` is on, a
/// session is enqueued once when its hint differs from the hint recorded in
/// `state.json` at its last caught-up sync; repeated changes before that sync
/// runs coalesce into the one entry already queued.
///
/// - **Skips** – sessions whose sighting carries no hint, dismissed sessions,
///   providers that do not declare both `transcript.read` and
///   `transcript.tail`, and everything while the flag is off.
/// - **Pacing** – one sync at a time per provider, each through the session's
///   lane in `RemoteTranscriptSync`, so it coalesces with an on-screen pane's
///   syncs rather than racing them. A sync not caught up goes to the back of
///   its provider's queue, so one long backlog cannot starve the rest. A sync
///   that fails is dropped, not retried: the session's next sighting enqueues
///   it again, since its hint still differs from the recorded one.
/// - **Restart** – the recorded hint lives in `state.json`, so after a daemon
///   restart a session whose first sighting matches it is not refetched.
/// - **The flag** is read at admission and before every dequeue, never cached.
///   Found off, every queue is dropped; a sync already running finishes.
///
/// No clock: nothing here sleeps, polls or times out. Each provider call's
/// timeout is the invoker's, behind `RemoteTranscriptSync`.
///
/// No new durable resource: syncs write the same per-session cache directory
/// `OrphanGC`'s remote-transcript leg already reclaims.
actor RemoteTranscriptBackgroundSync {
    /// One sync of one session's cache. Production passes
    /// `RemoteTranscriptSync.sync`.
    typealias Sync = @Sendable (_ provider: String, _ sessionID: String) async throws -> RemoteTranscriptSyncResult

    private struct Key: Hashable {
        let provider: String
        let sessionID: String
    }

    private let environment: [String: String]
    private let hints: RemoteTranscriptHints
    private let isEnabled: @Sendable () async -> Bool
    private let capabilities: @Sendable (_ provider: String) async -> Set<String>
    private let isDismissed: @Sendable (_ provider: String, _ sessionID: String) async -> Bool
    private let discard: @Sendable (_ provider: String, _ sessionID: String) async -> Void
    private let sync: Sync

    /// Provider → session ids waiting for a sync, in order.
    private var queues: [String: [String]] = [:]
    /// Every session in `queues`, for coalescing. A session leaves it when its
    /// sync starts, so a hint change seen during that sync queues it again.
    private var queued: Set<Key> = []
    /// The one worker draining each provider's queue.
    private var workers: [String: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - environment: resolves each session's cache through `TBDConstants`,
    ///     so `TBD_HOME` decides where the recorded hint is read from. It must
    ///     match the environment the `sync` closure's caches use.
    ///   - hints: the store every sighting's hint is recorded in — the same
    ///     instance `RemoteTranscriptSync`'s policy reads.
    ///   - isEnabled: the live-sync flag, read fresh on every call.
    ///   - capabilities: what a provider declared in `describe`.
    ///   - isDismissed: whether the session's mirror row is dismissed.
    ///   - discard: removes a session's cache, for one dismissed while its
    ///     sync ran.
    ///   - sync: see `Sync`.
    init(
        environment: [String: String],
        hints: RemoteTranscriptHints,
        isEnabled: @escaping @Sendable () async -> Bool,
        capabilities: @escaping @Sendable (_ provider: String) async -> Set<String>,
        isDismissed: @escaping @Sendable (_ provider: String, _ sessionID: String) async -> Bool,
        discard: @escaping @Sendable (_ provider: String, _ sessionID: String) async -> Void,
        sync: @escaping Sync
    ) {
        self.environment = environment
        self.hints = hints
        self.isEnabled = isEnabled
        self.capabilities = capabilities
        self.isDismissed = isDismissed
        self.discard = discard
        self.sync = sync
    }

    /// Records every sighting's hint (flag or not), then enqueues the ones
    /// that qualify. Returns without waiting for any sync.
    func observe(sessions: [RemoteSessionPayload], provider: String) async {
        for session in sessions {
            await hints.record(provider: provider, sessionID: session.id, hint: session.transcript)
        }
        guard await isEnabled() else {
            dropAll()
            return
        }
        let declared = await capabilities(provider)
        guard declared.contains(RemoteCapability.transcriptRead),
              declared.contains(RemoteCapability.transcriptTail) else { return }
        var added = false
        for session in sessions {
            guard let hint = session.transcript else { continue }
            let key = Key(provider: provider, sessionID: session.id)
            guard !queued.contains(key) else { continue }
            let recorded = RemoteTranscriptCache(
                provider: provider, sessionID: session.id, environment: environment
            ).peekState()?.hint
            guard hint != recorded else { continue }
            guard !(await isDismissed(provider, session.id)) else { continue }
            // Checked again after the suspension above: another sighting of
            // the same session may have queued it meanwhile.
            guard !queued.contains(key) else { continue }
            queues[provider, default: []].append(session.id)
            queued.insert(key)
            added = true
        }
        if added { startWorkerIfIdle(provider: provider) }
    }

    /// Empties every queue. A sync already running finishes.
    func dropAll() {
        queues.removeAll()
        queued.removeAll()
    }

    /// Test hook: the sessions waiting for a sync on one provider, in order.
    func queuedSessions(provider: String) -> [String] {
        queues[provider] ?? []
    }

    /// Test hook: returns once no worker is running, and so every queue is
    /// empty. Never called in production.
    func waitUntilIdle() async {
        while let worker = workers.values.first {
            await worker.value
        }
    }

    // MARK: - Worker

    private func startWorkerIfIdle(provider: String) {
        guard workers[provider] == nil else { return }
        workers[provider] = Task { await self.drain(provider: provider) }
    }

    /// Syncs one provider's queue front to back until it is empty. The worker
    /// removes itself in the same synchronous stretch that finds the queue
    /// empty, so an `observe` landing afterwards always starts a new one.
    private func drain(provider: String) async {
        while let sessionID = popFront(provider: provider) {
            guard await isEnabled() else {
                dropAll()
                break
            }
            if await isDismissed(provider, sessionID) { continue }
            do {
                let result = try await sync(provider, sessionID)
                if await isDismissed(provider, sessionID) {
                    // Dismissed while the sync ran: whatever it wrote belongs
                    // to a session TBD no longer keeps.
                    await discard(provider, sessionID)
                } else if !result.caughtUp {
                    requeueAtBack(provider: provider, sessionID: sessionID)
                }
            } catch {
                backgroundLogger.info(
                    """
                    background transcript sync provider=\(provider, privacy: .public) \
                    session=\(sessionID, privacy: .public) failed; dropped until its next sighting: \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
        workers[provider] = nil
    }

    private func popFront(provider: String) -> String? {
        guard var queue = queues[provider], !queue.isEmpty else {
            queues[provider] = nil
            return nil
        }
        let sessionID = queue.removeFirst()
        queues[provider] = queue.isEmpty ? nil : queue
        queued.remove(Key(provider: provider, sessionID: sessionID))
        return sessionID
    }

    private func requeueAtBack(provider: String, sessionID: String) {
        let key = Key(provider: provider, sessionID: sessionID)
        guard !queued.contains(key) else { return }
        queues[provider, default: []].append(sessionID)
        queued.insert(key)
    }
}
