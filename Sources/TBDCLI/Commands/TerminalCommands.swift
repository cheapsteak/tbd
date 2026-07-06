import ArgumentParser
import Foundation
import TBDShared

struct TerminalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "terminal",
        abstract: "Manage terminals",
        subcommands: [TerminalCreate.self, TerminalList.self, TerminalSend.self, TerminalOutput.self, TerminalConversation.self, TerminalFocus.self, TerminalPin.self, TerminalUnpin.self, TerminalSwapProfile.self]
    )
}

// MARK: - ExpressibleByArgument conformance for CLI

extension TerminalCreateType: ExpressibleByArgument {}

// MARK: - terminal create

struct TerminalCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new terminal in a worktree (TBD_PROMPT_* env vars are set automatically)"
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Option(name: .long, help: "Command to run in the terminal")
    var cmd: String?

    @Option(name: .long, help: "Terminal type (shell, claude, or codex)")
    var type: TerminalCreateType?

    @Option(name: .long, help: "Initial prompt to send to the spawned agent session (requires --type claude or --type codex)")
    var prompt: String?

    @Option(name: .long, help: "Read initial prompt from a file (use - for stdin)")
    var promptFile: String?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let worktreeID = try resolveWorktreeArg(worktree, client: client)

        let terminal: Terminal = try client.call(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: worktreeID, cmd: cmd, type: type, prompt: try resolvePrompt(inline: prompt, file: promptFile)),
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
            let header = tableRow([("ID", 36), ("WINDOW", 10), ("PANE", 10), ("LABEL", 0)])
            print(header)
            print(String(repeating: "-", count: 80))
            for term in terminals {
                let line = tableRow([
                    (term.id.uuidString, 36),
                    (term.tmuxWindowID, 10),
                    (term.tmuxPaneID, 10),
                    (term.label ?? "-", 0)
                ])
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

    @Flag(name: .long, help: "Press Enter after sending text")
    var submit = false

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        guard let terminalID = UUID(uuidString: terminal) else {
            throw CLIError.invalidArgument("Invalid terminal ID: \(terminal)")
        }

        let client = SocketClient()
        try client.callVoid(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(terminalID: terminalID, text: text, submit: submit)
        )

        if json {
            printJSON(["status": "sent"])
        } else {
            print("Text sent.")
        }
    }
}

// MARK: - terminal focus

struct TerminalFocus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Push the user's attention to a terminal's tab (soft by default; --activate foregrounds)"
    )

    @Option(name: .long, help: "Terminal ID")
    var terminal: String

    @Option(name: .long, help: "Notification message")
    var message: String?

    @Flag(name: .long, help: "Foreground and select the tab immediately instead of a soft push")
    var activate = false

    mutating func run() async throws {
        guard let terminalID = UUID(uuidString: terminal) else {
            throw CLIError.invalidArgument("Invalid terminal ID: \(terminal)")
        }

        let client = SocketClient()
        try client.callVoid(
            method: RPCMethod.terminalFocus,
            params: TerminalFocusParams(terminalID: terminalID, message: message, activate: activate)
        )

        print(activate ? "Focused (activated)." : "Focus push sent.")
    }
}

// MARK: - terminal pin

struct TerminalPin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pin",
        abstract: "Pin a terminal to the dock"
    )

    @Argument(help: "Terminal ID")
    var terminal: String

    mutating func run() async throws {
        guard let terminalID = UUID(uuidString: terminal) else {
            throw CLIError.invalidArgument("Invalid terminal ID: \(terminal)")
        }

        let client = SocketClient()
        try client.callVoid(
            method: RPCMethod.terminalSetPin,
            params: TerminalSetPinParams(terminalID: terminalID, pinned: true)
        )

        print("Terminal pinned.")
    }
}

// MARK: - terminal unpin

struct TerminalUnpin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unpin",
        abstract: "Unpin a terminal from the dock"
    )

    @Argument(help: "Terminal ID")
    var terminal: String

    mutating func run() async throws {
        guard let terminalID = UUID(uuidString: terminal) else {
            throw CLIError.invalidArgument("Invalid terminal ID: \(terminal)")
        }

        let client = SocketClient()
        try client.callVoid(
            method: RPCMethod.terminalSetPin,
            params: TerminalSetPinParams(terminalID: terminalID, pinned: false)
        )

        print("Terminal unpinned.")
    }
}

