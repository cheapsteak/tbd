import Foundation
import os

private let registryLogger = Logger(subsystem: "com.tbd.daemon", category: "remote")

/// Decode-time diagnostics for the provider contract. A provider's output is
/// untrusted input, so what TBD had to drop from it is a fact worth being able
/// to read back — but only ever the shape of the damage, never the payload.
private let contractLogger = Logger(subsystem: "com.tbd.daemon", category: "remote.contract")

// MARK: - Remote provider contract types (docs/remote-provider-contract.md, v1)

/// One registered provider from `~/tbd/agent-providers.json`.
public struct RemoteProviderConfig: Codable, Sendable, Equatable {
    public let name: String
    public let exec: String
    public let args: [String]?
    public init(name: String, exec: String, args: [String]? = nil) {
        self.name = name; self.exec = exec; self.args = args
    }
    public var argv: [String] { [exec] + (args ?? []) }
}

/// Process-liveness axis. Unknown raw values decode as `.unknown` so a newer
/// provider never breaks an older TBD (contract: ignore what you don't know).
public enum RemoteProcessState: String, Codable, Sendable {
    case starting, running, exited, unknown
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RemoteProcessState(rawValue: raw) ?? .unknown
    }
}

/// Agent-attention axis ("does the human need to look").
public enum RemoteAgentState: String, Codable, Sendable {
    case working
    case waitingInput = "waiting_input"
    case idle, exited, unknown
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RemoteAgentState(rawValue: raw) ?? .unknown
    }
}

/// Provider health as tracked by `RemoteProviderManager` and surfaced to the
/// app over the wire (`RemoteProviderStatus.health`, later tasks' RPC
/// results, and UI code). Raw values are deliberately explicit snake_case —
/// they're a wire contract other code matches on, not derived Swift casing.
public enum ProviderHealth: String, Codable, Sendable {
    case ok
    case stale
    case needsAuth = "needs_auth"
    case error
}

/// How a failing provider invocation is classified
/// (`docs/remote-provider-contract.md` § Error model). Lives here rather
/// than daemon-side because the app classifies exits too: an `attach`
/// process is spawned locally by the app, so its exit code never passes
/// through the daemon's runner.
public enum ProviderFailureClass: Sendable, Equatable {
    case permanent, contractBug, transient, authNeeded

    /// The contract's classification of record: the exit code alone.
    /// `nil` for exit 0 — a success is not a failure of any class.
    public init?(exitCode: Int32) {
        switch exitCode {
        case 0: return nil
        case 2: self = .contractBug
        case 3: self = .transient
        case 4: self = .authNeeded
        default: self = .permanent   // 1 and anything undeclared
        }
    }

    /// The contract's well-known `error.code` values that mean the PROVIDER
    /// itself can no longer authenticate — the codes whose remedy is "a
    /// human re-authenticates", regardless of which exit code the provider
    /// happened to pair them with.
    ///
    /// Deliberately does NOT include `credential_unresolvable`: per the
    /// contract that code means a `credential_ref` didn't resolve against
    /// the provider's own secret store, whose remedy is provisioning on the
    /// provider side, not re-authentication. It is a distinct code and stays
    /// a distinct state.
    ///
    /// This set is contract-derived and provider-agnostic — TBD never
    /// interprets any other part of a provider's error object.
    public static let authErrorCodes: Set<String> = ["auth_expired", "auth_missing"]

    /// Classifies a failing invocation from BOTH available signals,
    /// preferring the error object's `code` for precision while keeping the
    /// exit class authoritative.
    ///
    /// The rule, in one line: **auth-needed is the UNION of "exit class is
    /// `.authNeeded`" and "`error.code` is one of `authErrorCodes`";
    /// otherwise the exit class alone decides.** It is a union, not an
    /// override, because the two signals are independently informative — a
    /// provider may exit 4 while emitting a `code` TBD has never heard of
    /// (the exit class is the contract's classification of record and still
    /// wins), and a provider may exit 1 while naming `auth_expired`
    /// precisely (the code adds precision the exit class lacks).
    ///
    /// Exit 0 is success and returns `nil` whatever the stdout happens to
    /// decode as: a verb that exited 0 did not fail, so there is no failure
    /// to classify.
    public static func classify(exitCode: Int32, error: ProviderErrorObject?) -> ProviderFailureClass? {
        guard let exitClass = ProviderFailureClass(exitCode: exitCode) else { return nil }
        if let code = error?.code, authErrorCodes.contains(code) { return .authNeeded }
        return exitClass
    }
}

