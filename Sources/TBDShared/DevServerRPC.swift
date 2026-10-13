import Foundation

// RPC surface for dev servers (docs/specs/2026-10-11-dev-servers-design.md).

extension RPCMethod {
    public static let serverList = "server.list"
    public static let serverStart = "server.start"
    public static let serverStop = "server.stop"
    public static let serverSummary = "server.summary"
}

public struct DevServerListParams: Codable, Sendable {
    public let worktreeID: UUID
    /// Run declared `status` commands (5 s timeout each). Only explicit user
    /// requests ask for this: `tbd server list/status`, and the app after a
    /// Start, Stop or Restart and on "Refresh status".
    public let runStatusCommands: Bool
    public init(worktreeID: UUID, runStatusCommands: Bool) {
        self.worktreeID = worktreeID; self.runStatusCommands = runStatusCommands
    }
}

public enum DevServerStateKind: String, Codable, Sendable, Equatable {
    case running
    case exited
    case stopped
    /// The `status` command timed out and nothing else says "running".
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DevServerStateKind(rawValue: raw) ?? .unknown
    }
}

public struct DevServerInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var label: String
    /// `DevServerSource.rawValue` of the declaring file; nil = undeclared
    /// (known only from a running file). A string, not the enum, so a source
    /// a newer daemon adds cannot fail an older client's decode.
    public var source: String?
    public var state: DevServerStateKind
    public var exitCode: Int32?
    /// Empty unless a live running file reported them.
    public var endpoints: [DevServerEndpoint]
    /// The server's TBD tab, if one exists.
    public var terminalID: UUID?
    public var pid: Int32?
    public var hasStopCommand: Bool
    /// The Closed Terminals entry holding an exited server's saved final
    /// output (holder transport; plan decision D2), or nil. Set only when
    /// `state == .exited`. Optional, so an older daemon's JSON decodes nil.
    public var lastOutputID: UUID?
    /// True when the server's declared `status` command decided `state` —
    /// it exited 0 (running) or timed out (unknown) and nothing ranked above
    /// it. The app remembers such answers across refreshes that do not run
    /// `status` commands. Optional, so an older daemon's JSON decodes nil.
    public var stateFromStatusCommand: Bool?
    /// Whether the server's declaration has a `status` command. Optional, so
    /// an older daemon's JSON decodes nil (not known).
    public var hasStatusCommand: Bool?
    /// The server's TBD tab when that tab has ended, whatever decided
    /// `state`: a command that detaches (`docker compose up -d`) leaves an
    /// ended tab behind a server its `status` command reads running.
    /// Optional, so an older daemon's JSON decodes nil.
    public var exitedTab: DevServerExitedTab?

    public init(name: String, label: String, source: String?, state: DevServerStateKind,
                exitCode: Int32?, endpoints: [DevServerEndpoint], terminalID: UUID?,
                pid: Int32?, hasStopCommand: Bool, lastOutputID: UUID? = nil,
                stateFromStatusCommand: Bool? = nil, hasStatusCommand: Bool? = nil,
                exitedTab: DevServerExitedTab? = nil) {
        self.name = name; self.label = label; self.source = source; self.state = state
        self.exitCode = exitCode; self.endpoints = endpoints; self.terminalID = terminalID
        self.pid = pid; self.hasStopCommand = hasStopCommand; self.lastOutputID = lastOutputID
        self.stateFromStatusCommand = stateFromStatusCommand; self.hasStatusCommand = hasStatusCommand
        self.exitedTab = exitedTab
    }

    /// The first endpoint's URL — the server's main URL.
    public var mainURL: String? { endpoints.first?.url }
    public var isDeclared: Bool { source != nil }
}

/// One run of a server's TBD tab that has ended. Starting the server again
/// in a tmux tab respawns that tab in place, keeping its terminal id, so the
/// process id is what tells one run of the tab from the next.
public struct DevServerExitedTab: Codable, Sendable, Equatable {
    /// The tab's terminal id. Once an ended tab's row is gone, its saved
    /// last output carries the same id.
    public var terminalID: UUID
    /// The process the tab ran, when the transport still reports it after
    /// the exit (a tmux pane kept by `remain-on-exit`); nil otherwise. A
    /// holder tab is never respawned in place, so its terminal id alone is
    /// one run.
    public var pid: Int32?

    public init(terminalID: UUID, pid: Int32?) {
        self.terminalID = terminalID; self.pid = pid
    }
}

public struct DevServerListResult: Codable, Sendable, Equatable {
    public var worktreeID: UUID
    public var servers: [DevServerInfo]
    public var parseErrors: [DevServerParseError]
    public var runningFileDiagnostics: [DevServerRunningFileDiagnostic]

    public init(worktreeID: UUID, servers: [DevServerInfo], parseErrors: [DevServerParseError],
                runningFileDiagnostics: [DevServerRunningFileDiagnostic]) {
        self.worktreeID = worktreeID; self.servers = servers
        self.parseErrors = parseErrors; self.runningFileDiagnostics = runningFileDiagnostics
    }
}

public struct DevServerActionParams: Codable, Sendable {
    public let worktreeID: UUID
    /// Empty means all: every declared server for start, every running one for stop.
    public let names: [String]
    public init(worktreeID: UUID, names: [String]) { self.worktreeID = worktreeID; self.names = names }
}

public enum DevServerActionStatus: String, Codable, Sendable, Equatable {
    case started
    case alreadyRunning
    case stopped
    case notRunning
    case failed

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DevServerActionStatus(rawValue: raw) ?? .failed
    }
}

public struct DevServerActionOutcome: Codable, Sendable, Equatable {
    public var name: String
    public var status: DevServerActionStatus
    public var terminalID: UUID?
    public var message: String?
    public init(name: String, status: DevServerActionStatus, terminalID: UUID? = nil, message: String? = nil) {
        self.name = name; self.status = status; self.terminalID = terminalID; self.message = message
    }
}

public struct DevServerActionResult: Codable, Sendable, Equatable {
    public var outcomes: [DevServerActionOutcome]
    public init(outcomes: [DevServerActionOutcome]) { self.outcomes = outcomes }
    public var allSucceeded: Bool { !outcomes.contains { $0.status == .failed } }
}

/// Worktrees with at least one server running by a live running file or a
/// live TBD server tab. Never runs `status` commands.
public struct DevServerSummaryResult: Codable, Sendable, Equatable {
    public var runningWorktreeIDs: [UUID]
    public init(runningWorktreeIDs: [UUID]) { self.runningWorktreeIDs = runningWorktreeIDs }
}
