import ArgumentParser
import Foundation
import TBDShared

struct LinkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "link",
        abstract: "Print a tbd:// deep link for a worktree or one of its terminals",
        discussion: """
        With no arguments, prints a link to the current worktree, read from
        the TBD_WORKTREE_ID environment variable that TBD-spawned terminals
        inherit. With an argument, accepts a worktree UUID, name, or
        display name (matches the same conventions as other tbd commands).

        --terminal <uuid> adds that terminal's tab to the link; its worktree
        is looked up from the daemon, so no worktree argument is needed (if
        one is given, it must match). --this-terminal does the same for the
        terminal running the command (TBD_TERMINAL_ID). --https prints the
        shareable https form instead of tbd://.
        """
    )

    @Argument(help: "Worktree UUID, name, or display name (optional)")
    var worktree: String?

    @Option(name: .long, help: "Link to the tab of the terminal with this UUID")
    var terminal: String?

    @Flag(name: .customLong("this-terminal"),
          help: "Link to the terminal running this command (reads TBD_TERMINAL_ID)")
    var thisTerminal: Bool = false

    @Flag(name: .long, help: "Print the shareable https form instead of tbd://")
    var https: Bool = false

    mutating func validate() throws {
        if terminal != nil && thisTerminal {
            throw ValidationError("--terminal and --this-terminal are mutually exclusive")
        }
    }

    mutating func run() async throws {
        let client = SocketClient()
        let target = try Self.resolveTarget(
            worktreeArg: worktree,
            terminalArg: terminal,
            thisTerminal: thisTerminal,
            environment: ProcessInfo.processInfo.environment,
            resolveWorktree: { try resolveWorktreeNameOrID($0, client: client) },
            terminals: {
                try client.call(
                    method: RPCMethod.terminalList,
                    params: TerminalListParams(worktreeID: nil),
                    resultType: [Terminal].self
                )
            }
        )
        print(Self.render(target, https: https))
    }

    static func render(_ target: (worktree: UUID, terminal: UUID?), https: Bool) -> String {
        let url = https
            ? DeepLink.makeShareableOpenURL(target.worktree, terminalID: target.terminal)
            : DeepLink.makeOpenWorktreeURL(target.worktree, terminalID: target.terminal)
        return url.absoluteString
    }

    /// Decide which worktree (and optionally terminal) to link to. Daemon
    /// access is injected so the decision is testable without a socket. The
    /// bare form deliberately never reads `TBD_TERMINAL_ID`: only
    /// `--this-terminal` opts into a terminal anchor.
    static func resolveTarget(
        worktreeArg: String?,
        terminalArg: String?,
        thisTerminal: Bool,
        environment: [String: String],
        resolveWorktree: (String) throws -> UUID,
        terminals: () throws -> [Terminal]
    ) throws -> (worktree: UUID, terminal: UUID?) {
        let terminalID: UUID?
        if thisTerminal {
            guard let value = environment["TBD_TERMINAL_ID"], let id = UUID(uuidString: value) else {
                throw CLIError.invalidArgument(
                    "not inside a TBD terminal (TBD_TERMINAL_ID is not set to a UUID); use --terminal <uuid>"
                )
            }
            terminalID = id
        } else if let arg = terminalArg {
            guard let id = UUID(uuidString: arg) else {
                throw CLIError.invalidArgument("Invalid terminal ID: \(arg)")
            }
            terminalID = id
        } else {
            terminalID = nil
        }

        guard let terminalID else {
            if let arg = worktreeArg {
                return (try resolveWorktree(arg), nil)
            }
            guard
                let envValue = environment["TBD_WORKTREE_ID"],
                let id = UUID(uuidString: envValue)
            else {
                throw CLIError.invalidArgument(
                    "not inside a TBD terminal; pass a worktree name or UUID"
                )
            }
            return (id, nil)
        }

        guard let match = try terminals().first(where: { $0.id == terminalID }) else {
            throw CLIError.invalidArgument("No terminal found with ID: \(terminalID.uuidString)")
        }
        if let arg = worktreeArg {
            let expected = try resolveWorktree(arg)
            guard expected == match.worktreeID else {
                throw CLIError.invalidArgument(
                    "Terminal \(terminalID.uuidString) belongs to worktree \(match.worktreeID.uuidString), not \(expected.uuidString)"
                )
            }
        }
        return (match.worktreeID, terminalID)
    }
}
