import Foundation
import Testing
@testable import TBDDaemonLib

/// Tier 3 — the tab-separated pane probe against a real tmux server, queried
/// by a client with an **empty locale**.
///
/// A daemon relaunched by LaunchServices inherits no `LANG`, `LC_ALL` or
/// `LC_CTYPE`. A tmux client without a UTF-8 locale replaces every
/// non-printable byte of `-F` output with `_` — tab included — so without `-u`
/// `paneSendTargetQuery` read every live pane as missing while tmux exited 0.
/// The test runs the production query through `env -i`, once exactly as
/// `runTmux` would (behind `TmuxManager.executionArguments`) and once bare.
///
/// The bare half is a precondition, not the assertion: it checks the failure is
/// really reproduced here, and says nothing if this tmux happens not to
/// sanitize.
@Suite("tmux client locale (live tmux)", .serialized)
struct TmuxClientLocaleLiveTests {

    // MARK: - tmux helpers

    @discardableResult
    private func tmux(_ tmuxPath: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    /// Run `arguments` through a tmux client whose environment is empty apart
    /// from `HOME` and the harness's `TMUX_TMPDIR` — the latter so the client
    /// finds the server `scripts/test.sh` fenced.
    private func runUnderEmptyLocale(tmuxPath: String, _ arguments: [String]) async throws -> String {
        var environment = ["-i", "HOME=\(NSHomeDirectory())"]
        if let tmpdir = ProcessInfo.processInfo.environment["TMUX_TMPDIR"] {
            environment.append("TMUX_TMPDIR=\(tmpdir)")
        }
        return try await TmuxManager.runExternalCommand(
            executable: "/usr/bin/env",
            arguments: environment + [tmuxPath] + arguments,
            label: "env",
            timeout: .seconds(15))
    }

    // MARK: - Tests

    @Test("the pane-send probe reads a live pane as live under an empty locale")
    func paneSendProbeUnderEmptyLocale() async throws {
        guard let tmuxPath = TmuxManager.tmuxPath() else { return }
        let server = "locale-probe-\(UUID().uuidString.prefix(8))"
        defer { tmux(tmuxPath, ["-L", server, "kill-server"]) }
        #expect(tmux(tmuxPath, ["-L", server, "new-session", "-d", "-s", "main",
                                "-x", "80", "-y", "24", "/bin/sh", "-c", "sleep 300"]) == 0)
        let paneID = try #require(
            try await runUnderEmptyLocale(
                tmuxPath: tmuxPath,
                TmuxManager.executionArguments(
                    ["-L", server, "list-panes", "-t", "main", "-F", "#{pane_id}"]))
                .split(separator: "\n").first.map(String.init))
        let terminalID = UUID().uuidString
        #expect(tmux(tmuxPath, TmuxManager.setPaneTerminalIDCommand(
            server: server, target: paneID, terminalID: terminalID)) == 0)

        let query = TmuxManager.paneSendTargetQuery(server: server, paneID: paneID)

        let bare = try await runUnderEmptyLocale(tmuxPath: tmuxPath, query)
        if !bare.contains("\t") {
            #expect(bare.hasPrefix("\(paneID)_@"), "expected tmux's `_` substitution, got \(bare.debugDescription)")
        }

        let executed = try await runUnderEmptyLocale(
            tmuxPath: tmuxPath, TmuxManager.executionArguments(query))
        let probe = TmuxManager.parsePaneSendProbe(executed, paneID: paneID)
        #expect(probe.target == .live(terminalID: terminalID))
        #expect(probe.windowID?.hasPrefix("@") == true)
    }
}
