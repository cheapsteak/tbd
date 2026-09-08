import Foundation
import TBDShared
import os

/// The `NO_PROXY` value a proxied session is spawned with.
///
/// The session's `ANTHROPIC_BASE_URL` now names a loopback port, and a machine
/// behind a corporate HTTP proxy would otherwise send that request through it —
/// the outbound proxy answers for names it can resolve, and `127.0.0.1` is not
/// one of them. So loopback is added to whatever exception list the session was
/// already going to get, rather than replacing it: the *upstream* leg is made by
/// `TBDModelProxy`, in a process that reads the same `NO_PROXY`, and a session
/// whose corporate exceptions were dropped here would still reach the proxy and
/// then fail one hop later.
enum ModelProxyEnv {
    /// The entries a proxied session must never send through an outbound proxy.
    static let loopbackEntries = ["127.0.0.1", "localhost"]

    /// `existing` with `127.0.0.1,localhost` appended, without duplicates and
    /// without reordering what was already there.
    ///
    /// Idempotent by construction: a value this function produced already
    /// contains both entries, so a second pass adds nothing. That matters
    /// because a wake re-derives the whole environment from the same overrides
    /// the create path used, and a non-idempotent merge would grow the variable
    /// by two entries per park/wake cycle.
    static func noProxy(extending existing: String?) -> String {
        var seen = Set<String>()
        var entries: [String] = []
        for raw in (existing ?? "").split(separator: ",") {
            let entry = raw.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty, seen.insert(entry).inserted else { continue }
            entries.append(entry)
        }
        for entry in loopbackEntries where seen.insert(entry).inserted {
            entries.append(entry)
        }
        return entries.joined(separator: ",")
    }
}

/// What `daemon.capabilities` reports about the model proxy, read from the
/// supervisor in one actor hop.
///
/// One value rather than three awaited properties because the three facts are
/// only meaningful together: a port and a version that came from either side of
/// a replacement would describe a proxy that never existed.
struct ModelProxyCapabilitySnapshot: Sendable, Equatable {
    /// A `TBDModelProxy` sits beside this daemon **and** the supervisor has not
    /// given up on it. Both halves, because a daemon that hit a configuration
    /// defect still has the binary and would otherwise keep answering
    /// "supported" while routing nothing.
    let supported: Bool
    let port: Int?
    let version: String?

    /// The answer when no supervisor is wired at all.
    static let none = ModelProxyCapabilitySnapshot(
        supported: false, port: nil, version: nil)
}

/// The routes half of `ModelProxySupervisor`, as the spawn and teardown paths
/// use it.
///
/// A protocol rather than the actor itself so the spawn decision below is
/// testable without a proxy process, a port, or a rendezvous directory. Every
/// requirement is `async` because the witness is an actor's isolated member.
protocol ModelProxyRouting: Sendable {
    func makeRoute(
        terminalID: UUID, upstream: String, streamingEnabled: Bool
    ) async throws -> ModelProxyRoute
    func baseURL(for route: ModelProxyRoute) async -> String?
    func retireRoute(token: String, terminalID: UUID) async
    func routeToken(forTerminal terminalID: UUID) async -> String?
}

/// Everything the daemon asks of the supervisor. `RPCRouter` holds this one
/// because it retires routes (terminal deletion), reports capabilities, and
/// carries the flag's runtime flip; the two lifecycle types hold the narrower
/// `ModelProxyRouting`.
protocol ModelProxySupervising: ModelProxyRouting {
    func capabilitySnapshot() async -> ModelProxyCapabilitySnapshot
    /// Start supervising, if `config.model_proxy_enabled` is on. Idempotent.
    func startIfEnabled() async
    /// Stop supervising and ask the running proxy to retire — what turning the
    /// flag off means, as distinct from the `stop()` a shutdown performs.
    func retireProxy() async
}

extension ModelProxySupervisor: ModelProxySupervising {}

/// **The one decision every holder spawn site makes about the model proxy.**
///
/// It is a free function rather than a method on the supervisor because most of
/// what it decides is not the supervisor's business: the config flags, the
/// profile kind, the user's own `settings.json`, and the env overrides. The
/// supervisor is asked exactly once, at the end, and only when the answer can
/// still be used.
///
/// Its governing rule, from the spec ("The daemon" → "Spawn"): **a streaming
/// nicety never blocks a spawn.** Every refusal below returns the caller's own
/// environment unchanged and a nil stream path, so the session starts exactly as
/// it would have without the feature. The loud ones log at `.error` — they name
/// a proxy that should have been there and was not — and the quiet ones do not,
/// because a disabled flag or a Bedrock profile is not a fault.
enum ModelProxyRouteAttachment {
    private static let logger = Logger(
        subsystem: "com.tbd.daemon", category: "model-proxy")

    /// The public API, when neither the profile nor the env overrides name one.
    static let defaultUpstream = "https://api.anthropic.com"

