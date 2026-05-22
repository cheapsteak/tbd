import Foundation

/// A spawn-time environment value the user can configure. The on-disk JSON
/// format is frozen — all three cases exist from day one so adding settings
/// of any type never requires a storage migration.
public enum ClaudeEnvValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case string(String)

    private enum CodingKeys: String, CodingKey { case kind, value }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let b):
            try c.encode("bool", forKey: .kind); try c.encode(b, forKey: .value)
        case .int(let i):
            try c.encode("int", forKey: .kind); try c.encode(i, forKey: .value)
        case .string(let s):
            try c.encode("string", forKey: .kind); try c.encode(s, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "bool": self = .bool(try c.decode(Bool.self, forKey: .value))
        case "int": self = .int(try c.decode(Int.self, forKey: .value))
        case "string": self = .string(try c.decode(String.self, forKey: .value))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown ClaudeEnvValue kind '\(other)'")
        }
    }
}

/// One configurable Claude spawn-time environment setting.
public struct ClaudeEnvSetting: Sendable {
    /// The value type, default, and env-emission rule for a setting.
    /// v1 ships only `.toggle`; `.integer` / `.choice` are added — as new
    /// cases plus a settings-UI switch arm — when the first such setting
    /// is introduced.
    public enum Kind: Sendable {
        /// `emit` maps the boolean to the env value, or nil to omit the
        /// variable. A normal flag emits when on; an inverted `DISABLE_*`
        /// flag emits when off.
        case toggle(default: Bool, emit: @Sendable (Bool) -> String?)
    }

    /// Stable semantic key — used in persistence and RPC, never the env-var name.
    public let id: String
    /// The environment variable this setting controls.
    public let envVar: String
    public let title: String
    public let help: String
    public let kind: Kind

    public init(id: String, envVar: String, title: String, help: String, kind: Kind) {
        self.id = id
        self.envVar = envVar
        self.title = title
        self.help = help
        self.kind = kind
    }

    /// The setting's default value as a `ClaudeEnvValue`.
    public var defaultValue: ClaudeEnvValue {
        switch kind {
        case .toggle(let def, _): return .bool(def)
        }
    }

    /// Resolve a stored value to the env-var value to set, or nil to omit.
    /// A value whose type doesn't match the kind falls back to the default.
    public func emit(_ value: ClaudeEnvValue) -> String? {
        switch kind {
        case .toggle(let def, let emit):
            if case .bool(let b) = value { return emit(b) }
            return emit(def)
        }
    }
}

/// The single source of truth for which Claude spawn-time env settings exist.
/// Adding a setting is one entry here — no migration, no RPC change, and (for
/// `.toggle`) no UI code.
public enum ClaudeEnvRegistry {
    public static let all: [ClaudeEnvSetting] = [
        ClaudeEnvSetting(
            id: "fullscreenRendering",
            envVar: "CLAUDE_CODE_NO_FLICKER",
            title: "Fullscreen rendering for Claude sessions",
            help: "Flicker-free renderer for Claude Code. Research-preview "
                + "feature — run /tui in a session to override per-session.",
            kind: .toggle(default: true, emit: { $0 ? "1" : nil })
        ),
    ]

    public static func setting(id: String) -> ClaudeEnvSetting? {
        all.first { $0.id == id }
    }
}
