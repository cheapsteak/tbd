import Foundation
import os
import TBDShared

private let remoteLogger = Logger(subsystem: "com.tbd.daemon", category: "remote")

public struct RemoteProviderStatus: Codable, Sendable {
    public let config: RemoteProviderConfig
    public let describe: ProviderDescribe?
    public let health: String          // "ok" | "stale" | "needs_auth" | "error"
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
    private var health: [String: (state: String, message: String?, remediation: ProviderRemediation?)] = [:]
    private var loops: [String: Task<Void, Never>] = [:]

    init(db: TBDDatabase, subscriptions: StateSubscriptionManager,
         runner: any RemoteProviderInvoking, registryURL: URL) {
        self.db = db
        self.subscriptions = subscriptions
        self.runner = runner
        self.registryURL = registryURL
    }

    func start() async {
        let configs: [RemoteProviderConfig]
        do {
            configs = try RemoteProviderRegistry.load(from: registryURL)
        } catch {
            remoteLogger.error("provider registry unreadable: \(String(describing: error), privacy: .public)")
            return
        }
        for config in configs {
            providers[config.name] = config
            health[config.name] = ("ok", nil, nil)
            // describe is offline-by-contract; a failure is a provider bug.
            if let result = try? await runner.run(config, verb: ["describe"], stdin: nil, timeout: 10),
               result.exitCode == 0,
               let describe = try? result.decoded(ProviderDescribe.self) {
                if describe.contractVersions.contains(1) {
                    describes[config.name] = describe
                } else {
                    health[config.name] = ("error", "no common contract version", nil)
                    continue
                }
            } else {
                health[config.name] = ("error", "describe failed", nil)
                continue
            }
            startLoop(for: config)
        }
        subscriptions.broadcast(delta: .remoteSessionsChanged)
    }

    func stopAll() {
        for task in loops.values { task.cancel() }
        loops.removeAll()
    }

    private func startLoop(for config: RemoteProviderConfig) {
        // Events supervision replaces this in Task 6 when the capability is
        // declared; the 60s list poll is the universal floor.
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
        if providers[provider.name] == nil { providers[provider.name] = provider }
        if health[provider.name] == nil { health[provider.name] = ("ok", nil, nil) }
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
            setHealth(provider: provider.name, to: ("stale", String(describing: error), nil))
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
        providers[name] = config
        if health[name] == nil { health[name] = ("ok", nil, nil) }
        return config
    }

    func providerStatuses() -> [RemoteProviderStatus] {
        providers.values.sorted { $0.name < $1.name }.map { config in
            let h = health[config.name] ?? ("ok", nil, nil)
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
            setHealth(provider: provider, to: ("needs_auth", error?.message, error?.remediation))
        case .transient:
            setHealth(provider: provider, to: ("stale", error?.message ?? result.stderr, nil))
        case .permanent, .contractBug:
            setHealth(provider: provider, to: ("error", error?.message ?? result.stderr, nil))
        }
    }

    private func markHealthy(provider: String) {
        setHealth(provider: provider, to: ("ok", nil, nil))
    }

    private func setHealth(provider: String,
                           to new: (String, String?, ProviderRemediation?)) {
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
