import ArgumentParser
import Foundation
import TBDShared

struct TerminalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "terminal",
        abstract: "Manage terminals",
        subcommands: [TerminalCreate.self, TerminalList.self, TerminalSend.self, TerminalWake.self, TerminalClose.self, TerminalOutput.self, TerminalConversation.self, TerminalFocus.self, TerminalPin.self, TerminalUnpin.self, TerminalSwapProfile.self, TerminalContinueInCodex.self, TerminalAttach.self]
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

    @Option(name: .long, help: "Extra Claude Code settings as a JSON object, deep-merged into TBD's per-session --settings overlay for the spawned agent (Claude only). Example: '{\"skillOverrides\":{\"some-skill\":\"off\"}}'")
    var claudeSettings: String?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let worktreeID = try resolveWorktreeArg(worktree, client: client)

        let terminal: Terminal = try client.call(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: worktreeID, cmd: cmd, type: type, prompt: try resolvePrompt(inline: prompt, file: promptFile), claudeSettingsOverlay: claudeSettings),
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
            // A bare top-level array, unversioned by design — it has nowhere
            // additive to put a `schemaVersion`. Its `profileID` field is a
            // documented contract surface (docs/capacity-facts.md), so an
            // encoding failure must not read as "no terminals": name it on
            // stderr and exit nonzero instead of printing nothing at exit 0.
            guard let output = jsonString(terminals) else {
                FileHandle.standardError.write(Data(
                    "Error: could not encode the terminal list as JSON\n".utf8))
                throw ExitCode.failure
            }
            print(output)
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
        abstract: "Send a payload to a terminal: text, or named keys",
        discussion: """
            Exactly one payload per call.

              --text "…"          the message. Typed into the composer and left
                                  standing unless --submit is also passed.
              --text "…" --submit  the message, submitted. This is the pair every
                                  delivery uses.
              --keys "Escape Enter"  whitespace-separated tmux key names, sent one
                                  at a time. Interrupt is a keys payload
                                  (--keys "C-c"). Enter is itself a key, so
                                  --submit does not apply here.

            A non-empty text payload sent to an AGENT session is delivered
            behind a one-line attribution envelope carrying the send's record id
            and the caller's declared identity, then the message verbatim, so
            the receiving agent sees who is addressing it. A shell target gets
            the text alone: nothing there reads the tag, and --submit would run
            it as a command line of its own.

            --verify additionally asks the daemon to confirm the payload landed,
            by looking for that envelope in the session's transcript. It needs
            --submit (text left standing in a composer never enters the
            conversation) and cannot be combined with --keys (keys reach no
            transcript). It is available for Claude sessions only — a shell
            keeps no transcript, and Codex's acknowledgement arrives by a
            different mechanism that is not built yet. It is refused, rather
            than quietly downgraded, while delivery verification is disabled
            daemon-side.
            """
    )

    @Option(name: .long, help: "Terminal ID")
    var terminal: String

    @Option(name: .long, help: "Text to send")
    var text: String?

    @Option(name: .long, help: "Whitespace-separated tmux key names to send, e.g. \"Escape Enter\" or \"C-c\"")
    var keys: String?

    @Flag(name: .long, help: "Press Enter after sending text")
    var submit = false

    @Flag(name: .long, help: "Confirm the payload landed in the session's transcript (requires --submit; not valid with --keys)")
    var verify = false

    @Flag(name: .long, help: "Output JSON")
    var json = false

    /// The payload-shape rules, checked here so a human gets a clean message
    /// before a socket is opened. Deliberately duplicated rather than
    /// delegated: the CLI is not the only caller, so the daemon cannot rely on
    /// this — and a human should not have to read an RPC error to learn they
    /// passed two payloads.
    ///
    /// Not a complete mirror of the daemon's `validateSendShape`, and not meant
    /// to be: the daemon additionally refuses a `--keys` value that tokenizes
    /// to nothing or to more than `PacedKeySender.maxKeys` keys. Duplicating
    /// the tokenizer here would mean two copies of a bound that must agree,
    /// which is a worse failure than one extra round trip — the daemon's
    /// refusal is specific and reaches the user as an ordinary error.
    func validate() throws {
        if text != nil && keys != nil {
            throw ValidationError("Pass exactly one payload: --text or --keys, not both.")
        }
        if text == nil && keys == nil {
            throw ValidationError("Pass a payload: --text or --keys.")
        }
        if keys != nil && submit {
            throw ValidationError(
                "--submit is incoherent with --keys: Enter is itself a key. "
                + "Put it in the sequence instead, e.g. --keys \"Escape Enter\".")
        }
        if keys != nil && verify {
            throw ValidationError(
                "--verify cannot be used with --keys: keys reach no transcript, "
                + "so delivery cannot be observed.")
        }
        if verify && !submit {
            throw ValidationError(
                "--verify requires --submit: text left standing in a composer never "
                + "enters the conversation, so delivery cannot be observed.")
        }
        if verify, text?.isEmpty == true {
            throw ValidationError(
                "--verify requires a non-empty --text: an empty payload pastes nothing, "
                + "so there is no dispatch envelope to observe.")
        }
    }

    mutating func run() async throws {
        guard let terminalID = UUID(uuidString: terminal) else {
            throw CLIError.invalidArgument("Invalid terminal ID: \(terminal)")
        }

        let client = SocketClient()
        try client.callVoid(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: terminalID,
                text: text,
                keys: keys,
                // Preserved exactly: `--submit` is sent as a plain bool for a
                // text payload, as it always was. A keys payload never carries
                // it (validate() has already refused the combination).
                submit: keys == nil ? submit : nil,
                verify: verify ? true : nil)
        )

        if json {
            printJSON(["status": "sent"])
        } else {
            print(keys == nil ? "Text sent." : "Keys sent.")
        }
    }
}