/// The contract's Session object. Timestamps stay ISO-8601 strings — TBD
/// displays them and compares equality; it never does date math on them.
public struct RemoteSessionPayload: Codable, Sendable, Equatable {
    public let id: String
    public let title: String?
    public let createdAt: String?
    public let state: RemoteProcessState
    public let exitCode: Int?
    public let agentState: RemoteAgentState
    public let agentStateReason: String?
    public let agentStateAt: String?
    public let meta: [String: String]?
    /// Retirement-from-inventory claim, per the provider contract's
    /// `archived` field. `nil` means the provider made no claim (absent);
    /// `.some(false)`/`.some(true)` is an explicit claim. Deliberately NOT
    /// collapsed to a non-optional `Bool` — the filing-sync authority rule
    /// (docs/specs/2026-08-16-remote-lane-archive-design.md §"Whose report
    /// counts") must distinguish "no claim" from "explicit false", and
    /// collapsing this at decode would destroy that distinction. Use
    /// `isArchived` for display, which supplies the contract's
    /// absent-reads-as-false semantics.
    public let archived: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, state, meta, archived
        case createdAt = "created_at"
        case exitCode = "exit_code"
        case agentState = "agent_state"
        case agentStateReason = "agent_state_reason"
        case agentStateAt = "agent_state_at"
    }

    public init(id: String, title: String? = nil, createdAt: String? = nil,
                state: RemoteProcessState, exitCode: Int? = nil,
                agentState: RemoteAgentState = .unknown,
                agentStateReason: String? = nil, agentStateAt: String? = nil,
                meta: [String: String]? = nil, archived: Bool? = nil) {
        self.id = id; self.title = title; self.createdAt = createdAt
        self.state = state; self.exitCode = exitCode
        self.agentState = agentState; self.agentStateReason = agentStateReason
        self.agentStateAt = agentStateAt; self.meta = meta; self.archived = archived
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        state = try c.decodeIfPresent(RemoteProcessState.self, forKey: .state) ?? .unknown
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
        agentState = try c.decodeIfPresent(RemoteAgentState.self, forKey: .agentState) ?? .unknown
        agentStateReason = try c.decodeIfPresent(String.self, forKey: .agentStateReason)
        agentStateAt = try c.decodeIfPresent(String.self, forKey: .agentStateAt)
        meta = Self.decodeMeta(from: c, sessionID: id)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived)
    }

    /// `meta` decoded leniently, and never fatally.
    ///
    /// The contract calls `meta` a flat string-to-string map of display pairs,
    /// and it also calls the whole Session object untrusted input a caller must
    /// degrade gracefully on. Those two together decide this: a value that is
    /// not a string costs its own key and nothing else — not the session, and
    /// not (via the enclosing array) the rest of the fleet.
    ///
    /// Scalars are coerced rather than dropped because a map of display pairs
    /// can display them unambiguously; objects, arrays and nulls are dropped
    /// because there is no one right way to render them and inventing one would
    /// put a caller-chosen string where a provider-chosen one belongs.
    private static func decodeMeta(
        from c: KeyedDecodingContainer<CodingKeys>, sessionID: String
    ) -> [String: String]? {
        // `meta` absent, null, or not an object at all: no map, still a session.
        guard let raw = try? c.decodeIfPresent([String: MetaValue].self, forKey: .meta) else {
            return nil
        }
        var kept: [String: String] = [:]
        var dropped: [String] = []
        for (key, value) in raw {
            if let literal = value.literal {
                kept[key] = literal
            } else {
                dropped.append(key)
            }
        }
        if !dropped.isEmpty {
            // Keys only. A provider-defined map may carry anything, so the
            // values never reach the log.
            contractLogger.debug(
                """
                session \(sessionID, privacy: .public): dropped \(dropped.count, privacy: .public) \
                non-scalar meta key(s): \(dropped.sorted().joined(separator: ", "), privacy: .public)
                """
            )
        }
        return kept
    }

    /// One `meta` value, decoded down to the string a display map can show.
    /// `literal` is nil for anything with no unambiguous literal form — an
    /// object, an array, or an explicit null.
    private struct MetaValue: Decodable {
        let literal: String?

        init(from decoder: any Decoder) throws {
            guard let c = try? decoder.singleValueContainer(), !c.decodeNil() else {
                literal = nil
                return
            }
            if let s = try? c.decode(String.self) { literal = s; return }
            if let b = try? c.decode(Bool.self) { literal = b ? "true" : "false"; return }
            // Int before Double so a whole number reads as `42`, not `42.0`.
            if let i = try? c.decode(Int.self) { literal = String(i); return }
            if let d = try? c.decode(Double.self) { literal = String(d); return }
            literal = nil
        }
    }

    /// The contract's absent-reads-as-`false` display semantics. The sync
    /// path must NOT use this — it needs to distinguish "no claim" (nil) from
    /// an explicit `false`, so it reads `archived` directly.
    public var isArchived: Bool { archived ?? false }

    /// A presentation-safe projection for a cached row whose provider has
    /// failed to produce a fresh inventory. The mirror keeps the last good
    /// payload intact for recovery and diagnostics, but callers must not
    /// continue asserting that an active terminal or agent is still alive.
    ///
    /// A previously observed terminal exit remains a valid historical fact;
    /// only non-terminal/unknown rows are demoted. In every demoted case the
    /// agent axis also becomes unknown so a cached `working` or
    /// `waiting_input` value cannot keep rendering as current activity.
    ///
    /// This projection demotes only the liveness axis (`state`,
    /// `agentState`, `agentStateReason`) to `.unknown` — the fact this
    /// snapshot is stale says nothing about the filing axis, so `archived`
    /// must be threaded through unchanged. Filing and liveness are separate
    /// axes throughout this feature; a field that collapses them here lies
    /// about one of them. When adding a field to this type, decide which
    /// axis it belongs to before deciding whether it survives this
    /// projection.
    public func projectedForStaleSnapshot() -> RemoteSessionPayload {
        guard state != .exited else { return self }
        return RemoteSessionPayload(
            id: id, title: title, createdAt: createdAt,
            state: .unknown, exitCode: exitCode, agentState: .unknown,
            agentStateReason: nil, agentStateAt: agentStateAt, meta: meta,
            archived: archived)
    }
}