    /// What a spawn site takes away: the process environment to launch with,
    /// and the stream file to stamp on the row (nil when the session is
    /// unproxied).
    struct Outcome: Sendable {
        let sensitiveEnv: [String: String]
        /// The proxy URL a routed spawn talks to — `http://127.0.0.1:<port>/r/<token>`
        /// — and nil for every unrouted outcome.
        ///
        /// Held rather than re-derived because `builderBaseURL` has to hand the
        /// spawn builder the *same* value the process environment carries; two
        /// derivations of one URL is exactly the kind of near-miss that would
        /// leave a session on a route the daemon does not think it is on.
        let baseURL: String?
        let streamPath: String?
        /// The route this attachment minted, for a caller that has to drop
        /// *this* route rather than whatever route the terminal currently
        /// holds. The distinction is not academic: a wake that ends up adopting
        /// a live holder instead of spawning has two routes in play — the one
        /// it just minted and the one the running session is already using —
        /// and dropping them by terminal id would pick whichever the directory
        /// listed first, which half the time is the live session's.
        let token: String?

        /// The session runs against the model API directly, as it always did.
        static func unproxied(_ sensitiveEnv: [String: String]) -> Outcome {
            Outcome(sensitiveEnv: sensitiveEnv, baseURL: nil, streamPath: nil, token: nil)
        }

        /// A route was minted and this spawn will run against it.
        ///
        /// **Read before `ClaudeSpawnCommandBuilder.build`, not after.** The
        /// builder is given `builderBaseURL`, which needs this decision to have
        /// been made already.
        var routed: Bool { token != nil }

        /// The `profileBaseURL` `ClaudeSpawnCommandBuilder.build` must be given
        /// for this spawn: **the route's own URL once a route is in play**, and
        /// the profile's otherwise.
        ///
        /// The builder does two things with this value — it puts it in the
        /// spawn's `sensitiveEnv`, and it re-exports it inline into the command
        /// string, where the export runs *after* the shell's rc files. That
        /// second half is a defence, not a redundancy: a user whose `.zshrc`
        /// sets `ANTHROPIC_BASE_URL` would otherwise have it clobber whatever
        /// the process environment carried, and a routed session would go
        /// straight to that endpoint while the row recorded a stream file that
        /// never fills. The profile's URL has always been defended that way;
        /// once a route replaces it as the endpoint this session must reach, the
        /// route needs the same defence.
        ///
        /// **So the proxy URL is carried twice, in the environment and in the
        /// inline export, and the duplication is deliberate** — they are one
        /// value from one field, so they cannot disagree, and the second is what
        /// survives an rc file.
        ///
        /// It puts the route token in the job's argv, where any process running
        /// as this user can read it with `ps -ww`. That is not a widening: the
        /// route files under `~/tbd/proxy/routes/` are mode-0700 in a directory
        /// the same user owns, so every token is already readable by exactly
        /// that set of processes. Losing the rc-file defence would be a real
        /// failure; this is not one.
        ///
        /// A named function rather than a ternary at each spawn site, because
        /// the two sites are the create path and the wake path and a third will
        /// exist one day: the expression is the whole fix, it is easy to leave
        /// out, and leaving it out fails silently. As a function it is
        /// greppable, it is one thing to get right, and it has a test of its
        /// own.
        func builderBaseURL(profile: String?) -> String? {
            baseURL ?? profile
        }

        /// The same attachment carrying `environment` instead.
        ///
        /// The routing decision is made before the spawn command is composed,
        /// and the launch environment is only complete after it — the builder's
        /// auth env merges on top. This is how the two meet: the decision keeps
        /// its route and stream path, and the caller substitutes the
        /// environment it will actually launch with, so no spawn site can hold
        /// an attachment whose environment is not the one it uses.
        func withEnvironment(_ environment: [String: String]) -> Outcome {
            Outcome(
                sensitiveEnv: environment, baseURL: baseURL,
                streamPath: streamPath, token: token)
        }
    }

