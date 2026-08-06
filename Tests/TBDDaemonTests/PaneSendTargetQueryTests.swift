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

    /// A stand-in for the only thing TBD ever plants in `TBD_TERMINAL_ID`: a
    /// terminal row's `id.uuidString`.
    static let plantedID = "6E4B1C2A-9F03-4D57-8B11-2C7E5A0D9F44"

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
        let line = "%7\t0\tSTAMPED\t/bin/zsh -ic \"export TBD_TERMINAL_ID='\(Self.plantedID)'; claude\"\n"
        #expect(TmuxManager.parsePaneSendTarget(line, paneID: "%7") == .live(terminalID: "STAMPED"))
    }

    @Test("an unstamped pane still answers from its start command")
    func parseFallsBackToStartCommand() {
        let line = "%7\t0\t\t/bin/zsh -ic \"export TBD_TERMINAL_ID='\(Self.plantedID)'; claude\"\n"
        #expect(TmuxManager.parsePaneSendTarget(line, paneID: "%7")
            == .live(terminalID: Self.plantedID))
    }

    /// The start command is last precisely so its own tabs and separators stay
    /// inside it — the split takes the remainder rather than a fifth field.
    @Test("a tab inside the start command does not split it into a fifth field")
    func parseStartCommandWithTab() {
        let line = "%7\t0\t\t/bin/zsh -ic \"export TBD_TERMINAL_ID='\(Self.plantedID)'; printf 'a\tb'\"\n"
        #expect(TmuxManager.parsePaneSendTarget(line, paneID: "%7")
            == .live(terminalID: Self.plantedID))
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
        let command = "/bin/zsh -ic \"export TBD_TERMINAL_ID='\(Self.plantedID)'; "
            + "export TBD_WORKTREE_ID='11'; claude\""
        #expect(TmuxManager.resolvePaneTerminalID(paneOption: "", startCommand: command)
            == Self.plantedID)
    }

    @Test("a pane carrying neither source resolves to nil, never to a guess")
    func resolveNothing() {
        #expect(TmuxManager.resolvePaneTerminalID(
            paneOption: "", startCommand: "/bin/zsh -ic \"vim\"") == nil)
        #expect(TmuxManager.resolvePaneTerminalID(paneOption: "   ", startCommand: "") == nil)
        #expect(TmuxManager.resolvePaneTerminalID(
            paneOption: "", startCommand: "/bin/zsh -ic \"export TBD_TERMINAL_ID=''; vim\"") == nil)
    }

    // MARK: - User-authored text in the start command cannot forge an identity

    /// Both spawn paths inline the env map the same way, so the anchor the
    /// resolver looks for holds for the in-place profile swap too. Asserted
    /// against the builders rather than a hand-written literal, because the
    /// resolver's narrowness is only safe while this stays true.
    @Test("both spawn paths emit the assignment shape the resolver anchors on")
    func bothSpawnPathsEmitTheAnchor() throws {
        let env = ["TBD_TERMINAL_ID": Self.plantedID]
        let spawned = try #require(TmuxManager.newWindowCommand(
            server: "tbd-acme", session: "main", cwd: "/tmp", shellCommand: "claude",
            env: env).last)
        let respawned = try #require(TmuxManager.respawnWindowCommand(
            server: "tbd-acme", windowID: "@3", cwd: "/tmp", shellCommand: "claude",
            env: env).last)
        #expect(spawned.contains(TmuxManager.terminalIDExportAnchor))
        #expect(respawned.contains(TmuxManager.terminalIDExportAnchor))
        #expect(TmuxManager.resolvePaneTerminalID(paneOption: "", startCommand: spawned)
            == Self.plantedID)
        #expect(TmuxManager.resolvePaneTerminalID(paneOption: "", startCommand: respawned)
            == Self.plantedID)
    }

    /// The env map is inlined sorted by key, and `TBD_PROMPT_INSTRUCTIONS`
    /// carries a repo's arbitrary user-authored custom instructions — so it is
    /// inlined BEFORE `TBD_TERMINAL_ID` and any unanchored substring search
    /// reads the user's prose as the pane's identity. A pane that misreports
    /// its identity is refused as a stranger for the whole life of its window.
    @Test("instructions containing the bare env-var name do not poison resolution")
    func resolveIgnoresBareNameInInstructions() throws {
        let command = try #require(TmuxManager.newWindowCommand(
            server: "tbd-acme", session: "main", cwd: "/tmp", shellCommand: "claude",
            env: [
                "TBD_PROMPT_INSTRUCTIONS":
                    "When paging a sibling, read TBD_TERMINAL_ID= from its pane env first.",
                "TBD_TERMINAL_ID": Self.plantedID,
            ]).last)
        // The decoy really does precede the real assignment in the emitted string.
        let decoy = try #require(command.range(of: "TBD_TERMINAL_ID="))
        let real = try #require(command.range(of: TmuxManager.terminalIDExportAnchor))
        #expect(decoy.lowerBound < real.lowerBound)

        #expect(TmuxManager.resolvePaneTerminalID(paneOption: "", startCommand: command)
            == Self.plantedID)
    }

    /// The same hazard one step further: prose that spells the assignment out
    /// with a quoted value, so an anchored-but-first-match-only search would
    /// hand back the quoted garbage. Scanning every occurrence steps over it.
    @Test("instructions containing a quoted decoy value do not poison resolution")
    func resolveStepsOverQuotedDecoy() throws {
        let command = try #require(TmuxManager.newWindowCommand(
            server: "tbd-acme", session: "main", cwd: "/tmp", shellCommand: "claude",
            env: [
                "TBD_PROMPT_INSTRUCTIONS":
                    "Never run: export TBD_TERMINAL_ID='not-a-uuid' — it breaks routing.",
                "TBD_TERMINAL_ID": Self.plantedID,
            ]).last)
        // The quote-escaping leaves a complete anchor inside the instructions.
        #expect(command.ranges(of: TmuxManager.terminalIDExportAnchor).count == 2)
        #expect(TmuxManager.resolvePaneTerminalID(paneOption: "", startCommand: command)
            == Self.plantedID)

        // The same property stated directly, independent of the escaping rules.
        let handWritten = "/bin/zsh -ic \"export TBD_TERMINAL_ID='decoy'; "
            + "export TBD_TERMINAL_ID='\(Self.plantedID)'; claude\""
        #expect(TmuxManager.resolvePaneTerminalID(paneOption: "", startCommand: handWritten)
            == Self.plantedID)
    }

    /// Fail-open on a value that is not a terminal id at all: nil means "this
    /// pane gave no answer", and the send proceeds. Returning the garbage would
    /// be a positive disagreement and refuse a healthy pane.
    @Test("a non-UUID value in the real slot resolves to nil, not to garbage")
    func resolveRejectsNonUUIDValue() {
        let command = "/bin/zsh -ic \"export TBD_TERMINAL_ID='not-a-uuid'; claude\""
        #expect(TmuxManager.resolvePaneTerminalID(paneOption: "", startCommand: command) == nil)
        // Truncated: the anchor is there but the quote never closes.
        #expect(TmuxManager.resolvePaneTerminalID(
            paneOption: "", startCommand: "export TBD_TERMINAL_ID='\(Self.plantedID)") == nil)
    }

    /// The pane-option path never reaches the start-command parser, so no
    /// amount of user text in the command can influence a stamped pane.
    @Test("the stamped pane option is unaffected by decoys in the start command")
    func resolveStampWinsOverDecoys() {
        let command = "/bin/zsh -ic \"export TBD_PROMPT_INSTRUCTIONS='"
            + "export TBD_TERMINAL_ID=\(Self.plantedID)'; export TBD_TERMINAL_ID='"
            + "11111111-2222-3333-4444-555555555555'; claude\""
        #expect(TmuxManager.resolvePaneTerminalID(paneOption: "STAMPED", startCommand: command)
            == "STAMPED")
    }
}