public struct RemoteSessionListEnvelope: Codable, Sendable {
    public let sessions: [RemoteSessionPayload]
    /// Whether `sessions` is the provider's ENTIRE inventory or only part of
    /// it (`docs/remote-provider-contract.md` § Snapshot completeness).
    ///
    /// An incomplete snapshot is authoritative about **presence only**: a
    /// caller may adopt and update on it, and MUST NOT retire anything on it
    /// or treat it as refreshing freshness. Absent reads as `true`, so every
    /// provider written before this field keeps its exact current meaning.
    public let complete: Bool

    public init(sessions: [RemoteSessionPayload], complete: Bool = true) {
        self.sessions = sessions
        self.complete = complete
    }

    private enum CodingKeys: String, CodingKey {
        case sessions, complete
    }

    /// Hand-written so `complete` can default when absent: Swift's
    /// synthesized `init(from:)` ignores property default values, and the
    /// contract's absent-means-complete rule is the whole reason a v1
    /// provider needs no edit.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.decode(LenientSessionArray.self, forKey: .sessions).sessions
        complete = try c.decodeIfPresent(Bool.self, forKey: .complete) ?? true
    }
}

/// An inventory of sessions, decoded element by element, so one malformed
/// session costs one session.
///
/// A plain `[RemoteSessionPayload]` fails whole on its first bad element,
/// which turns one contract-violating session into a failed inventory for the
/// entire provider — every remote row goes stale at once, and the fleet
/// disappears from view because of a session nobody was looking at. Both places
/// a provider enumerates its fleet decode through this: the `list` envelope and
/// the `events` stream's `snapshot` line.
///
/// A skipped session is simply absent from the snapshot, so the mirror's
/// absence bookkeeping starts counting it missing and may eventually mark it
/// gone. That is the honest reading of the only evidence there is: the provider
/// said nothing this caller could understand about that session.
public struct LenientSessionArray: Decodable, Sendable {
    public let sessions: [RemoteSessionPayload]

