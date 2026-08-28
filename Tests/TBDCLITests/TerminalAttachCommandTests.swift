import ArgumentParser
import Foundation
import Testing
import TBDShared
@testable import TBDCLI

/// Tier 1 — parsing and the decision logic `tbd terminal attach` runs before it
/// opens a socket or replaces its own process image. No daemon, no tmux, no
/// exec: every branch that matters is a pure function taking the terminal list,
/// the environment, or the RPC result as an argument.
@Suite("tbd terminal attach")
struct TerminalAttachCommandTests {

    private static let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    private static func terminal(
        window: String,
        pane: String,
        label: String? = nil
    ) -> Terminal {
        Terminal(
            worktreeID: UUID(), tmuxWindowID: window, tmuxPaneID: pane,
            label: label, createdAt: createdAt, kind: .claude
        )
    }

    /// The message a `CLIError` presents to the user, or a recorded failure if
    /// the call unexpectedly succeeded. Asserting on composed output rather
    /// than on the fact that *something* threw is what makes the
    /// candidate-listing requirement testable.
    private func refusalMessage(
        _ body: () throws -> Terminal,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> String {
        do {
            let resolved = try body()
            Issue.record(
                "expected a refusal, got terminal \(resolved.id)",
                sourceLocation: sourceLocation)
            return ""
        } catch {
            return "\(error)"
        }
    }

    // MARK: - Parsing

    @Test("worktree alone parses, with no terminal and neither output flag")
    func bareParse() throws {
        let cmd = try TerminalAttach.parse(["my-worktree"])
        #expect(cmd.worktree == "my-worktree")
        #expect(cmd.terminal == nil)
        #expect(cmd.printScript == false)
        #expect(cmd.json == false)
    }

    @Test("--terminal, --print and --json each parse on their own")
    func flagsParseIndividually() throws {
        let withTerminal = try TerminalAttach.parse(["wt", "--terminal", "ABC"])
        #expect(withTerminal.terminal == "ABC")

        let printing = try TerminalAttach.parse(["wt", "--print"])
        #expect(printing.printScript == true)
        #expect(printing.json == false)

        let jsonOnly = try TerminalAttach.parse(["wt", "--json"])
        #expect(jsonOnly.json == true)
        #expect(jsonOnly.printScript == false)
    }

    /// Two different documents on one stdout. Refused at parse time, so the
    /// caller learns before a socket is opened.
    @Test("--print and --json together are refused")
    func printAndJSONAreExclusive() {
        #expect(throws: (any Error).self) {
            _ = try TerminalAttach.parse(["wt", "--print", "--json"])
        }
    }