// MARK: - terminal output

struct TerminalOutput: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "output",
        abstract: "Capture terminal output"
    )

    @Argument(help: "Terminal ID")
    var terminal: String

    @Option(name: .long, help: "Number of lines to capture (default 50)")
    var lines: Int?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        guard let terminalID = UUID(uuidString: terminal) else {
            throw CLIError.invalidArgument("Invalid terminal ID: \(terminal)")
        }

        let client = SocketClient()
        let result: TerminalOutputResult = try client.call(
            method: RPCMethod.terminalOutput,
            params: TerminalOutputParams(terminalID: terminalID, lines: lines),
            resultType: TerminalOutputResult.self
        )

        if json {
            printJSON(result)
        } else {
            print(result.output)
        }
    }
}

// MARK: - terminal conversation

struct TerminalConversation: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "conversation",
        abstract: "Read Claude conversation messages from a terminal"
    )

    @Argument(help: "Terminal ID")
    var terminal: String

    @Option(name: .long, help: "Number of messages to return (default 1)")
    var messages: Int?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        guard let terminalID = UUID(uuidString: terminal) else {
            throw CLIError.invalidArgument("Invalid terminal ID: \(terminal)")
        }

        let client = SocketClient()
        let result: TerminalConversationResult = try client.call(
            method: RPCMethod.terminalConversation,
            params: TerminalConversationParams(terminalID: terminalID, messages: messages),
            resultType: TerminalConversationResult.self
        )

        if json {
            printJSON(result)
        } else {
            if let sid = result.sessionID {
                print("Session: \(sid)")
                print()
            }
            if result.messages.isEmpty {
                print("No messages found.")
            } else {
                for msg in result.messages {
                    print("[\(msg.role)]")
                    print(msg.content)
                    print()
                }
            }
        }
    }
}

// MARK: - terminal swap-profile

struct TerminalSwapProfile: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swap-profile",
        abstract: "Reassign a terminal's Claude session to a different account/profile",
        discussion: """
            The daemon decides how to apply the swap based on the session's state:

              • PARKED session (hibernated) → COLD swap: the profile is reassigned
                but the session is NOT woken. Memory stays reclaimed; the session
                resumes under the new profile on its next wake/focus. Ideal for
                bulk-rebalancing many parked sessions onto an underused account.

              • AWAKE session → the running Claude is respawned in place under the
                new profile (a brief interruption).

            Pass --profile ambient (or omit it) to clear the profile (use ambient
            keychain credentials).
            """
    )

    @Option(name: .long, help: "Terminal ID (UUID)")
    var terminal: String

    @Option(name: .long, help: "Target profile name or UUID, or 'ambient' to clear (defaults to ambient)")
    var profile: String?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        guard let terminalID = UUID(uuidString: terminal) else {
            throw CLIError.invalidArgument("Invalid terminal ID: \(terminal)")
        }

        let client = SocketClient()

        // Resolve the target profile. Omitted or "ambient" → nil (clear profile).
        var newProfileID: UUID? = nil
        var targetLabel = "ambient"
        if let profile, profile.lowercased() != "ambient" {
            let list = try client.call(
                method: RPCMethod.modelProfileList,
                resultType: ModelProfileListResult.self
            )
            let entry = try resolveProfile(named: profile, in: list.profiles)
            newProfileID = entry.profile.id
            targetLabel = entry.profile.name
        }

        let updated: Terminal = try client.call(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(terminalID: terminalID, newProfileID: newProfileID),
            resultType: Terminal.self
        )

        if json {
            printJSON(updated)
        } else {
            // A cold-swapped (parked) session stays parked in the returned row;
            // a respawned one is no longer parked.
            if updated.isParked {
                print("Cold swap: session parked, will resume under '\(targetLabel)' on wake.")
            } else {
                print("Respawned under '\(targetLabel)'.")
            }
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
