import ArgumentParser
import Foundation
import TBDShared

struct ConductorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "conductor",
        abstract: "Manage conductors",
        subcommands: [
            ConductorSetup.self,
            ConductorStart.self,
            ConductorStop.self,
            ConductorTeardown.self,
            ConductorListCmd.self,
            ConductorStatusCmd.self,
            ConductorSuggestCmd.self,
            ConductorClearSuggestionCmd.self,
        ]
    )
}

// MARK: - conductor setup

struct ConductorSetup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Create a new conductor"
    )

    @Argument(help: "Conductor name")
    var name: String

    @Option(name: .long, help: "Comma-separated repo IDs (default: all)")
    var repos: String?

    @Option(name: .long, help: "Comma-separated worktree name patterns")
    var worktrees: String?

    @Option(name: .long, help: "Comma-separated terminal labels to monitor")
    var terminalLabels: String?

    @Option(name: .long, help: "Heartbeat interval in minutes (default: 10, 0 = disabled)")
    var heartbeat: Int?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let reposList = repos?.split(separator: ",").map(String.init)
        let worktreesList = worktrees?.split(separator: ",").map(String.init)
        let labelsList = terminalLabels?.split(separator: ",").map(String.init)

        let conductor: Conductor = try client.call(
            method: RPCMethod.conductorSetup,
            params: ConductorSetupParams(
                name: name,
                repos: reposList,
                worktrees: worktreesList,
                terminalLabels: labelsList,
                heartbeatIntervalMinutes: heartbeat
            ),
            resultType: Conductor.self
        )

        if json {
            printJSON(conductor)
        } else {
            print("Created conductor: \(conductor.name)")
            print("  ID:          \(conductor.id)")
            print("  Repos:       \(conductor.repos.joined(separator: ", "))")
            print("  Heartbeat:   \(conductor.heartbeatIntervalMinutes)m")
        }
    }
}

// MARK: - conductor start

struct ConductorStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start a conductor session"
    )

    @Argument(help: "Conductor name")
    var name: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let terminal: Terminal = try client.call(
            method: RPCMethod.conductorStart,
            params: ConductorNameParams(name: name),
            resultType: Terminal.self
        )

        if json {
            printJSON(terminal)
        } else {
            print("Started conductor: \(name)")
            print("  Terminal: \(terminal.id)")
            print("  Window:   \(terminal.tmuxWindowID)")
        }
    }
}

// MARK: - conductor stop

struct ConductorStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop a conductor session"
    )

    @Argument(help: "Conductor name")
    var name: String

    mutating func run() async throws {
        let client = SocketClient()
        try client.callVoid(
            method: RPCMethod.conductorStop,
            params: ConductorNameParams(name: name)
        )
        print("Stopped conductor: \(name)")
    }
}

// MARK: - conductor teardown

struct ConductorTeardown: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "teardown",
        abstract: "Remove a conductor completely"
    )

    @Argument(help: "Conductor name")
    var name: String

    mutating func run() async throws {
        let client = SocketClient()
        try client.callVoid(
            method: RPCMethod.conductorTeardown,
            params: ConductorNameParams(name: name)
        )
        print("Removed conductor: \(name)")
    }
}

// MARK: - conductor list

struct ConductorListCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all conductors"
    )

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let result: ConductorListResult = try client.call(
            method: RPCMethod.conductorList,
            params: EmptyParams(),
            resultType: ConductorListResult.self
        )

        if json {
            printJSON(result.conductors)
        } else {
            if result.conductors.isEmpty {
                print("No conductors configured.")
                return
            }
            let header = String(format: "%-20s  %-20s  %s", "NAME", "REPOS", "HEARTBEAT")
            print(header)
            print(String(repeating: "-", count: 55))
            for c in result.conductors {
                let reposStr = c.repos.contains("*") ? "*" : c.repos.joined(separator: ",")
                let line = String(format: "%-20s  %-20s  %dm",
                    c.name as NSString,
                    String(reposStr.prefix(20)) as NSString,
                    c.heartbeatIntervalMinutes)
                print(line)
            }
        }
    }
}

// MARK: - conductor status

struct ConductorStatusCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show conductor status"
    )

    @Argument(help: "Conductor name")
    var name: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let result: ConductorStatusResult = try client.call(
            method: RPCMethod.conductorStatus,
            params: ConductorNameParams(name: name),
            resultType: ConductorStatusResult.self
        )

        if json {
            printJSON(result)
        } else {
            let c = result.conductor
            print("Conductor: \(c.name)")
            print("  ID:          \(c.id)")
            print("  Running:     \(result.isRunning)")
            print("  Repos:       \(c.repos.joined(separator: ", "))")
            print("  Heartbeat:   \(c.heartbeatIntervalMinutes)m")
            if let wt = c.worktrees { print("  Worktrees:   \(wt.joined(separator: ", "))") }
            if let labels = c.terminalLabels { print("  Labels:      \(labels.joined(separator: ", "))") }
        }
    }
}

// MARK: - conductor suggest

struct ConductorSuggestCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "suggest",
        abstract: "Set a navigation suggestion for the UI"
    )

    @Argument(help: "Conductor name")
    var name: String

    @Option(name: .long, help: "Worktree ID to suggest navigating to")
    var worktree: String

    @Option(name: .long, help: "Optional label (e.g. 'waiting for input')")
    var label: String?

    mutating func run() async throws {
        guard let worktreeID = UUID(uuidString: worktree) else {
            print("Error: invalid worktree UUID: \(worktree)")
            throw ExitCode.failure
        }
        let client = SocketClient()
        try client.callVoid(
            method: RPCMethod.conductorSuggest,
            params: ConductorSuggestParams(name: name, worktreeID: worktreeID, label: label)
        )
        print("Suggestion set for conductor '\(name)'")
    }
}

// MARK: - conductor clear-suggestion

struct ConductorClearSuggestionCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear-suggestion",
        abstract: "Clear the navigation suggestion"
    )

    @Argument(help: "Conductor name")
    var name: String

    mutating func run() async throws {
        let client = SocketClient()
        try client.callVoid(
            method: RPCMethod.conductorClearSuggestion,
            params: ConductorNameParams(name: name)
        )
        print("Suggestion cleared for conductor '\(name)'")
    }
}

// Empty params for list endpoints
private struct EmptyParams: Codable {}