// MARK: - terminal wake

struct TerminalWake: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wake",
        abstract: "Wake a hibernated terminal (respawn claude --resume). Idempotent: waking a non-hibernated terminal is a no-op."
    )

    @Option(name: .long, help: "Terminal ID")
    var terminal: String

    @Option(name: .long, help: "Prompt delivered to the resumed claude as an argv (atomic with the respawn). NOT delivered when the wake is a no-op — check `woken` in the output.")
    var prompt: String?

    @Flag(name: .long, help: "If the pinned account profile no longer exists, resume on the default login instead of failing")
    var fallbackToDefaultProfile = false

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        guard let terminalID = UUID(uuidString: terminal) else {
            throw CLIError.invalidArgument("Invalid terminal ID: \(terminal)")
        }

        let client = SocketClient()
        let result: TerminalWakeResult = try client.call(
            method: RPCMethod.terminalWake,
            params: TerminalWakeParams(
                terminalID: terminalID,
                fallbackToDefaultProfile: fallbackToDefaultProfile ? true : nil,
                prompt: prompt
            ),
            resultType: TerminalWakeResult.self
        )

        if json {
            printJSON(["woken": result.woken])
        } else {
            print(result.woken
                ? "Terminal woken."
                : "Terminal already awake (no-op)\(prompt != nil ? " — prompt NOT delivered" : "").")
        }
    }
}

// MARK: - terminal close