    static func attach(
        terminalID: UUID,
        config: Config,
        profileKind: CredentialKind?,
        profileBaseURL: String?,
        envOverrideBaseURL: String?,
        overlaySetsBaseURL: Bool,
        sensitiveEnv: [String: String],
        baseEnvironment: [String: String],
        supervisor: (any ModelProxyRouting)?
    ) async -> Outcome {
        guard config.modelProxyEnabled else { return .unproxied(sensitiveEnv) }
        // Bedrock speaks to AWS, not to the Messages API, and its spawn env
        // deliberately carries no `ANTHROPIC_BASE_URL` at all
        // (`ClaudeSpawnCommandBuilder.routingEnv`). Setting one here would not
        // route it through the proxy; it would give a Bedrock session a
        // variable it is not supposed to have.
        guard profileKind != .bedrock else { return .unproxied(sensitiveEnv) }
        // No supervisor is the ordinary state of a daemon built without one
        // (mock mode, most tests). It is not a fault and is not logged.
        guard let supervisor else { return .unproxied(sensitiveEnv) }
        if overlaySetsBaseURL {
            // Claude Code reads `settings.json`'s `env` block *after* the
            // process environment, so the overlay wins and the session would
            // talk to the user's endpoint while TBD believed it was proxied —
            // a stream file that never fills and a route nothing uses. Spawn
            // without one rather than fight the setting.
            logger.error("""
                model proxy skipped: settings overlay sets ANTHROPIC_BASE_URL for terminal \
                \(terminalID.uuidString, privacy: .public)
                """)
            return .unproxied(sensitiveEnv)
        }

        let upstream = nonEmpty(profileBaseURL)
            ?? nonEmpty(envOverrideBaseURL)
            ?? defaultUpstream
        let route: ModelProxyRoute
        do {
            route = try await supervisor.makeRoute(
                terminalID: terminalID,
                upstream: upstream,
                // The conjunction, never the raw column: streaming with the
                // proxy off is not a state a route may describe.
                streamingEnabled: config.transcriptStreamingEffective)
        } catch {
            // The kind is public and the description is not, because the
            // description can carry the token: `ModelProxyRouteStore.Failure
            // .invalidToken` interpolates it verbatim, and a write error from
            // the route store names a path whose last component is
            // `<token>.json`. A route token is a bearer credential for this
            // session's upstream, and the system log is world-readable to
            // anything running as this user.
            logger.error("""
                model proxy route unavailable, spawning unproxied: terminal \
                \(terminalID.uuidString, privacy: .public): \
                \(Self.errorKind(error), privacy: .public) \
                (\(error.localizedDescription, privacy: .private))
                """)
            return .unproxied(sensitiveEnv)
        }
        guard let baseURL = await supervisor.baseURL(for: route) else {
            // The proxy went away between minting the route and naming its
            // port. The route file exists and nothing will ever be spawned
            // against it, so retire it here rather than leave it for the sweep.
            logger.error("""
                model proxy route unavailable, spawning unproxied: no live proxy to name for \
                terminal \(terminalID.uuidString, privacy: .public)
                """)
            await supervisor.retireRoute(token: route.token, terminalID: terminalID)
            return .unproxied(sensitiveEnv)
        }

        var env = sensitiveEnv
        env["ANTHROPIC_BASE_URL"] = baseURL
        env["NO_PROXY"] = ModelProxyEnv.noProxy(
            extending: sensitiveEnv["NO_PROXY"] ?? baseEnvironment["NO_PROXY"])
        return Outcome(
            sensitiveEnv: env,
            baseURL: baseURL,
            streamPath: TBDConstants.streamFilePath(
                terminalID: terminalID, environment: baseEnvironment),
            token: route.token)
    }

    /// Drops one named route, for a caller holding the token of the route it
    /// itself minted. Use this — never the terminal-id form below — to undo an
    /// attachment whose spawn did not happen.
    ///
    /// The outcome is optional because a spawn site that never attempted a
    /// route holds no outcome at all: there is deliberately no "empty" `Outcome`
    /// to stand in for one. See `WorktreeLifecycle+Create`'s `primaryAttachment`.
    static func retire(
        _ outcome: Outcome?, terminalID: UUID, supervisor: (any ModelProxyRouting)?
    ) async {
        guard let supervisor, let token = outcome?.token else { return }
        await supervisor.retireRoute(token: token, terminalID: terminalID)
        logger.debug(
            "retired an unused model proxy route for terminal \(terminalID.uuidString, privacy: .public)")
    }

    /// Drops whatever route this terminal holds, if any.
    ///
    /// The one door every teardown, park and reclaim path goes through, so the
    /// "find the token, then retire it" pair cannot be half-written anywhere.
    /// Best-effort and never throwing: a route the proxy will not drop is
    /// unlinked by `retireRoute` itself, and one this daemon cannot even find is
    /// the `OrphanGC` leg's.
    static func retire(terminalID: UUID, supervisor: (any ModelProxyRouting)?) async {
        guard let supervisor,
              let token = await supervisor.routeToken(forTerminal: terminalID) else { return }
        await supervisor.retireRoute(token: token, terminalID: terminalID)
        logger.debug("""
            retired the model proxy route for terminal \
            \(terminalID.uuidString, privacy: .public)
            """)
    }

    /// A short name for why a route could not be minted, carrying nothing a
    /// route file's path or a token could hide in.
    ///
    /// It is what the operator actually needs — "the store refused the token"
    /// versus "the rename failed" — and it is the half of the diagnostic that
    /// can be logged publicly. `errno` is included because it names an OS
    /// condition and cannot carry a credential.
    static func errorKind(_ error: any Error) -> String {
        if let failure = error as? ModelProxyRouteStore.Failure {
            switch failure {
            case .invalidToken:
                return "invalid-token"
            case .renameFailed(let code):
                return "rename-failed(errno \(code))"
            }
        }
        if error is ModelProxySupervisor.RouteError { return "no-proxy" }
        return String(describing: type(of: error))
    }

    /// A configured value, or nil for one that is present but says nothing.
    /// A profile whose base URL is the empty string must fall through to the
    /// next source rather than become an upstream nothing can connect to.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
