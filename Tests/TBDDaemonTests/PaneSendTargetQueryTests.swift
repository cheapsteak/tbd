import Foundation
import Testing
@testable import TBDDaemonLib

/// Tier 1 — the read-only target consultation's command shapes and its parsing,
/// with no tmux server anywhere.
///
/// These are the queries `terminal.send` reads before it types. They are
/// deliberately NOT actuations: nothing here touches a process, a pty, or a
/// lifecycle, which is why none of them appears in the SwiftLint
/// `actuation_primitive_allowlist` regex.
@Suite("Pane send-target query")
struct PaneSendTargetQueryTests {

    // MARK: - Command builders

    @Test("the target query asks one list-panes for all four facts")
    func queryShape() {
        let args = TmuxManager.paneSendTargetQuery(server: "tbd-acme", paneID: "%7")
        #expect(args == [
            "-L", "tbd-acme", "list-panes", "-t", "%7", "-F",
            "#{pane_id}\t#{pane_dead}\t#{@tbd_terminal_id}\t#{pane_start_command}",
        ])
    }

    /// `list-panes -t %N` lists every pane in `%N`'s *window*, not just `%N`.
    /// Without `#{pane_id}` in the format there is no way to tell which line
    /// answered, so the query must keep asking for it.
    @Test("the target query asks each line to name its own pane")
    func queryCarriesPaneID() {
        let args = TmuxManager.paneSendTargetQuery(server: "tbd-acme", paneID: "%7")
        #expect(args.last?.hasPrefix("#{pane_id}\t") == true)
    }

    /// `display-message -p` prints an empty line and exits 0 for a pane that is
    /// gone, so it cannot distinguish "vanished" from "healthy". `list-panes`
    /// exits non-zero with `can't find pane`. The builder must stay on
    /// `list-panes` for the missing-pane branch to exist at all.
    @Test("the target query uses list-panes, not display-message")
    func queryUsesListPanes() {
        let args = TmuxManager.paneSendTargetQuery(server: "tbd-acme", paneID: "%7")
        #expect(args.contains("list-panes"))
        #expect(!args.contains("display-message"))
    }

    @Test("the stamp command sets the pane-scoped option on the given target")
    func stampShape() {
        let args = TmuxManager.setPaneTerminalIDCommand(
            server: "tbd-acme", target: "%7", terminalID: "F1A2")
        #expect(args == ["-L", "tbd-acme", "set-option", "-p", "-t", "%7", "@tbd_terminal_id", "F1A2"])
    }

    // MARK: - Parsing

    @Test("a live unstamped pane with no planted id resolves to no identity")
    func parseLiveUnknown() {
        #expect(TmuxManager.parsePaneSendTarget("%7\t0\t\t/bin/zsh -ic \"sleep 300\"\n", paneID: "%7")
            == .live(terminalID: nil))
    }

    @Test("pane_dead=1 is dead regardless of what else the pane answers")
    func parseDead() {
        #expect(TmuxManager.parsePaneSendTarget(
            "%7\t1\tF1A2\t/bin/zsh -ic \"claude\"\n", paneID: "%7") == .dead)
    }

    @Test("the stamped pane option wins over the start command")
    func parseStampedWins() {
        let line = "%7\t0\tSTAMPED\t/bin/zsh -ic \"export TBD_TERMINAL_ID='INLINED'; claude\"\n"
        #expect(TmuxManager.parsePaneSendTarget(line, paneID: "%7") == .live(terminalID: "STAMPED"))
    }

    @Test("an unstamped pane still answers from its start command")
    func parseFallsBackToStartCommand() {
        let line = "%7\t0\t\t/bin/zsh -ic \"export TBD_TERMINAL_ID='INLINED'; claude\"\n"
        #expect(TmuxManager.parsePaneSendTarget(line, paneID: "%7") == .live(terminalID: "INLINED"))
    }

    /// The start command is last precisely so its own tabs and separators stay
    /// inside it — the split takes the remainder rather than a fifth field.
    @Test("a tab inside the start command does not split it into a fifth field")
    func parseStartCommandWithTab() {
        let line = "%7\t0\t\t/bin/zsh -ic \"export TBD_TERMINAL_ID='ID9'; printf 'a\tb'\"\n"
        #expect(TmuxManager.parsePaneSendTarget(line, paneID: "%7") == .live(terminalID: "ID9"))
    }

    // MARK: - Selecting the pane the send actually named

    /// `list-panes -t %N` answers for every pane in `%N`'s window. A user who
    /// splits a TBD window by hand therefore gets two lines back, and the first
    /// one is whichever pane tmux lists first — a stranger. Reading it would
    /// refuse a perfectly healthy send.
    @Test("a split window answers for the named pane, not the first one listed")
    func parseSelectsNamedPaneInASplitWindow() {
        let output = """
            %1\t0\tSTRANGER\t/bin/zsh -ic "vim"
            %2\t0\tMINE\t/bin/zsh -ic "claude"

            """
        #expect(TmuxManager.parsePaneSendTarget(output, paneID: "%2") == .live(terminalID: "MINE"))
        #expect(TmuxManager.parsePaneSendTarget(output, paneID: "%1")
            == .live(terminalID: "STRANGER"))
    }

    /// The same hazard for liveness: a dead sibling pane must not make a live
    /// target look dead, nor a live sibling make a dead target look sendable.
    @Test("a dead sibling pane does not decide the named pane's liveness")
    func parseSelectsLivenessOfNamedPane() {
        let output = "%1\t1\t\tsh\n%2\t0\tMINE\tclaude\n"
        #expect(TmuxManager.parsePaneSendTarget(output, paneID: "%2") == .live(terminalID: "MINE"))
        #expect(TmuxManager.parsePaneSendTarget(output, paneID: "%1") == .dead)
    }

    /// A prefix match is not a match: `%1` must not answer for `%12`.
    @Test("pane ids are compared whole, not by prefix")
    func parsePaneIDMatchIsExact() {
        let output = "%12\t0\tMINE\tclaude\n"
        #expect(TmuxManager.parsePaneSendTarget(output, paneID: "%1") == .missing)
        #expect(TmuxManager.parsePaneSendTarget(output, paneID: "%12") == .live(terminalID: "MINE"))
    }

    /// A pane started without an explicit command — `tmux new-session -d` with
    /// no argument — reports an empty `#{pane_start_command}`, so the last
    /// field is genuinely empty rather than absent. It must still parse as four
    /// fields, not fall through to `.missing`.
    @Test("an empty trailing start command is still a complete answer")
    func parseEmptyStartCommand() {
        #expect(TmuxManager.parsePaneSendTarget("%0\t0\t\t\n", paneID: "%0")
            == .live(terminalID: nil))
        #expect(TmuxManager.parsePaneSendTarget("%0\t0\tMINE\t\n", paneID: "%0")
            == .live(terminalID: "MINE"))
    }

    @Test("empty or malformed output names nothing")
    func parseEmpty() {
        #expect(TmuxManager.parsePaneSendTarget("", paneID: "%7") == .missing)
        #expect(TmuxManager.parsePaneSendTarget("\n", paneID: "%7") == .missing)
        #expect(TmuxManager.parsePaneSendTarget("%7\t0\tonly-three\n", paneID: "%7") == .missing)
    }

    // MARK: - Identity resolution

    @Test("the quoted export form TBD actually plants is read back exactly")
    func resolveQuotedExport() {
        // The literal shape `newWindowCommand` produces from the `env` map.
        let command = "/bin/zsh -ic \"export TBD_TERMINAL_ID='9C1E-AB'; "
            + "export TBD_WORKTREE_ID='11'; claude\""
        #expect(TmuxManager.resolvePaneTerminalID(paneOption: "", startCommand: command) == "9C1E-AB")
    }

    @Test("an unquoted planted value stops at the first separator")
    func resolveUnquoted() {
        #expect(TmuxManager.resolvePaneTerminalID(
            paneOption: "", startCommand: "env TBD_TERMINAL_ID=9C1E-AB claude") == "9C1E-AB")
        #expect(TmuxManager.resolvePaneTerminalID(
            paneOption: "", startCommand: "TBD_TERMINAL_ID=9C1E-AB; claude") == "9C1E-AB")
    }

    @Test("a pane carrying neither source resolves to nil, never to a guess")
    func resolveNothing() {
        #expect(TmuxManager.resolvePaneTerminalID(
            paneOption: "", startCommand: "/bin/zsh -ic \"vim\"") == nil)
        #expect(TmuxManager.resolvePaneTerminalID(paneOption: "   ", startCommand: "") == nil)
        #expect(TmuxManager.resolvePaneTerminalID(
            paneOption: "", startCommand: "/bin/zsh -ic \"export TBD_TERMINAL_ID=''; vim\"") == nil)
    }
}
