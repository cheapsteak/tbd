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

    @Test("the target query asks one list-panes for all three facts")
    func queryShape() {
        let args = TmuxManager.paneSendTargetQuery(server: "tbd-acme", paneID: "%7")
        #expect(args == [
            "-L", "tbd-acme", "list-panes", "-t", "%7", "-F",
            "#{pane_dead}\t#{@tbd_terminal_id}\t#{pane_start_command}",
        ])
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
        #expect(TmuxManager.parsePaneSendTarget("0\t\t/bin/zsh -ic \"sleep 300\"\n")
            == .live(terminalID: nil))
    }

    @Test("pane_dead=1 is dead regardless of what else the pane answers")
    func parseDead() {
        #expect(TmuxManager.parsePaneSendTarget("1\tF1A2\t/bin/zsh -ic \"claude\"\n") == .dead)
    }

    @Test("the stamped pane option wins over the start command")
    func parseStampedWins() {
        let line = "0\tSTAMPED\t/bin/zsh -ic \"export TBD_TERMINAL_ID='INLINED'; claude\"\n"
        #expect(TmuxManager.parsePaneSendTarget(line) == .live(terminalID: "STAMPED"))
    }

    @Test("an unstamped pane still answers from its start command")
    func parseFallsBackToStartCommand() {
        let line = "0\t\t/bin/zsh -ic \"export TBD_TERMINAL_ID='INLINED'; claude\"\n"
        #expect(TmuxManager.parsePaneSendTarget(line) == .live(terminalID: "INLINED"))
    }

    /// The start command is last precisely so its own tabs and separators stay
    /// inside it — the split takes the remainder rather than a fourth field.
    @Test("a tab inside the start command does not split it into a fourth field")
    func parseStartCommandWithTab() {
        let line = "0\t\t/bin/zsh -ic \"export TBD_TERMINAL_ID='ID9'; printf 'a\tb'\"\n"
        #expect(TmuxManager.parsePaneSendTarget(line) == .live(terminalID: "ID9"))
    }

    @Test("empty or malformed output names nothing")
    func parseEmpty() {
        #expect(TmuxManager.parsePaneSendTarget("") == .missing)
        #expect(TmuxManager.parsePaneSendTarget("\n") == .missing)
        #expect(TmuxManager.parsePaneSendTarget("0\tonly-two-fields\n") == .missing)
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