struct TerminalClose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "Close a terminal: capture its scrollback to Closed Terminals history, kill its tmux window, remove it from TBD. Idempotent: closing an already-closed terminal is a no-op.",
        discussion: """
            Closing is immediate and final for the terminal row. The pane's
            scrollback is captured into Session History → Closed Terminals
            (best-effort), any pending session-limit auto-resume is cancelled,
            and the tab disappears from the app. A Claude session's transcript
            survives on disk, and a closed Claude terminal can be revived from
            Closed Terminals history.

            By default a terminal that is mid-turn or holding a permission
            prompt is refused (exit 2) — pass --force to close it anyway. That
            check applies only while the pane's window is alive, so a session
            that died mid-turn stays closeable without --force.

            A terminal cannot close itself: killing the window SIGHUPs the
            calling shell, so this command could never report its own result.
            Spawn a successor and have it close you.

            Closing a worktree's last terminal does NOT archive the worktree —
            it stays active with zero terminals. Use `tbd worktree archive`.
            """
    )

    @Option(name: .long, help: "Terminal ID")
    var terminal: String

    @Flag(name: .long, help: "Close even if the terminal is mid-turn or waiting on a permission prompt")
    var force = false

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        guard let terminalID = UUID(uuidString: terminal) else {
            throw CLIError.invalidArgument("Invalid terminal ID: \(terminal)")
        }

        // Self-close is refused before the RPC, not skipped: with a single
        // target, skipping would exit 0 having done nothing, which an
        // autonomous caller reads as success.
        if let selfID = ProcessInfo.processInfo.environment["TBD_TERMINAL_ID"],
           UUID(uuidString: selfID) == terminalID {
            FileHandle.standardError.write(Data("""
                Refusing to close the calling terminal (\(terminalID)). A terminal cannot \
                close itself — spawn a successor and have it close this one.\n
                """.utf8))
            throw ExitCode(2)
        }

        let client = SocketClient()
        let response = try client.send(try RPCRequest(
            method: RPCMethod.terminalDelete,
            // --force drops the rails; otherwise the daemon applies them.
            params: TerminalDeleteParams(
                terminalID: terminalID,
                respectActivityRails: force ? nil : true)
        ))

        guard response.success else {
            // Branch on the machine-readable code, never the prose.
            if response.errorCode == RPCErrorCode.terminalBusy.rawValue {
                FileHandle.standardError.write(Data(((response.error ?? "Terminal is busy.") + "\n").utf8))
                throw ExitCode(2)
            }
            throw CLIError.rpcError(response.error ?? "Unknown error")
        }

        let result = try response.decodeResult(TerminalDeleteResult.self)
        if json {
            printJSON(result)
        } else {
            print(result.alreadyGone ? "Terminal already closed (no-op)." : "Terminal closed.")
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

// MARK: - terminal continue-in-codex

struct TerminalContinueInCodex: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "continue-in-codex",
        abstract: "Import a Claude terminal's conversation and open it in Codex"
    )

    @Argument(help: "Claude terminal ID (UUID)")
    var terminal: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        guard let terminalID = UUID(uuidString: terminal) else {
            throw CLIError.invalidArgument("Invalid terminal ID: \(terminal)")
        }

        let result: TerminalContinueInCodexResult = try SocketClient().call(
            method: RPCMethod.terminalContinueInCodex,
            params: TerminalContinueInCodexParams(terminalID: terminalID),
            resultType: TerminalContinueInCodexResult.self)

        if json {
            printJSON(result)
        } else {
            print("Continued in Codex:")
            print("  Terminal: \(result.terminalID)")
            print("  Thread:   \(result.threadID)")
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

// MARK: - terminal attach

/// The coordinates half of `terminal.attachCommand`, without the script.
///
/// `--json` exists so the *sharper* instrument for the byte-burst question —
/// `tmux pipe-pane -o`, which needs a socket path and a pane id and attaches no
/// client at all — is drivable from this command. Emitting the script there too
/// would invite a consumer to `sh`-pipe a field out of a JSON document; the two
/// output modes are deliberately disjoint.
///
/// Built from the RPC result rather than from separately resolved values: the
/// `paneID` reported here is the one the daemon's identity probe answered for.
struct ExternalAttachCoordinates: Encodable {
    let socketPath: String
    let sessionName: String
    let windowID: String
    let paneID: String
    let terminalID: UUID

    init(_ result: TerminalAttachCommandResult) {
        self.socketPath = result.socketPath
        self.sessionName = result.sessionName
        self.windowID = result.windowID
        self.paneID = result.paneID
        self.terminalID = result.terminalID
    }
}

/// Pick the terminal `tbd terminal attach` should target.
///
/// Never guesses. An explicit `--terminal` must name a terminal that actually
/// belongs to this worktree — attaching to a stranger's window is the failure
/// reused pane coordinates already produced once (issue #384), and the list is
/// in hand, so checking costs nothing. With no `--terminal`, a worktree holding
/// exactly one terminal resolves to it and any other count is an error that
/// lists what was available.
func resolveAttachTerminal(
    explicit: String?,
    terminals: [Terminal],
    worktreeLabel: String
) throws -> Terminal {
    if let explicit {
        guard let id = UUID(uuidString: explicit) else {
            throw CLIError.invalidArgument("Invalid terminal ID: \(explicit)")
        }
        guard let match = terminals.first(where: { $0.id == id }) else {
            throw CLIError.invalidArgument(
                "Terminal \(id) is not in worktree '\(worktreeLabel)'."
                + attachCandidateList(terminals))
        }
        return match
    }

    if terminals.count == 1, let only = terminals.first {
        return only
    }

    if terminals.isEmpty {
        throw CLIError.invalidArgument("Worktree '\(worktreeLabel)' has no terminals to attach to.")
    }

    throw CLIError.invalidArgument(
        "Worktree '\(worktreeLabel)' has \(terminals.count) terminals — "
        + "pass --terminal <id> to choose one."
        + attachCandidateList(terminals))
}

/// The candidate lines appended to every ambiguous-or-absent resolution error.
/// Empty for an empty list, so the caller's sentence stands on its own.
private func attachCandidateList(_ terminals: [Terminal]) -> String {
    guard !terminals.isEmpty else { return "" }
    return "\n" + terminals.map { term in
        "  \(term.id.uuidString)  \(term.tmuxWindowID)  \(term.label ?? "-")"
    }.joined(separator: "\n")
}

/// The refusal text for attaching from *inside* tmux, or nil when the exec path
/// may proceed.
///
/// Taking the environment as an argument is what makes both branches of the
/// gate testable without a subprocess: `run()` passes the real environment and
/// the tests pass a dictionary. An empty `$TMUX` is treated as unset — that is
/// how a shell that exported and cleared it presents, and tmux itself sets a
/// non-empty triple.
func externalAttachNestingRefusal(environment: [String: String]) -> String? {
    guard let tmux = environment["TMUX"], !tmux.isEmpty else { return nil }
    return """
        Refusing to attach from inside tmux ($TMUX is set): a tmux client nested \
        in a tmux pane is not the second emulator this command exists to give you. \
        Run it from another terminal emulator, or run \
        `sh -c "$(tbd terminal attach <worktree> --print)"` there. Piping --print \
        into `sh` does not work: the attach needs a tty on stdin.
        """
}

/// The process image the exec path replaces itself with.
///
/// The composed script is two shell statements — an idempotent `has-session`
/// guard and the attach — so the thing exec'd is a shell running them, not tmux
/// directly. `sh` exits with the attach's status, which is what lets a harness
/// tell a failed attach from an empty measurement.
///
/// Split out from `run()` so the argv is asserted in a test rather than only
/// observed by a process that never returns.
func externalAttachExecInvocation(script: String) -> (executable: String, arguments: [String]) {
    ("/bin/sh", ["-c", script])
}

struct TerminalAttach: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attach",
        abstract: "Attach an external terminal emulator to a TBD terminal's tmux window",
        discussion: """
            Puts a second client — iTerm2, Terminal.app, Ghostty — on the window a
            TBD panel is already showing, so somebody else's renderer sits next to
            SwiftTerm's on the identical byte stream. With no flags it execs tmux,
            replacing itself, so run it in the emulator you want attached. It
            refuses when $TMUX is set: pass --print and run the script in the
            target emulator instead.

            --terminal picks the terminal when the worktree has more than one. With
            one terminal it can be omitted; with several, omitting it is an error
            listing the candidates rather than a guess.

            --print writes the script and nothing else, to be run from a tty:
            sh -c "$(tbd terminal attach <worktree> --print)", or equivalently
            eval "$(tbd terminal attach <worktree> --print)". Both keep the
            caller's terminal as stdin. PIPING THE SCRIPT INTO `sh` DOES NOT WORK:
            `tmux attach` requires a tty on stdin, and a shell reading its script
            from a pipe leaves stdin as that pipe, so the attach dies with
            "open terminal failed: not a terminal". The setup half of the script
            has already created the session by then, and the reaping option rides
            the attach that just failed, so every piped attempt also leaves a
            client-less session behind for the daemon to reclaim. Use one of the
            two forms above.

            --json writes the coordinates instead — socket path, session name,
            @window, %pane, terminal id — which is what drives `tmux pipe-pane -o`,
            an instrument that needs those values and attaches no client at all.
            --print and --json are mutually exclusive.

            SIZING THE EXTERNAL WINDOW. Match TBD's panel dimensions EXACTLY
            whenever you will run the external-alone condition (TBD's tab switched
            away). The window follows the external client's dimensions once it is
            the only one left, so an exactly-sized window resizes it to the size it
            already had and the both-attached and external-alone conditions share a
            geometry. Larger is acceptable when running only the TBD-alone and
            both-attached conditions. SMALLER IS NEVER ACCEPTABLE: while both
            clients are attached the window keeps TBD's dimensions, so a narrower
            external window wraps or clips a stream cut for a wider window, which
            makes the external client look worse than it is and fakes a result in
            TBD's favour. Expect exact sizing to be fiddly to hit by hand: emulator
            windows are dragged in pixels while tmux counts character cells, so
            landing on a given rows-by-columns geometry usually takes several
            tries. Nothing enforces it — the size is yours to get right.

            WHAT THIS DOES NOT MEASURE. tmux tailors its output to each client's
            declared terminal capabilities, so two different emulators attached to
            one window do not receive identical bytes. The comparison is
            informative about order-of-magnitude jerkiness. It is not a calibrated
            measurement, and must not be reported as one.
            """
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Option(name: .long, help: "Terminal ID (required when the worktree has more than one terminal)")
    var terminal: String?

    @Flag(name: .customLong("print"), help: "Write the attach script to stdout and exit (run it as sh -c \"$(...)\"; piping into sh does not work)")
    var printScript = false

    @Flag(name: .long, help: "Write the coordinates (socket path, session name, window id, pane id, terminal id) as JSON")
    var json = false

    /// `--print` and `--json` name two different documents on one stdout.
    /// Refused at parse time so the caller learns before a socket is opened.
    func validate() throws {
        if printScript && json {
            throw ValidationError(
                "--print and --json are mutually exclusive: one writes a shell script, "
                + "the other writes a coordinates object.")
        }
    }

    mutating func run() async throws {
        // The nesting gate runs before anything else so a user inside tmux is
        // told what to do instead, rather than after a round trip.
        if !printScript && !json,
           let refusal = externalAttachNestingRefusal(
            environment: ProcessInfo.processInfo.environment) {
            FileHandle.standardError.write(Data((refusal + "\n").utf8))
            throw ExitCode.failure
        }

        let client = SocketClient()
        let worktreeID = try resolveWorktreeArg(worktree, client: client)

        let terminals: [Terminal] = try client.call(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: worktreeID),
            resultType: [Terminal].self
        )
        let target = try resolveAttachTerminal(
            explicit: terminal, terminals: terminals, worktreeLabel: worktree)

        let result: TerminalAttachCommandResult = try client.call(
            method: RPCMethod.terminalAttachCommand,
            params: TerminalAttachCommandParams(worktreeID: worktreeID, terminalID: target.id),
            resultType: TerminalAttachCommandResult.self
        )

        if json {
            // Same discipline as `terminal list --json`: an encoding failure
            // names itself on stderr and exits nonzero. Printing nothing at
            // exit 0 would read to a harness as a terminal with no coordinates.
            guard let output = jsonString(ExternalAttachCoordinates(result)) else {
                FileHandle.standardError.write(Data(
                    "Error: could not encode the attach coordinates as JSON\n".utf8))
                throw ExitCode.failure
            }
            print(output)
            return
        }

        if printScript {
            // The script and nothing else — no banner, no trailing prose. A
            // consumer runs it as `sh -c "$(...)"`, which keeps their tty as
            // stdin; piping it into `sh` leaves stdin a pipe and the attach
            // fails for want of a terminal.
            print(result.script)
            return
        }

        let invocation = externalAttachExecInvocation(script: result.script)
        try execReplacingCurrentProcess(
            executablePath: invocation.executable,
            arguments: invocation.arguments,
            environment: ProcessInfo.processInfo.environment)
    }
}
