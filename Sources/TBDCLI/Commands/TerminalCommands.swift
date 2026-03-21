import ArgumentParser
import Foundation
import TBDShared

struct TerminalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "terminal",
        abstract: "Manage terminals",
        subcommands: [TerminalCreate.self, TerminalList.self, TerminalSend.self]
    )
}

// MARK: - terminal create

struct TerminalCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new terminal in a worktree"
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Option(name: .long, help: "Command to run in the terminal")
    var cmd: String?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let worktreeID = try resolveWorktreeArg(worktree, client: client)

        let terminal: Terminal = try client.call(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: worktreeID, cmd: cmd),
            resultType: Terminal.self
        )

        if json {
            printJSON(terminal)
        } else {
            print("Created terminal:")
            print("  ID:     \(terminal.id)")
            print("  Window: \(terminal.tmuxWindowID)")
            print("  Pane:   \(terminal.tmuxPaneID)")
        }
    }
}

// MARK: - terminal list

struct TerminalList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List terminals in a worktree"
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let worktreeID = try resolveWorktreeArg(worktree, client: client)

        let terminals: [Terminal] = try client.call(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: worktreeID),
            resultType: [Terminal].self
        )

        if json {
            printJSON(terminals)
        } else {
            if terminals.isEmpty {
                print("No terminals found.")
                return
            }
            let header = String(format: "%-36s  %-10s  %-10s  %s", "ID", "WINDOW", "PANE", "LABEL")
            print(header)
            print(String(repeating: "-", count: 80))
            for term in terminals {
                let line = String(format: "%-36s  %-10s  %-10s  %s",
                    term.id.uuidString as NSString,
                    term.tmuxWindowID as NSString,
                    term.tmuxPaneID as NSString,
                    (term.label ?? "-") as NSString)
                print(line)
            }
        }
    }
}

// MARK: - terminal send

struct TerminalSend: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send text to a terminal"
    )

    @Option(name: .long, help: "Terminal ID")
    var terminal: String

    @Option(name: .long, help: "Text to send")
    var text: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        guard let terminalID = UUID(uuidString: terminal) else {
            throw CLIError.invalidArgument("Invalid terminal ID: \(terminal)")
        }

        let client = SocketClient()
        try client.callVoid(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(terminalID: terminalID, text: text)
        )

        if json {
            printJSON(["status": "sent"])
        } else {
            print("Text sent.")
        }
    }
}

// MARK: - Helpers

/// Resolve a worktree argument that could be a UUID or a name.
private func resolveWorktreeArg(_ nameOrID: String, client: SocketClient) throws -> UUID {
    if let id = UUID(uuidString: nameOrID) {
        return id
    }

    let worktrees: [Worktree] = try client.call(
        method: RPCMethod.worktreeList,
        params: WorktreeListParams(),
        resultType: [Worktree].self
    )

    let matches = worktrees.filter { $0.name == nameOrID || $0.displayName == nameOrID }
    guard let match = matches.first else {
        throw CLIError.invalidArgument("No worktree found with name or ID: \(nameOrID)")
    }
    if matches.count > 1 {
        throw CLIError.invalidArgument("Multiple worktrees match '\(nameOrID)'. Use the full ID instead.")
    }
    return match.id
}