    public init(from decoder: any Decoder) throws {
        let elements = try [LenientSession](from: decoder)
        sessions = elements.compactMap(\.payload)
        let skipped = elements.filter { $0.payload == nil }
        if !skipped.isEmpty {
            // `.error`, not `.debug`: losing a session from the inventory is
            // significant, and the id is what makes it actionable when the
            // element was intact enough to carry one.
            let named = skipped.compactMap(\.id).sorted()
            contractLogger.error(
                """
                skipped \(skipped.count, privacy: .public) undecodable session(s) in a provider \
                inventory; ids: \(named.isEmpty ? "none recoverable" : named.joined(separator: ", "), privacy: .public)
                """
            )
        }
    }

    /// One array element, decoded without the power to fail the array.
    /// `payload` is nil for an element `RemoteSessionPayload` could not decode;
    /// `id` is recovered separately where it survives, since it is the only
    /// part of a broken element worth naming.
    private struct LenientSession: Decodable {
        let payload: RemoteSessionPayload?
        let id: String?

        init(from decoder: any Decoder) throws {
            let decoded = try? RemoteSessionPayload(from: decoder)
            payload = decoded
            if let decoded {
                id = decoded.id
            } else {
                let c = try? decoder.container(keyedBy: RemoteSessionPayload.CodingKeys.self)
                id = (try? c?.decodeIfPresent(String.self, forKey: .id)) ?? nil
            }
        }
    }
}

/// `describe` response.
public struct ProviderDescribe: Codable, Sendable {
    public let contractVersions: [Int]
    public let name: String
    public let providerVersion: String?
    public let capabilities: [String]
    public let createParams: [ProviderCreateParamField]

    enum CodingKeys: String, CodingKey {
        case name, capabilities
        case contractVersions = "contract_versions"
        case providerVersion = "provider_version"
        case createParams = "create_params"
    }

    /// Memberwise init for constructing fixtures directly (tests, previews)
    /// — the custom `init(from:)` below suppresses Swift's synthesized
    /// memberwise init, so without this the only way to build one was a
    /// round-trip through `JSONDecoder`.
    public init(contractVersions: [Int] = [1], name: String, providerVersion: String? = nil,
                capabilities: [String] = [], createParams: [ProviderCreateParamField] = []) {
        self.contractVersions = contractVersions
        self.name = name
        self.providerVersion = providerVersion
        self.capabilities = capabilities
        self.createParams = createParams
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contractVersions = try c.decode([Int].self, forKey: .contractVersions)
        name = try c.decode(String.self, forKey: .name)
        providerVersion = try c.decodeIfPresent(String.self, forKey: .providerVersion)
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        createParams = try c.decodeIfPresent([ProviderCreateParamField].self, forKey: .createParams) ?? []
    }
}

/// One field of the provider's create form. `type` stays a raw string so an
/// unknown future type renders as `string` instead of failing decode.
public struct ProviderCreateParamField: Codable, Sendable, Equatable {
    public let name: String
    public let type: String   // string | text | bool | int | enum
    public let label: String?
    public let required: Bool
    public let defaultValue: String?
    public let values: [String]?

    enum CodingKeys: String, CodingKey {
        case name, type, label, required, values
        case defaultValue = "default"
    }

    /// Memberwise init for constructing fixtures directly (tests, previews)
    /// — see `ProviderDescribe`'s equivalent init for why this is needed
    /// alongside a custom `init(from:)`.
    public init(name: String, type: String, label: String? = nil, required: Bool = false,
                defaultValue: String? = nil, values: [String]? = nil) {
        self.name = name
        self.type = type
        self.label = label
        self.required = required
        self.defaultValue = defaultValue
        self.values = values
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(String.self, forKey: .type)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
        defaultValue = try c.decodeIfPresent(String.self, forKey: .defaultValue)
        values = try c.decodeIfPresent([String].self, forKey: .values)
    }
}

/// Error envelope a failing verb prints on stdout.
public struct ProviderErrorEnvelope: Codable, Sendable {
    public let error: ProviderErrorObject
}

public struct ProviderErrorObject: Codable, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool?
    public let remediation: ProviderRemediation?
}

