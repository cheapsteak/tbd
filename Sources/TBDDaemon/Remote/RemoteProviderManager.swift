import Foundation
import os
import TBDShared

private let remoteLogger = Logger(subsystem: "com.tbd.daemon", category: "remote")

/// Owns the remote-backend feature at runtime: registry, describe cache,
/// per-provider poll loops, provider health, and pass-through invocations.
/// Source of truth for sessions is always the provider; this actor only
/// maintains the mirror + broadcasts.
public actor RemoteProviderManager {
    private let db: TBDDatabase
    private let subscriptions: StateSubscriptionManager
    private let runner: any RemoteProviderInvoking
    private let registryURL: URL
    private let clock: any Clock<Duration>
    static let pollInterval: TimeInterval = 60

    private var providers: [String: RemoteProviderConfig] = [:]
    private var describes: [String: ProviderDescribe] = [:]
    private var health: [String: (state: ProviderHealth, message: String?, remediation: ProviderRemediation?)] = [:]
    private var loops: [String: Task<Void, Never>] = [:]
    private var supervisors: [String: ProviderEventsSupervisor] = [:]
    /// Guards `spawnPollLoops`'s compound stopAll()+startLoop() sequence
    /// against a second concurrent call to the same sequence (e.g. two
    /// overlapping `start()`s). See the comment on `spawnPollLoops` for the
    /// race this closes.
    private var reconfiguring = false
    private var reconfigureWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set by `shutdown()` while still holding the reconfigure lock, and
    /// never cleared — shutdown is terminal for this actor's lifetime. See
    /// `shutdown()`'s doc comment for the race this closes.
    private var shuttingDown = false

    init(db: TBDDatabase, subscriptions: StateSubscriptionManager,
         runner: any RemoteProviderInvoking, registryURL: URL,
         clock: any Clock<Duration> = ContinuousClock()) {
        self.db = db
        self.subscriptions = subscriptions
        self.runner = runner
        self.registryURL = registryURL
        self.clock = clock
    }

    /// Full boot path: load the registry, describe every provider, then
    /// spawn poll loops for the ones that negotiated a usable contract.
    /// Composition of the two steps below — callers that only need
    /// registry/describe state (e.g. verb-routing tests) should call
    /// `loadRegistryAndDescribe()` alone so no background timer is armed.
    func start() async {
        await loadRegistryAndDescribe()
        await spawnPollLoops()
    }

    /// Loads the provider registry and runs `describe` against every entry,
    /// populating `providers`/`describes`/`health`. Spawns no poll loops —
    /// safe to call from tests that only want to exercise describe/invoke
    /// routing without racing a real 60s timer.
    ///
    /// Checks `Task.isCancelled` before each provider's `describe` so a
    /// caller cancelling the enclosing task (daemon shutdown racing boot)
    /// bounds this to at most one `describe` child process in flight rather
    /// than one per remaining provider.
    func loadRegistryAndDescribe() async {
        let configs: [RemoteProviderConfig]
        do {
            configs = try RemoteProviderRegistry.load(from: registryURL)
        } catch {
            remoteLogger.error("provider registry unreadable: \(String(describing: error), privacy: .public)")
            return
        }
        for config in configs {
            guard !Task.isCancelled else { return }
            registerIfNeeded(config)
            await describeProvider(config)
        }
        subscriptions.broadcast(delta: .remoteSessionsChanged)
    }

    /// Runs `describe` for one provider and records the outcome in
    /// `describes`/`health`. Auth failures (exit 4) and other classified
    /// failures route through the same `recordFailure` path `pollOnce` and
    /// `invoke` use, so a provider that rejects credentials on its very
    /// first contact still surfaces `needs_auth` with remediation instead of
    /// a generic error. Only spawn/parse problems — which no failure class
    /// can describe — fall back to a generic message, distinguished by text
    /// from "it ran and rejected us".
    private func describeProvider(_ config: RemoteProviderConfig) async {
        let result: ProviderResult
        do {
            result = try await runner.run(config, verb: ["describe"], stdin: nil, timeout: 10)
        } catch {
            remoteLogger.error("describe \(config.name, privacy: .public) couldn't run: \(String(describing: error), privacy: .public)")
            setHealth(provider: config.name, to: (.error, "couldn't run describe: \(error)", nil))
            return
        }
        if let failure = result.failureClass {
            recordFailure(provider: config.name, class: failure, result: result)
            return
        }
        guard let describe = try? result.decoded(ProviderDescribe.self) else {
            setHealth(provider: config.name, to: (.error, "describe returned an unparseable response", nil))
            return
        }
        guard describe.contractVersions.contains(1) else {
            setHealth(provider: config.name, to: (.error, "no common contract version", nil))
            return
        }
        describes[config.name] = describe
    }

    /// Spawns/re-spawns the 60s poll loop for every provider with a valid
    /// `describe` on file. Cancels any existing loops (and stops any running
    /// events supervisors) first so a second call can't orphan one that
    /// `stopAll()` would no longer be able to reach (the stored handle would
    /// just get overwritten).
    /// The whole stopAll()+startLoop() sequence runs under `reconfiguring` so
    /// two concurrent calls (e.g. overlapping `start()`s) can never
    /// interleave. Without it: `startLoop` inserts a supervisor into
    /// `supervisors` and then suspends at `await supervisor.start()` — a
    /// different actor, so this actor's executor is released for that
    /// window. A second call's `stopAll()` could run entirely in that
    /// window: its `await supervisor.stop()` on the just-inserted supervisor
    /// returns instantly (nothing has started yet) and `removeAll()` drops
    /// it, then the first call resumes and arms `start()` on a supervisor
    /// nothing holds — the provider's child process respawns on backoff for
    /// the daemon's life with no handle able to stop it. The symmetric case
    /// (a supervisor inserted during one of `stopAll()`'s own awaits, then
    /// dropped by that call's `removeAll()`) is closed the same way, since
    /// the two call sequences now can't overlap at all.
    private func spawnPollLoops() async {
        await acquireReconfigureLock()
        defer { releaseReconfigureLock() }
        // A call already parked in the FIFO waiter queue when `shutdown()`
        // ran receives the baton right after `shutdown()` releases it — FIFO
        // ordering alone doesn't stop that hand-off, only this flag does.
        // Without it, this would respawn poll loops (and events supervisors)
        // on a manager the daemon believes it already tore down.
        guard !shuttingDown else { return }
        await stopAll()
        for name in describes.keys {
            guard let config = providers[name] else { continue }
            await startLoop(for: config)
        }
    }

    private func acquireReconfigureLock() async {
        if reconfiguring {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                reconfigureWaiters.append(continuation)
            }
        } else {
            reconfiguring = true
        }
    }

    private func releaseReconfigureLock() {
        if reconfigureWaiters.isEmpty {
            reconfiguring = false
        } else {
            reconfigureWaiters.removeFirst().resume()
        }
    }

    func stopAll() async {
        for task in loops.values { task.cancel() }
        loops.removeAll()
        for supervisor in supervisors.values { await supervisor.stop() }
        supervisors.removeAll()
    }

    /// Guarded daemon-shutdown entry point. `stopAll()` itself is not safe
    /// to call directly from outside `spawnPollLoops` — it's the FIFO
    /// reconfigure lock (see `spawnPollLoops`'s comment) that makes teardown
    /// and a concurrent spawn mutually exclusive, and `stopAll()` on its own
    /// doesn't take it.
    ///
    /// Taking the lock alone is NOT sufficient, and this does not merely
    /// guard against "a `start()` still in flight at shutdown": FIFO means a
    /// `spawnPollLoops()` call already parked in the waiter queue when this
    /// runs receives the baton right after `shutdown()` releases the lock —
    /// it would then respawn poll loops/supervisors on a manager the daemon
    /// believes is torn down. `shuttingDown` (set here, before `stopAll()`,
    /// and never cleared) makes shutdown terminal: every `spawnPollLoops()`
    /// call that resumes after this one — queued or future — is a no-op.
    func shutdown() async {
        await acquireReconfigureLock()
        defer { releaseReconfigureLock() }
        shuttingDown = true
        await stopAll()
    }

    /// The 60s `list` poll is the universal floor for every provider,
    /// events-capable or not — it keeps running even when a stream is up,
    /// since snapshot application is idempotent and this is what covers a
    /// stream that's down or restarting. Providers that declared the
    /// `events` capability in their cached `describe` additionally get a
    /// supervised low-latency NDJSON stream.
    private func startLoop(for config: RemoteProviderConfig) async {
        if describes[config.name]?.capabilities.contains("events") == true {
            let supervisor = ProviderEventsSupervisor(config: config, manager: self, clock: clock)
            supervisors[config.name] = supervisor
            // Awaiting `supervisor.start()` (a different actor) suspends this
            // actor's executor, which by itself does NOT close the race
            // described on `spawnPollLoops` — only that method's
            // `reconfiguring` guard does, by making it impossible for a
            // concurrent stopAll()/spawnPollLoops() call to run while this
            // one is still in flight.
            await supervisor.start()
        }
        loops[config.name] = Task { [weak self, clock] in
            while !Task.isCancelled {
                await self?.pollOnce(provider: config)
                try? await clock.sleep(for: .seconds(Self.pollInterval))
            }
        }
    }

    func pollOnce(provider: RemoteProviderConfig) async {
        // pollOnce must work standalone, without start() having registered
        // the provider first (mirror tests + Task 7's ad-hoc RPC lookups
        // both call it directly) — register on first use so providerStatuses()
        // reflects it.
        registerIfNeeded(provider)
        do {
            let result = try await runner.run(provider, verb: ["list"], stdin: nil, timeout: 30)
            if let failure = result.failureClass {
                recordFailure(provider: provider.name, class: failure, result: result)
                return
            }
            let envelope = try result.decoded(RemoteSessionListEnvelope.self)
            try await apply(snapshot: envelope.sessions, provider: provider.name)
            markHealthy(provider: provider.name)
        } catch {
            remoteLogger.debug("poll \(provider.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            setHealth(provider: provider.name, to: (.stale, String(describing: error), nil))
        }
    }

    /// Shared by the poll path and the events snapshot path (Task 6).
    func apply(snapshot sessions: [RemoteSessionPayload], provider: String) async throws {
        let outcome = try await db.remoteSessions.applySnapshot(
            provider: provider, sessions: sessions, now: Date())
        if outcome.changed {
            subscriptions.broadcast(delta: .remoteSessionsChanged)
        }
        for session in outcome.attention {
            subscriptions.broadcast(delta: .remoteSessionAttention(RemoteSessionAttentionDelta(
                provider: provider, sessionID: session.id, title: session.title,
                kind: session.agentState.rawValue, reason: session.agentStateReason,
                exitCode: session.exitCode)))
        }
    }

    /// Single-session upsert from an events `session` line. No absence
    /// bookkeeping happens here — only `apply(snapshot:)` drives the
    /// two-absence rule, since only a full snapshot can tell what's missing.
    func applyUpsert(_ session: RemoteSessionPayload, provider: String) async {
        let outcome: SnapshotOutcome
        do {
            outcome = try await db.remoteSessions.upsertOne(
                provider: provider, session: session, now: Date())
        } catch {
            remoteLogger.error(
                "events upsert failed for \(provider, privacy: .public)/\(session.id, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        if outcome.changed {
            subscriptions.broadcast(delta: .remoteSessionsChanged)
        }
        for session in outcome.attention {
            subscriptions.broadcast(delta: .remoteSessionAttention(RemoteSessionAttentionDelta(
                provider: provider, sessionID: session.id, title: session.title,
                kind: session.agentState.rawValue, reason: session.agentStateReason,
                exitCode: session.exitCode)))
        }
    }

    /// Explicit removal from an events `removed` line. The provider is
    /// authoritative about this — skip the two-absence rule entirely and
    /// mark the row gone immediately.
    func applyRemoval(sessionID: String, provider: String) async {
        let changed: Bool
        do {
            changed = try await db.remoteSessions.markGone(
                provider: provider, sessionID: sessionID)
        } catch {
            remoteLogger.error(
                "events removal failed for \(provider, privacy: .public)/\(sessionID, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        if changed {
            subscriptions.broadcast(delta: .remoteSessionsChanged)
        }
    }

    /// Test seam: whether a supervisor currently exists for `name` — used
    /// only to make the events-vs-poll capability gate in `startLoop`
    /// observable from tests without exposing `supervisors` itself.
    func hasSupervisor(named name: String) -> Bool {
        supervisors[name] != nil
    }

    func invoke(providerName: String, verb: [String], stdin: Data?,
                timeout: TimeInterval) async throws -> ProviderResult {
        guard let config = providers[providerName] ?? loadAdHoc(named: providerName) else {
            throw RemoteProviderError.unknownProvider(providerName)
        }
        let result = try await runner.run(config, verb: verb, stdin: stdin, timeout: timeout)
        if let failure = result.failureClass {
            recordFailure(provider: providerName, class: failure, result: result)
        } else {
            markHealthy(provider: providerName)
        }
        return result
    }

    /// Tests (and a pre-`start()` RPC call) can address providers straight
    /// from the registry file.
    private func loadAdHoc(named name: String) -> RemoteProviderConfig? {
        guard let configs = try? RemoteProviderRegistry.load(from: registryURL),
              let config = configs.first(where: { $0.name == name }) else { return nil }
        registerIfNeeded(config)
        return config
    }

    /// Registers a provider config (if not already known) and seeds a
    /// default `ok` health entry (if not already present). Shared by every
    /// entry point that can be a provider's first contact with this actor
    /// (`loadRegistryAndDescribe`, `pollOnce`, `loadAdHoc`).
    private func registerIfNeeded(_ config: RemoteProviderConfig) {
        if providers[config.name] == nil { providers[config.name] = config }
        if health[config.name] == nil { health[config.name] = (.ok, nil, nil) }
    }

    func providerStatuses() -> [RemoteProviderStatus] {
        providers.values.sorted { $0.name < $1.name }.map { config in
            let h = health[config.name] ?? (.ok, nil, nil)
            return RemoteProviderStatus(
                config: config, describe: describes[config.name],
                health: h.state, errorMessage: h.message,
                remediationLabel: h.remediation?.label,
                remediationCommand: h.remediation?.command)
        }
    }

    private func recordFailure(provider: String, class failureClass: ProviderFailureClass,
                               result: ProviderResult) {
        let error = result.decodedError
        switch failureClass {
        case .authNeeded:
            setHealth(provider: provider, to: (.needsAuth, error?.message, error?.remediation))
        case .transient:
            setHealth(provider: provider, to: (.stale, error?.message ?? result.stderr, nil))
        case .permanent, .contractBug:
            setHealth(provider: provider, to: (.error, error?.message ?? result.stderr, nil))
        }
    }

    private func markHealthy(provider: String) {
        setHealth(provider: provider, to: (.ok, nil, nil))
    }

    private func setHealth(provider: String,
                           to new: (ProviderHealth, String?, ProviderRemediation?)) {
        let old = health[provider]
        health[provider] = new
        if old?.state != new.0 {
            subscriptions.broadcast(delta: .remoteSessionsChanged)
        }
    }
}

enum RemoteProviderError: Error {
    case unknownProvider(String)
}