    @Test("a worktree argument is required")
    func worktreeRequired() {
        #expect(throws: (any Error).self) {
            _ = try TerminalAttach.parse([])
        }
    }

    // MARK: - The help text's own claims

    /// `--help` rendered the way a user sees it, with wrapping newlines
    /// flattened back into single spaces. The claims below are properties of
    /// the composed help screen — discussion and flag help together — not of
    /// any one string literal, so moving a sentence between them cannot make
    /// the assertion vacuous.
    private func attachHelp(columns: Int = 80) -> String {
        TerminalAttach.helpMessage(includeHidden: false, columns: columns)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// The help used to say the `--print` output was safe to pipe straight
    /// into `sh`. It never was: `tmux attach` requires a tty on stdin, and a
    /// shell reading its script from a pipe leaves stdin as that pipe, so the
    /// attach exits 1 with "open terminal failed: not a terminal" — after the
    /// setup half of the script has already created the session, and with the
    /// reaping option riding the attach that just failed. Every piped attempt
    /// therefore also orphaned a session. Verified against tmux 3.6a.
    @Test("the help never claims the --print output can be piped into sh")
    func helpMakesNoPipeSafetyClaim() {
        let help = attachHelp()
        for claim in [
            "safe to pipe",
            "pipe the script into",
            "pipe straight into",
            "pipes into",
            "piping the script into `sh` works"
        ] {
            #expect(!help.contains(claim), "help still claims pipe-safety: \(claim)")
        }
    }

    /// Replacing a wrong incantation with nothing would leave the reader worse
    /// off, so the help has to carry one that works — and both forms do the
    /// same thing: they keep the caller's own terminal as stdin.
    @Test("the help carries an incantation that actually works from a tty")
    func helpCarriesAWorkingIncantation() {
        let help = attachHelp(columns: 100)
        #expect(help.contains(#"sh -c "$(tbd terminal attach <worktree> --print)""#))
        #expect(help.contains(#"eval "$(tbd terminal attach <worktree> --print)""#))
    }

    /// A reader who has seen the old guidance will try the pipe anyway unless
    /// the help says outright that it fails, and why — otherwise the error is
    /// confusing and the leftover session is invisible.
    @Test("the help says the pipe fails, and names the tty as the reason")
    func helpExplainsWhyThePipeFails() {
        let help = attachHelp(columns: 100)
        #expect(help.contains("PIPING THE SCRIPT INTO `sh` DOES NOT WORK"))
        #expect(help.contains("requires a tty on stdin"))
        #expect(help.contains("open terminal failed: not a terminal"))
        #expect(help.contains("client-less session behind"))
    }

    /// The spec asks the help to concede that exact sizing is fiddly to hit by
    /// hand, so a reader expects to fight it rather than assuming they have
    /// misread the rule.
    @Test("the help concedes that exact sizing is fiddly by hand")
    func helpConcedesSizingIsFiddly() {
        let help = attachHelp(columns: 100)
        #expect(help.contains("fiddly to hit by hand"))
        #expect(help.contains("character cells"))
    }

    // MARK: - Terminal resolution

    @Test("a worktree with exactly one terminal resolves to it")
    func soleTerminalResolves() throws {
        let only = Self.terminal(window: "@7", pane: "%7")
        let resolved = try resolveAttachTerminal(
            explicit: nil, terminals: [only], worktreeLabel: "wt")
        #expect(resolved.id == only.id)
    }

    @Test("--terminal picks the named terminal out of several")
    func explicitTerminalWins() throws {
        let first = Self.terminal(window: "@1", pane: "%1")
        let second = Self.terminal(window: "@2", pane: "%2")
        let third = Self.terminal(window: "@3", pane: "%3")
        let resolved = try resolveAttachTerminal(
            explicit: second.id.uuidString,
            terminals: [first, second, third],
            worktreeLabel: "wt")
        #expect(resolved.id == second.id)
        #expect(resolved.tmuxWindowID == "@2")
    }

    /// Never a guess. The error has to be actionable on its own, so it names
    /// every candidate — id, window and label — not just the count.
    @Test("several terminals with no --terminal is an error listing the candidates")
    func ambiguityIsRefusedWithCandidates() {
        let first = Self.terminal(window: "@1", pane: "%1", label: "agent")
        let second = Self.terminal(window: "@2", pane: "%2", label: "shell")
        let message = refusalMessage {
            try resolveAttachTerminal(
                explicit: nil, terminals: [first, second], worktreeLabel: "wt")
        }
        #expect(message.contains("--terminal"))
        #expect(message.contains(first.id.uuidString))
        #expect(message.contains(second.id.uuidString))
        #expect(message.contains("@1"))
        #expect(message.contains("@2"))
        #expect(message.contains("agent"))
        #expect(message.contains("shell"))
    }

    @Test("a --terminal that is not in this worktree is refused, with the candidates")
    func foreignTerminalIsRefused() {
        let mine = Self.terminal(window: "@1", pane: "%1")
        let stranger = UUID()
        let message = refusalMessage {
            try resolveAttachTerminal(
                explicit: stranger.uuidString, terminals: [mine], worktreeLabel: "wt")
        }
        #expect(message.contains(stranger.uuidString))
        #expect(message.contains(mine.id.uuidString))
    }

    @Test("a --terminal that is not a UUID is refused")
    func malformedTerminalIDIsRefused() {
        let message = refusalMessage {
            try resolveAttachTerminal(
                explicit: "not-a-uuid",
                terminals: [Self.terminal(window: "@1", pane: "%1")],
                worktreeLabel: "wt")
        }
        #expect(message.contains("not-a-uuid"))
    }

    @Test("a worktree with no terminals is refused")
    func emptyWorktreeIsRefused() {
        let message = refusalMessage {
            try resolveAttachTerminal(explicit: nil, terminals: [], worktreeLabel: "wt")
        }
        #expect(message.contains("wt"))
        #expect(message.contains("no terminals"))
    }

    // MARK: - The $TMUX nesting gate, both branches

    /// A tmux client nested in a tmux pane is not the second emulator this
    /// command exists to give you, so the exec path refuses — and the refusal
    /// has to name the way out.
    @Test("$TMUX set refuses and names --print")
    func nestingRefusedWhenInsideTmux() throws {
        let refusal = try #require(externalAttachNestingRefusal(
            environment: ["TMUX": "/private/tmp/tmux-501/tbd-ab12,4242,0"]))
        #expect(refusal.contains("--print"))
        #expect(refusal.contains("$TMUX"))
    }

    @Test("$TMUX unset does not refuse")
    func nestingAllowedOutsideTmux() {
        #expect(externalAttachNestingRefusal(environment: [:]) == nil)
        #expect(externalAttachNestingRefusal(environment: ["TERM": "xterm-256color"]) == nil)
    }

    /// A shell that exported and cleared `TMUX` presents as empty, and tmux
    /// itself always sets a non-empty triple — so empty is "not inside tmux",
    /// not "inside tmux with an unreadable socket".
    @Test("an empty $TMUX does not refuse")
    func emptyTMUXIsNotNesting() {
        #expect(externalAttachNestingRefusal(environment: ["TMUX": ""]) == nil)
    }

    // MARK: - The exec path

    /// The exec path is unobservable from a test — it never returns — so the
    /// argv it would hand to `execve` is composed by a function of its own and
    /// asserted here. The script is two shell statements, so what gets exec'd
    /// is a shell running them; `sh` exits with the attach's status, which is
    /// what lets a harness tell a failed attach from an empty measurement.
    @Test("the exec path runs the composed script under /bin/sh")
    func execInvocationIsShellRunningTheScript() {
        let script = ExternalAttachCommand.script(
            socketPath: "/private/tmp/tmux-501/tbd-ab12cd34",
            sessionName: ExternalAttachCommand.sessionName(for: UUID()),
            windowID: "@9")
        let invocation = externalAttachExecInvocation(script: script)
        #expect(invocation.executable == "/bin/sh")
        #expect(invocation.arguments == ["-c", script])
    }

    // MARK: - --json shape

    /// The coordinates, and only the coordinates. `--json` exists so
    /// `tmux pipe-pane -o` — which needs a socket path and a pane id and
    /// attaches no client at all — is drivable from this command; emitting the
    /// script alongside them would invite a consumer to `sh`-pipe a field out
    /// of a JSON document.
    @Test("--json carries the five coordinates and not the script")
    func jsonCarriesCoordinatesOnly() throws {
        let terminalID = UUID()
        let sessionName = ExternalAttachCommand.sessionName(for: terminalID)
        let result = TerminalAttachCommandResult(
            socketPath: "/private/tmp/tmux-501/tbd-ab12cd34",
            sessionName: sessionName,
            windowID: "@9",
            paneID: "%14",
            terminalID: terminalID,
            script: ExternalAttachCommand.script(
                socketPath: "/private/tmp/tmux-501/tbd-ab12cd34",
                sessionName: sessionName,
                windowID: "@9"))

        // Composed through the same helper the command prints with, so the
        // assertion is about what a caller actually receives.
        let text = try #require(jsonString(ExternalAttachCoordinates(result)))
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])

        #expect(object["socketPath"] as? String == "/private/tmp/tmux-501/tbd-ab12cd34")
        #expect(object["sessionName"] as? String == sessionName)
        #expect(object["windowID"] as? String == "@9")
        #expect(object["paneID"] as? String == "%14")
        #expect(object["terminalID"] as? String == terminalID.uuidString)
        #expect(object["script"] == nil)
        #expect(object.count == 5)
    }

    /// The pane id emitted is the one the daemon's identity probe answered
    /// for — carried through from the result, never re-derived from the window
    /// id or the session name. Reused pane coordinates have already sent
    /// keystrokes into an unrelated live session (issue #384).
    @Test("--json reports the result's pane id verbatim")
    func jsonPaneIDComesFromTheResult() {
        let result = TerminalAttachCommandResult(
            socketPath: "/tmp/sock", sessionName: "tbd-ext-deadbeef",
            windowID: "@9", paneID: "%987", terminalID: UUID(), script: "")
        #expect(ExternalAttachCoordinates(result).paneID == "%987")
    }
}