/// `Equatable` because the daemon diffs it: `RemoteProviderManager.setHealth`
/// broadcasts on any change to the (state, message, remediation) triple, not
/// just the state, so a probe that lands a remediation onto an already-
/// `needs_auth` provider still reaches the app.
public struct ProviderRemediation: Codable, Sendable, Equatable {
    public let label: String
    public let command: String?
}

/// One provider's negotiated contract + current health, as tracked by
/// `RemoteProviderManager` (daemon) and rendered by the app. Lives here (not
/// daemon-side) because `remote.providers` puts it on the wire.
public struct RemoteProviderStatus: Codable, Sendable, Identifiable {
    public let config: RemoteProviderConfig
    public let describe: ProviderDescribe?
    public let health: ProviderHealth
    public let errorMessage: String?
    public let remediationLabel: String?
    public let remediationCommand: String?
    /// Timestamp of the most recent complete `list` snapshot accepted into
    /// the mirror. Nil means this manager has not observed (or recovered
    /// from the mirror) a successful snapshot yet.
    public let lastSuccessfulSnapshotAt: Date?
    /// True when the daemon could not READ the persisted freshness row, so it
    /// cannot say whether a successful snapshot exists. Distinct from a nil
    /// `lastSuccessfulSnapshotAt`, which by itself cannot tell "confirmed
    /// never" apart from "unknown" — and only the former is safe to fail open
    /// on. Carried on the wire so this DTO reaches the same verdict as the
    /// daemon's authoritative `RemoteProviderManager.hasStaleSnapshot`; the two
    /// disagreeing is how cached rows once kept rendering as confidently
    /// running in exactly the case the daemon knew the least.
    public let freshnessUnreadable: Bool
    /// The contract major the daemon negotiated for this provider — the highest
    /// version both sides declare. Nil when `describe` has not succeeded, and
    /// nil in a payload from a daemon that predates negotiation; a reader with
    /// no value falls back to `1`, which is what every emitter announced
    /// unconditionally before.
    public let contractVersion: Int?
    public init(config: RemoteProviderConfig, describe: ProviderDescribe?, health: ProviderHealth,
                errorMessage: String?, remediationLabel: String?, remediationCommand: String?,
                lastSuccessfulSnapshotAt: Date? = nil, freshnessUnreadable: Bool = false,
                contractVersion: Int? = nil) {
        self.config = config; self.describe = describe; self.health = health
        self.errorMessage = errorMessage
        self.remediationLabel = remediationLabel; self.remediationCommand = remediationCommand
        self.lastSuccessfulSnapshotAt = lastSuccessfulSnapshotAt
        self.freshnessUnreadable = freshnessUnreadable
        self.contractVersion = contractVersion
    }

    private enum CodingKeys: String, CodingKey {
        case config, describe, health, errorMessage, remediationLabel, remediationCommand
        case lastSuccessfulSnapshotAt, freshnessUnreadable, contractVersion
    }

    /// Hand-written so `freshnessUnreadable` can default when absent: a
    /// payload from a daemon predating the field must still decode, and
    /// Swift's synthesized `init(from:)` ignores property default values.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        config = try c.decode(RemoteProviderConfig.self, forKey: .config)
        describe = try c.decodeIfPresent(ProviderDescribe.self, forKey: .describe)
        health = try c.decode(ProviderHealth.self, forKey: .health)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        remediationLabel = try c.decodeIfPresent(String.self, forKey: .remediationLabel)
        remediationCommand = try c.decodeIfPresent(String.self, forKey: .remediationCommand)
        lastSuccessfulSnapshotAt = try c.decodeIfPresent(Date.self, forKey: .lastSuccessfulSnapshotAt)
        freshnessUnreadable = try c.decodeIfPresent(Bool.self, forKey: .freshnessUnreadable) ?? false
        contractVersion = try c.decodeIfPresent(Int.self, forKey: .contractVersion)
    }

    /// True when there is cached state on screen that must stop being
    /// presented as current. Two ways to get there: a prior successful
    /// inventory that is now stale, or a freshness row the daemon could not
    /// read at all. A provider confirmed never to have snapshotted is
    /// deliberately excluded — there are no cached rows to project or stale
    /// controls to suppress.
    public var hasStaleSnapshot: Bool {
        Self.isStaleSnapshot(
            health: health,
            lastSuccessfulSnapshotAt: lastSuccessfulSnapshotAt,
            freshnessUnreadable: freshnessUnreadable)
    }

    /// The one definition of "stale snapshot", shared by this DTO and the
    /// daemon's `RemoteProviderManager.hasStaleSnapshot(provider:)`. It lives
    /// here as a static so the display projection and the RPC mutation gate
    /// cannot answer differently: when they did, the mutation gate failed
    /// closed while the session list went on rendering cached rows as running.
    public static func isStaleSnapshot(
        health: ProviderHealth, lastSuccessfulSnapshotAt: Date?, freshnessUnreadable: Bool
    ) -> Bool {
        health != .ok && (lastSuccessfulSnapshotAt != nil || freshnessUnreadable)
    }

    // Provider names are already the unique identity used everywhere else in
    // this codebase (`ForEach(appState.remoteProviders, id: \.config.name)`,
    // `RemoteProviderRegistry.load` rejects duplicates) — a computed `id`
    // here doesn't participate in `Codable` synthesis, so this is purely
    // additive. Lets a `RemoteProviderStatus?` drive `.sheet(item:)` instead
    // of `.sheet(isPresented:)` + `if let`, which can structurally present
    // an empty sheet.
    public var id: String { config.name }
}

