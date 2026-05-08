import Foundation
import Testing
@testable import TBDDaemonLib

@Suite struct ClaudeHookOverlayTests {

    // MARK: - Helpers

    /// Decode the overlay body and pull out the SessionStart + Stop command
    /// strings. Returns (sessionStart, stop) or nil if the shape is wrong.
    private func extractCommands(from data: Data) throws -> (String, String)? {
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let hooks = parsed?["hooks"] as? [String: Any] else { return nil }
        let sessionStart = hooks["SessionStart"] as? [[String: Any]]
        let inner = sessionStart?.first?["hooks"] as? [[String: Any]]
        let cmd0 = inner?.first?["command"] as? String
        let stop = hooks["Stop"] as? [[String: Any]]
        let stopHooks = stop?.first?["hooks"] as? [[String: Any]]
        let stopCmd = stopHooks?.first?["command"] as? String
        guard let cmd0, let stopCmd else { return nil }
        return (cmd0, stopCmd)
    }

    // MARK: - Shape

    @Test func generateBodyHasExpectedShape() throws {
        let data = try ClaudeHookOverlay.generateBody(cliPath: "/abs/TBDCLI")
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = parsed?["hooks"] as? [String: Any]
        #expect(hooks != nil)
        // SessionStart entry registers `<cli> session-event` with a `*` matcher.
        let sessionStart = hooks?["SessionStart"] as? [[String: Any]]
        let matcher0 = sessionStart?.first?["matcher"] as? String
        #expect(matcher0 == "*")
        let inner = sessionStart?.first?["hooks"] as? [[String: Any]]
        let cmd0 = inner?.first?["command"] as? String
        #expect(cmd0?.contains("session-event") == true)

        // Stop entry registers `<cli> notify`.
        let stop = hooks?["Stop"] as? [[String: Any]]
        let stopHooks = stop?.first?["hooks"] as? [[String: Any]]
        let stopCmd = stopHooks?.first?["command"] as? String
        #expect(stopCmd?.contains("notify") == true)
    }

    @Test func roundtripsAsValidJSON() throws {
        let data = try ClaudeHookOverlay.generateBody(cliPath: "/abs/TBDCLI")
        // Must round-trip — a malformed overlay file would crash Claude
        // Code's settings loader. JSONSerialization throws on invalid JSON.
        _ = try JSONSerialization.jsonObject(with: data, options: [])
    }

    // MARK: - Absolute-path baking

    @Test func bakesAbsolutePathIntoBothHooks() throws {
        let cli = "/Users/chang/tbd/worktrees/foo/.build/debug/TBDCLI"
        let data = try ClaudeHookOverlay.generateBody(cliPath: cli)
        let cmds = try extractCommands(from: data)
        #expect(cmds != nil)
        // Both hooks invoke the absolute path, not bare `tbd`.
        #expect(cmds?.0.contains(cli) == true)
        #expect(cmds?.1.contains(cli) == true)
        // Specifically, the absolute path should appear *as the binary*, not
        // bare `tbd`. The simplest signature: the command starts with a
        // single-quoted absolute path.
        #expect(cmds?.0.hasPrefix("'\(cli)'") == true)
        #expect(cmds?.1.contains("'\(cli)' notify") == true)
    }

    @Test func absolutePathIsShellQuoted() throws {
        // A path with a space must round-trip through JSON encoding *and*
        // come out as a single shell token. Use single-quote wrapping.
        let pathWithSpace = "/tmp/path with spaces/TBDCLI"
        let data = try ClaudeHookOverlay.generateBody(cliPath: pathWithSpace)
        let cmds = try extractCommands(from: data)
        #expect(cmds != nil)
        // Single-quoted form keeps the whole path as one shell argument.
        #expect(cmds?.0.contains("'\(pathWithSpace)'") == true)
        #expect(cmds?.1.contains("'\(pathWithSpace)'") == true)

        // Defense in depth: parse the command back out and verify it would
        // round-trip cleanly through `sh -c` as a single token. We don't
        // shell-execute here (the binary doesn't exist) — we just confirm
        // the quoting structure: the path is wrapped in matching `'...'`
        // and contains no unescaped single quotes inside.
        let cmd = cmds!.0
        // Strip the suffix to get just the quoted path.
        let suffix = " session-event 2>/dev/null || true"
        #expect(cmd.hasSuffix(suffix))
        let quoted = String(cmd.dropLast(suffix.count))
        #expect(quoted.hasPrefix("'") && quoted.hasSuffix("'"))
        // Inside the quotes, there are no `'` chars (the path under test
        // doesn't contain any).
        let inside = String(quoted.dropFirst().dropLast())
        #expect(inside == pathWithSpace)
    }

    @Test func embeddedSingleQuoteSurvives() throws {
        // Pathological input — paths with literal `'` are rare but valid.
        // The standard `'\''` trick must produce a shell-parseable command.
        let weirdPath = "/tmp/it's/TBDCLI"
        let data = try ClaudeHookOverlay.generateBody(cliPath: weirdPath)
        let cmds = try extractCommands(from: data)
        #expect(cmds != nil)
        // The `'` should be escaped as `'\''` inside the wrapping quotes.
        #expect(cmds?.0.contains(#"'/tmp/it'\''s/TBDCLI'"#) == true)
    }

    // MARK: - Fallback branch

    @Test func nilCliPathFallsBackToBareTbd() throws {
        let data = try ClaudeHookOverlay.generateBody(cliPath: nil)
        let cmds = try extractCommands(from: data)
        #expect(cmds != nil)
        #expect(cmds?.0 == "tbd session-event 2>/dev/null || true")
        #expect(cmds?.1.hasPrefix("MSG=") == true)
        #expect(cmds?.1.contains("tbd notify --type response_complete") == true)
        // Make sure no stray quoting was added when falling back.
        #expect(cmds?.0.contains("'") == false)
    }

    @Test func emptyCliPathFallsBackToBareTbd() throws {
        // Empty string is treated the same as nil — defensive against
        // accidental "" from a misbehaving caller.
        let data = try ClaudeHookOverlay.generateBody(cliPath: "")
        let cmds = try extractCommands(from: data)
        #expect(cmds?.0 == "tbd session-event 2>/dev/null || true")
        #expect(cmds?.1.contains("tbd notify") == true)
    }

    @Test func writeOverlayWithNilFallsBackAndStillWrites() throws {
        // Redirect overlay path to a temp file via override of the constant
        // is overkill for this test — instead, call writeOverlay() and
        // verify it succeeded and that the on-disk content reflects the
        // bare-`tbd` fallback. We restore the file afterwards.
        let path = ClaudeHookOverlay.overlayPath
        let fm = FileManager.default
        // Snapshot existing content so the test doesn't perturb a running
        // daemon's overlay (the daemon will rewrite on next restart anyway,
        // but the snapshot keeps the test idempotent for repeated runs).
        let snapshot = try? Data(contentsOf: URL(fileURLWithPath: path))
        defer {
            if let snapshot {
                try? snapshot.write(to: URL(fileURLWithPath: path))
            } else {
                try? fm.removeItem(atPath: path)
            }
        }

        let ok = ClaudeHookOverlay.writeOverlay(cliPath: nil)
        #expect(ok)
        let onDisk = try Data(contentsOf: URL(fileURLWithPath: path))
        let cmds = try extractCommands(from: onDisk)
        #expect(cmds?.0 == "tbd session-event 2>/dev/null || true")
    }
}
