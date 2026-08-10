import Foundation
import Testing
@testable import TBDDaemonLib

/// Proves M4.4's scrollback guarantee end-to-end against a real throwaway
/// tmux server: the production server-create path (`TmuxManager.ensureServer`)
/// must apply `history-limit 50000` BEFORE any window exists, so every pane's
/// ceiling supports the control-mode replay's `capture-pane -S -50000`.
///
/// tmux resolves `history_limit` per pane at window-creation time — setting
/// the option after a window exists does nothing for it. `newServerCommand`
/// therefore chains `set-option -g history-limit 50000 ; new-session ...` in
/// ONE tmux invocation: the server starts for the command list (it contains
/// new-session), runs set-option first, then creates window 0. This test
/// asserts all three layers:
///   (a) the global option is 50000,
///   (b) the FIRST window on the server (new-session's own window 0, whose
///       ID `ensureServer` returns) already has the limit,
///   (c) a content window created via the production `createWindow` path
///       inherits it too.
@Suite("History limit integration")
struct HistoryLimitIntegrationTests {

    /// One-shot tmux command via the same binary TmuxManager uses,
    /// capturing trimmed stdout (nil on nonzero exit).
    private func tmuxCapture(_ args: [String]) -> String? {
        guard let tmuxPath = TmuxManager.tmuxPath() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// Poll a tmux query until it returns `expected`, or throw at deadline.
    private func awaitTmuxValue(_ args: [String], expected: String,
                                what: String,
                                timeout: Duration = .seconds(15)) async throws {
        let deadline = ContinuousClock.now + timeout
        var last: String?
        while ContinuousClock.now < deadline {
            last = tmuxCapture(args)
            if last == expected { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HistoryLimitTestError.valueMismatch(
            what: what, expected: expected, actual: last ?? "<no output>"
        )
    }

    @Test func managedServerAppliesHistoryLimitBeforeFirstWindow() async throws {
        let server = "tbd-histlimit-" + UUID().uuidString
            .replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let tmux = TmuxManager()
        defer {
            // Best-effort teardown — the throwaway server must not outlive
            // the test even on assertion failure.
            _ = tmuxCapture(["-L", server, "kill-server"])
        }

        // Production seam: same call every server-creation path funnels
        // through (worktree create, pre-session, resume, terminal create).
        let initialWindowID = try await tmux.ensureServer(
            server: server, session: "main", cwd: "/tmp",
            cols: 220, rows: 50
        )
        let firstWindow = try #require(
            initialWindowID,
            "fresh server must report the new-session bootstrap window ID"
        )

        // (a) Global option landed.
        try await awaitTmuxValue(
            ["-L", server, "show-options", "-g", "history-limit"],
            expected: "history-limit 50000",
            what: "global history-limit option"
        )

        // (b) The FIRST window on the server — created by new-session itself —
        // already carries the limit. This is the load-bearing assertion: it
        // proves set-option executed before window 0 existed, not merely
        // before ensureServer returned.
        try await awaitTmuxValue(
            ["-L", server, "display-message", "-p", "-t", firstWindow,
             "#{history_limit}"],
            expected: "50000",
            what: "bootstrap window 0 pane history_limit"
        )

        // (c) A real content window created through the production
        // createWindow path inherits the limit at creation.
        let window = try await tmux.createWindow(
            server: server, session: "main", cwd: "/tmp",
            shellCommand: "sleep 15"
        )
        try await awaitTmuxValue(
            ["-L", server, "display-message", "-p", "-t", window.paneID,
             "#{history_limit}"],
            expected: "50000",
            what: "content window pane history_limit"
        )
    }
}

private enum HistoryLimitTestError: Error, CustomStringConvertible {
    case valueMismatch(what: String, expected: String, actual: String)

    var description: String {
        switch self {
        case let .valueMismatch(what, expected, actual):
            return "\(what): expected \(expected), got \(actual)"
        }
    }
}
