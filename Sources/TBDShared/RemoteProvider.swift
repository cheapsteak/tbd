import Foundation

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

    enum CodingKeys: String, CodingKey {
        case id, title, state, meta
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
                meta: [String: String]? = nil) {
        self.id = id; self.title = title; self.createdAt = createdAt
        self.state = state; self.exitCode = exitCode
        self.agentState = agentState; self.agentStateReason = agentStateReason
        self.agentStateAt = agentStateAt; self.meta = meta
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
        meta = try c.decodeIfPresent([String: String].self, forKey: .meta)
    }
}

public struct RemoteSessionListEnvelope: Codable, Sendable {
    public let sessions: [RemoteSessionPayload]
    public init(sessions: [RemoteSessionPayload]) { self.sessions = sessions }
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

public struct ProviderRemediation: Codable, Sendable {
    public let label: String
    public let command: String?
}

/// One provider's negotiated contract + current health, as tracked by
/// `RemoteProviderManager` (daemon) and rendered by the app. Lives here (not
/// daemon-side) because `remote.providers` puts it on the wire.
public struct RemoteProviderStatus: Codable, Sendable {
    public let config: RemoteProviderConfig
    public let describe: ProviderDescribe?
    public let health: ProviderHealth
    public let errorMessage: String?
    public let remediationLabel: String?
    public let remediationCommand: String?
    public init(config: RemoteProviderConfig, describe: ProviderDescribe?, health: ProviderHealth,
                errorMessage: String?, remediationLabel: String?, remediationCommand: String?) {
        self.config = config; self.describe = describe; self.health = health
        self.errorMessage = errorMessage
        self.remediationLabel = remediationLabel; self.remediationCommand = remediationCommand
    }
}

/// Loads `agent-providers.json`. Missing file = no providers (not an error);
/// duplicate names or empty exec = configuration error.
public enum RemoteProviderRegistry {
    public static func load(from url: URL) throws -> [RemoteProviderConfig] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let configs = try JSONDecoder().decode([RemoteProviderConfig].self, from: data)
        var seen = Set<String>()
        for c in configs {
            guard !c.name.isEmpty, !c.exec.isEmpty else {
                throw RegistryError.invalidEntry(c.name)
            }
            guard seen.insert(c.name).inserted else {
                throw RegistryError.duplicateName(c.name)
            }
        }
        return configs
    }

    public enum RegistryError: Error, Equatable {
        case invalidEntry(String)
        case duplicateName(String)
    }
}
