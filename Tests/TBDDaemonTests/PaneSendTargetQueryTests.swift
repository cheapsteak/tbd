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

    @Test("the target query asks one list-panes for all five facts")
    func queryShape() {
        let args = TmuxManager.paneSendTargetQuery(server: "tbd-acme", paneID: "%7")
        #expect(args == [
            "-L", "tbd-acme", "list-panes", "-t", "%7", "-F",
            "#{pane_id}\t#{window_id}\t#{pane_dead}\t#{@tbd_terminal_id}\t#{pane_start_command}",
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
        #expect(TmuxManager.parsePaneSendTarget("%7\t@3\t0\t\t/bin/zsh -ic \"sleep 300\"\n", paneID: "%7")
            == .live(terminalID: nil))
    }

    @Test("pane_dead=1 retains the pane ownership identity")
    func parseDead() {
        #expect(TmuxManager.parsePaneSendTarget(
            "%7\t@3\t1\tF1A2\t/bin/zsh -ic \"claude\"\n", paneID: "%7")
            == .dead(terminalID: "F1A2"))
    }

    @Test("an unstamped dead pane retains identity from its start command")
    func parseDeadFallsBackToStartCommand() {
        let line = "%7\t@3\t1\t\t/bin/zsh -ic \"export TBD_TERMINAL_ID='\(Self.plantedID)'; claude\"\n"
        #expect(TmuxManager.parsePaneSendTarget(line, paneID: "%7")
            == .dead(terminalID: Self.plantedID))
    }

    @Test("a legacy dead pane with no planted id has no identity")
    func parseDeadUnknown() {
        #expect(TmuxManager.parsePaneSendTarget(
            "%7\t@3\t1\t\t/bin/zsh -ic \"claude\"\n", paneID: "%7")
            == .dead(terminalID: nil))
    }

    @Test("the stamped pane option wins over the start command")
    func parseStampedWins() {
        let line = "%7\t@3\t0\tSTAMPED\t/bin/zsh -ic \"export TBD_TERMINAL_ID='\(Self.plantedID)'; claude\"\n"
        #expect(TmuxManager.parsePaneSendTarget(line, paneID: "%7") == .live(terminalID: "STAMPED"))
    }

    @Test("an unstamped pane still answers from its start command")
    func parseFallsBackToStartCommand() {
        let line = "%7\t@3\t0\t\t/bin/zsh -ic \"export TBD_TERMINAL_ID='\(Self.plantedID)'; claude\"\n"
        #expect(TmuxManager.parsePaneSendTarget(line, paneID: "%7")
            == .live(terminalID: Self.plantedID))
    }

    /// The start command is last precisely so its own tabs and separators stay
    /// inside it — the split takes the remainder rather than a fifth field.
    @Test("a tab inside the start command does not split it into a fifth field")
    func parseStartCommandWithTab() {
        let line = "%7\t@3\t0\t\t/bin/zsh -ic \"export TBD_TERMINAL_ID='\(Self.plantedID)'; printf 'a\tb'\"\n"
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
            %1\t@3\t0\tSTRANGER\t/bin/zsh -ic "vim"
            %2\t@3\t0\tMINE\t/bin/zsh -ic "claude"

            """
        #expect(TmuxManager.parsePaneSendTarget(output, paneID: "%2") == .live(terminalID: "MINE"))
        #expect(TmuxManager.parsePaneSendTarget(output, paneID: "%1")
            == .live(terminalID: "STRANGER"))
    }

    /// The same hazard for liveness: a dead sibling pane must not make a live
    /// target look dead, nor a live sibling make a dead target look sendable.
    @Test("a dead sibling pane does not decide the named pane's liveness")
    func parseSelectsLivenessOfNamedPane() {
        let output = "%1\t@3\t1\t\tsh\n%2\t@3\t0\tMINE\tclaude\n"
        #expect(TmuxManager.parsePaneSendTarget(output, paneID: "%2") == .live(terminalID: "MINE"))
        #expect(TmuxManager.parsePaneSendTarget(output, paneID: "%1")
            == .dead(terminalID: nil))
    }

    /// A prefix match is not a match: `%1` must not answer for `%12`.
    @Test("pane ids are compared whole, not by prefix")
    func parsePaneIDMatchIsExact() {
        let output = "%12\t@3\t0\tMINE\tclaude\n"
        #expect(TmuxManager.parsePaneSendTarget(output, paneID: "%1") == .missing)
        #expect(TmuxManager.parsePaneSendTarget(output, paneID: "%12") == .live(terminalID: "MINE"))
    }

    /// A pane started without an explicit command — `tmux new-session -d` with
    /// no argument — reports an empty `#{pane_start_command}`, so the last
    /// field is genuinely empty rather than absent. It must still parse as five
    /// fields, not fall through to `.missing`.
    @Test("an empty trailing start command is still a complete answer")
    func parseEmptyStartCommand() {
        #expect(TmuxManager.parsePaneSendTarget("%0\t@3\t0\t\t\n", paneID: "%0")
            == .live(terminalID: nil))
        #expect(TmuxManager.parsePaneSendTarget("%0\t@3\t0\tMINE\t\n", paneID: "%0")
            == .live(terminalID: "MINE"))
    }

    @Test("empty or malformed output names nothing")
    func parseEmpty() {
        #expect(TmuxManager.parsePaneSendTarget("", paneID: "%7") == .missing)
        #expect(TmuxManager.parsePaneSendTarget("\n", paneID: "%7") == .missing)
        #expect(TmuxManager.parsePaneSendTarget("%7\t@3\t0\tonly-four\n", paneID: "%7") == .missing)
    }

    // MARK: - Identity resolution

    @Test("the quoted export form TBD actually plants is read back exactly")
    func resolveQuotedExport() throws {
        // Derived from the real builder so the fixture tracks it: the body is
        // `newWindowCommand`'s final argv element, and tmux reports the argv
        // in `#{pane_start_command}` with the separate shell flags
        // (`-i -l -c`, see TmuxManager.shellFlags(forShell:)) and the body
        // quoted as the final argument.
        let args = TmuxManager.newWindowCommand(
            server: "tbd-acme", session: "main", cwd: "/tmp",
            shellCommand: "claude",
            env: ["TBD_TERMINAL_ID": Self.plantedID, "TBD_WORKTREE_ID": "11"],
            environment: ["SHELL": "/bin/zsh"])
        let body = try #require(args.last)
        let command = "/bin/zsh -i -l -c \"" + body + "\""
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

    /// The two spawn paths that plant `TBD_TERMINAL_ID` into a pane's start
    /// command. Every adversarial case below is driven through both.
    ///
    /// They share one env-prefix builder (`TmuxManager.envExportPrefixed`), so
    /// today the two arms exercise the same code — but the resolver's anchor is
    /// only safe while *every* spawn path emits the identical shape, and the
    /// in-place profile swap that goes through `respawnWindowCommand` is the
    /// path a reader is least likely to check. Parameterising rather than
    /// copying the suite means the two can never drift apart in coverage.
    enum SpawnBuilder: CaseIterable, Sendable, CustomStringConvertible {
        case newWindow
        case respawnWindow

        var description: String {
            switch self {
            case .newWindow: "newWindowCommand"
            case .respawnWindow: "respawnWindowCommand"
            }
        }

        /// The shell command string the builder hands tmux — the same text tmux
        /// reports back as `#{pane_start_command}`.
        func startCommand(env: [String: String]) throws -> String {
            let args: [String]
            switch self {
            case .newWindow:
                args = TmuxManager.newWindowCommand(
                    server: "tbd-acme", session: "main", cwd: "/tmp",
                    shellCommand: "claude", env: env)
            case .respawnWindow:
                args = TmuxManager.respawnWindowCommand(
                    server: "tbd-acme", windowID: "@3", cwd: "/tmp",
                    shellCommand: "claude", env: env)
            }
            return try #require(args.last)
        }
    }

    /// Both spawn paths inline the env map the same way, so the anchor the
    /// resolver looks for holds for the in-place profile swap too. Asserted
    /// against the builders rather than a hand-written literal, because the
    /// resolver's narrowness is only safe while this stays true.
    @Test("a spawn path emits the assignment shape the resolver anchors on",
          arguments: SpawnBuilder.allCases)
    func spawnPathEmitsTheAnchor(builder: SpawnBuilder) throws {
        let command = try builder.startCommand(env: ["TBD_TERMINAL_ID": Self.plantedID])
        #expect(command.contains(TmuxManager.terminalIDExportAnchor))
        #expect(TmuxManager.resolvePaneTerminalID(paneOption: "", startCommand: command)
            == Self.plantedID)
    }

    /// The env map is inlined sorted by key, and `TBD_PROMPT_INSTRUCTIONS`
    /// carries a repo's arbitrary user-authored custom instructions — so it is
    /// inlined BEFORE `TBD_TERMINAL_ID` and any unanchored substring search
    /// reads the user's prose as the pane's identity. A pane that misreports
    /// its identity is refused as a stranger for the whole life of its window.
    @Test("instructions containing the bare env-var name do not poison resolution",
          arguments: SpawnBuilder.allCases)
    func resolveIgnoresBareNameInInstructions(builder: SpawnBuilder) throws {
        let command = try builder.startCommand(env: [
            "TBD_PROMPT_INSTRUCTIONS":
                "When paging a sibling, read TBD_TERMINAL_ID= from its pane env first.",
            "TBD_TERMINAL_ID": Self.plantedID,
        ])
        // The decoy really does precede the real assignment in the emitted string.
        let decoy = try #require(command.range(of: "TBD_TERMINAL_ID="))
        let real = try #require(command.range(of: TmuxManager.terminalIDExportAnchor))
        #expect(decoy.lowerBound < real.lowerBound)
        // It is not an anchor at all: no `export ` and no opening quote.
        #expect(command.ranges(of: TmuxManager.terminalIDExportAnchor).count == 1)

        #expect(TmuxManager.resolvePaneTerminalID(paneOption: "", startCommand: command)
            == Self.plantedID)
    }

    /// The same hazard one step further: prose that spells the assignment out
    /// with a quoted value, so an anchored-but-first-match-only search would
    /// give up at the decoy and fail open. Scanning every occurrence steps over
    /// it and still finds the real id.
    ///
    /// What the decoy occurrence yields is asserted rather than described,
    /// because it is *not* the decoy's payload: `'` is escaped as `'\''`, the
    /// anchor consumes the first of those quotes, and the value read runs to
    /// the next quote — a lone backslash. `not-a-uuid` is never extracted.
    @Test("instructions containing a quoted decoy value do not poison resolution",
          arguments: SpawnBuilder.allCases)
    func resolveStepsOverQuotedDecoy(builder: SpawnBuilder) throws {
        let command = try builder.startCommand(env: [
            "TBD_PROMPT_INSTRUCTIONS":
                "Never run: export TBD_TERMINAL_ID='not-a-uuid' — it breaks routing.",
            "TBD_TERMINAL_ID": Self.plantedID,
        ])
        // The quote-escaping leaves a complete anchor inside the instructions.
        #expect(command.ranges(of: TmuxManager.terminalIDExportAnchor).count == 2)
        #expect(Self.valueAtFirstAnchor(of: command) == "\\")
        #expect(TmuxManager.resolvePaneTerminalID(paneOption: "", startCommand: command)
            == Self.plantedID)
    }

    /// The one decoy shape whose extracted value is neither a backslash nor the
    /// payload: instructions ending exactly at the `=`, so the anchor closes on
    /// the env entry's own closing quote and the value read is the `; export …=`
    /// separator that always follows it. Also not a UUID.
    @Test("instructions ending at the assignment read the separator, not an id",
          arguments: SpawnBuilder.allCases)
    func resolveStepsOverTruncatedDecoy(builder: SpawnBuilder) throws {
        let command = try builder.startCommand(env: [
            "TBD_PROMPT_INSTRUCTIONS": "Never write export TBD_TERMINAL_ID=",
            "TBD_TERMINAL_ID": Self.plantedID,
        ])
        #expect(command.ranges(of: TmuxManager.terminalIDExportAnchor).count == 2)
        #expect(Self.valueAtFirstAnchor(of: command) == "; export TBD_TERMINAL_ID=")
        #expect(TmuxManager.resolvePaneTerminalID(paneOption: "", startCommand: command)
            == Self.plantedID)
    }

    /// Hand-written rather than built, so it holds the property independent of
    /// the escaping rules: a raw adjacent decoy whose value really *is* read as
    /// `decoy` still resolves to the real id, because `decoy` is not a UUID.
    /// No `env` value can produce this shape — only unescaped command text can.
    @Test("a raw adjacent decoy is stepped over on its UUID check")
    func resolveStepsOverRawDecoy() {
        let command = "/bin/zsh -ic \"export TBD_TERMINAL_ID='decoy'; "
            + "export TBD_TERMINAL_ID='\(Self.plantedID)'; claude\""
        #expect(Self.valueAtFirstAnchor(of: command) == "decoy")
        #expect(TmuxManager.resolvePaneTerminalID(paneOption: "", startCommand: command)
            == Self.plantedID)
    }

    /// What `resolvePaneTerminalID` would return at the FIRST anchor if it did
    /// not validate and keep scanning. Spelled out here so the tests above
    /// assert the extracted text rather than asserting the doc comment.
    static func valueAtFirstAnchor(of command: String) -> String? {
        guard let anchor = command.range(of: TmuxManager.terminalIDExportAnchor) else { return nil }
        let rest = command[anchor.upperBound...]
        guard let close = rest.firstIndex(of: "'") else { return nil }
        return String(rest[..<close])
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

    // MARK: - Window existence

    /// `windowExists` used to answer a plain Bool and fold every tmux failure
    /// into `false`, so "the window is gone" and "tmux could not be asked" were
    /// the same answer — and the Watch Desk read that answer as license to spawn
    /// an agent and revoke a running judge's lease. This is the branch that
    /// decides between them, unit-tested here because the desk's own fixtures run
    /// in dry-run mode and never reach a real tmux error at all.
    @Test("only tmux's own can't-find text proves a window gone")
    func windowGoneOnlyWhenTmuxLooked() {
        #expect(
            TmuxManager.classifyWindowExistence(status: 1, output: "can't find window @7")
                == .gone)
        #expect(
            TmuxManager.classifyWindowExistence(status: 1, output: "can't find session: tbd-x")
                == .gone)
    }

    /// Everything else with a non-zero exit is the query failing. Each of these
    /// is a tmux that was never in a position to say anything about the window,
    /// and reading any of them as absence is the field incident.
    @Test("an unreachable or broken tmux is unverifiable, never gone")
    func windowUnverifiableOnEveryOtherFailure() {
        for output in [
            "error connecting to /tmp/tmux-501/tbd (No such file or directory)",
            "protocol version mismatch (client 8, server 7)",
            "lost server",
            "",
        ] {
            let verdict = TmuxManager.classifyWindowExistence(status: 1, output: output)
            #expect(verdict != .gone, "\(output.isEmpty ? "<empty>" : output) must not prove absence")
            guard case .unverifiable(let error) = verdict else {
                Issue.record("expected .unverifiable for \(output.isEmpty ? "<empty>" : output)")
                continue
            }
            // A rail that refuses to act should be able to say why it could not look.
            #expect(error.contains("exited 1"), "the verdict must carry tmux's status: \(error)")
        }
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
