import Foundation
import os
import TBDShared

private let remoteLogger = Logger(subsystem: "com.tbd.daemon", category: "remote")

public struct RemoteProviderStatus: Codable, Sendable {
    public let config: RemoteProviderConfig
    public let describe: ProviderDescribe?
    public let health: ProviderHealth
    public let errorMessage: String?
    public let remediationLabel: String?
    public let remediationCommand: String?
}

/// Owns the remote-backend feature at runtime: registry, describe cache,
/// per-provider poll loops, provider health, and pass-through invocations.
/// Source of truth for sessions is always the provider; this actor only
/// maintains the mirror + broadcasts.
actor RemoteProviderManager {
    private let db: TBDDatabase
    private let subscriptions: StateSubscriptionManager
    private let runner: any RemoteProviderInvoking
    private let registryURL: URL
    static let pollInterval: TimeInterval = 60

    private var providers: [String: RemoteProviderConfig] = [:]
    private var describes: [String: ProviderDescribe] = [:]
    private var health: [String: (state: ProviderHealth, message: String?, remediation: ProviderRemediation?)] = [:]
    private var loops: [String: Task<Void, Never>] = [:]
    private var supervisors: [String: ProviderEventsSupervisor] = [:]

    init(db: TBDDatabase, subscriptions: StateSubscriptionManager,
         runner: any RemoteProviderInvoking, registryURL: URL) {
        self.db = db
        self.subscriptions = subscriptions
        self.runner = runner
        self.registryURL = registryURL
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
    func loadRegistryAndDescribe() async {
        let configs: [RemoteProviderConfig]
        do {
            configs = try RemoteProviderRegistry.load(from: registryURL)
        } catch {
            remoteLogger.error("provider registry unreadable: \(String(describing: error), privacy: .public)")
            return
        }
        for config in configs {
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
    private func spawnPollLoops() async {
        await stopAll()
        for name in describes.keys {
            guard let config = providers[name] else { continue }
            await startLoop(for: config)
        }
    }

    func stopAll() async {
        for task in loops.values { task.cancel() }
        loops.removeAll()
        for supervisor in supervisors.values { await supervisor.stop() }
        supervisors.removeAll()
    }

    /// The 60s `list` poll is the universal floor for every provider,
    /// events-capable or not — it keeps running even when a stream is up,
    /// since snapshot application is idempotent and this is what covers a
    /// stream that's down or restarting. Providers that declared the
    /// `events` capability in their cached `describe` additionally get a
    /// supervised low-latency NDJSON stream.
    private func startLoop(for config: RemoteProviderConfig) async {
        if describes[config.name]?.capabilities.contains("events") == true {
            let supervisor = ProviderEventsSupervisor(config: config, manager: self)
            supervisors[config.name] = supervisor
            // Awaited, not fired off as a detached `Task`: a queued `start()`
            // could otherwise land AFTER a concurrent `stopAll()` had already
            // stopped (a no-op, since nothing was started yet) and dropped this
            // supervisor, arming a supervision loop on an object nobody holds —
            // provider children respawning on backoff for the daemon's life
            // with no way to reach them.
            await supervisor.start()
        }
        loops[config.name] = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce(provider: config)
                try? await Task.sleep(for: .seconds(Self.pollInterval))
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
                kind: session.agentState.rawValue, reason: session.agentStateReason)))
        }
    }

    /// Single-session upsert from an events `session` line. No absence
    /// bookkeeping happens here — only `apply(snapshot:)` drives the
    /// two-absence rule, since only a full snapshot can tell what's missing.
    func applyUpsert(_ session: RemoteSessionPayload, provider: String) async {
        let outcome = try? await db.remoteSessions.upsertOne(
            provider: provider, session: session, now: Date())
        guard let outcome else { return }
        if outcome.changed {
            subscriptions.broadcast(delta: .remoteSessionsChanged)
        }
        for session in outcome.attention {
            subscriptions.broadcast(delta: .remoteSessionAttention(RemoteSessionAttentionDelta(
                provider: provider, sessionID: session.id, title: session.title,
                kind: session.agentState.rawValue, reason: session.agentStateReason)))
        }
    }

    /// Explicit removal from an events `removed` line. The provider is
    /// authoritative about this — skip the two-absence rule entirely and
    /// mark the row gone immediately.
    func applyRemoval(sessionID: String, provider: String) async {
        let changed = try? await db.remoteSessions.markGone(
            provider: provider, sessionID: sessionID)
        if changed == true {
            subscriptions.broadcast(delta: .remoteSessionsChanged)
        }
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