/// Loads `agent-providers.json`. Missing file = no providers (not an error);
/// duplicate names or empty exec = configuration error.
public enum RemoteProviderRegistry {
    /// Names TBD's own compiled providers answer to. Reserved
    /// **unconditionally** and not behind the cloud flag: a name that became
    /// available when a feature was off and unavailable when it was turned on
    /// would change which providers load as a side effect of a toggle.
    public static let reservedProviderNames: Set<String> = [ClaudeCloudProvider.name]

    public static func isReserved(_ name: String) -> Bool {
        reservedProviderNames.contains(name)
    }

    /// What one registry file yielded: the entries TBD will use, and the
    /// reserved-name entries it stepped over.
    public struct RegistryLoad: Sendable, Equatable {
        public let configs: [RemoteProviderConfig]
        public let skippedReservedNames: [String]

        public init(configs: [RemoteProviderConfig], skippedReservedNames: [String]) {
            self.configs = configs
            self.skippedReservedNames = skippedReservedNames
        }
    }

    /// A reserved entry is SKIPPED, never a reason to reject the file. The
    /// skip is deliberately checked BEFORE the duplicate rule so two reserved
    /// entries are two skips rather than a whole-file failure — this function
    /// throws for the entire registry on a duplicate, and two of its three
    /// call sites swallow that with `try?`, so one bad entry would otherwise
    /// silently remove every provider the user registered. Each skip is
    /// logged here (rather than left for callers to notice) so it is
    /// surfaced regardless of which of the three call sites triggered it.
    public static func loadEntries(from url: URL) throws -> RegistryLoad {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return RegistryLoad(configs: [], skippedReservedNames: [])
        }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([RemoteProviderConfig].self, from: data)
        var configs: [RemoteProviderConfig] = []
        var skipped: [String] = []
        var seen = Set<String>()
        for c in decoded {
            guard !c.name.isEmpty, !c.exec.isEmpty else {
                throw RegistryError.invalidEntry(c.name)
            }
            if isReserved(c.name) {
                registryLogger.warning(
                    "skipping registry entry for reserved provider name \(c.name, privacy: .public): reserved for TBD's compiled provider"
                )
                skipped.append(c.name)
                continue
            }
            guard seen.insert(c.name).inserted else {
                throw RegistryError.duplicateName(c.name)
            }
            configs.append(c)
        }
        return RegistryLoad(configs: configs, skippedReservedNames: skipped)
    }

    public static func load(from url: URL) throws -> [RemoteProviderConfig] {
        try loadEntries(from: url).configs
    }

    public enum RegistryError: LocalizedError, Equatable {
        case invalidEntry(String)
        case duplicateName(String)

        public var errorDescription: String? {
            switch self {
            case .invalidEntry(let name):
                return "invalid remote provider registry entry (name and exec must both be non-empty): name \"\(name)\""
            case .duplicateName(let name):
                return "duplicate remote provider name in registry: \(name)"
            }
        }
    }
}
