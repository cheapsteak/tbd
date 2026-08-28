import Foundation
import Testing
import TBDShared
@testable import TBDApp

/// Tier 3: `TmuxBridge.prepareSession` against a real tmux server on a
/// throwaway socket. Lives here, not in `TBDAppTests`, because its runtime
/// depends on an external process it does not fully control.
@Suite("TmuxBridge view session (live tmux)")
struct TmuxBridgeViewSessionLiveTests {
    @Test(.timeLimit(.minutes(1)))
    func staleUnattachedViewSessionIsReplaced() async throws {
        guard let tmuxExecutablePath = TmuxExecutableResolver().resolve()?.path else { return }
        let server = "tbd-view-live-\(UUID().uuidString.prefix(8).lowercased())"
        defer { _ = runTmuxCLI(tmuxExecutablePath, ["-L", server, "kill-server"]) }
        let panelID = UUID()
        let sessionName = TmuxBridge.sessionName(for: panelID)

        try #require(runTmuxCLI(tmuxExecutablePath, [
            "-L", server, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24",
        ]).status == 0)
        let windowID = runTmuxCLI(tmuxExecutablePath, [
            "-L", server, "display-message", "-p", "-t", "main", "#{window_id}",
        ]).output
        try #require(windowID.hasPrefix("@"))
        // Exactly what a pre-kill that failed leaves behind: a same-named,
        // unattached leftover session. The name is derived from the panel
        // UUID, so it can never be sidestepped by picking a fresh one.
        try #require(runTmuxCLI(tmuxExecutablePath, [
            "-L", server, "new-session", "-d", "-s", sessionName, "-c", "/tmp",
        ]).status == 0)

        let prepared = try await TmuxBridge().prepareSession(
            panelID: panelID,
            server: server,
            windowID: windowID
        ).get()

        #expect(prepared.arguments == ["-u", "-L", server, "attach", "-t", sessionName])
        let activeWindow = runTmuxCLI(tmuxExecutablePath, [
            "-L", server, "display-message", "-p", "-t", sessionName, "#{window_id}",
        ])
        #expect(activeWindow.status == 0)
        #expect(activeWindow.output == windowID)
        // Replacement must not cost the agent its window: `kill-window`
        // destroys a window globally rather than unlinking it from one
        // session, which is why the leftover is replaced and never adopted.
        let inventory = runTmuxCLI(tmuxExecutablePath, [
            "-L", server, "list-windows", "-a", "-F", "#{window_id}",
        ])
        #expect(inventory.output.split(whereSeparator: { $0.isNewline }).contains(windowID[...]))
    }

    /// Runs one tmux command with a hard deadline, so a wedged server fails
    /// the test instead of hanging it.
    private func runTmuxCLI(
        _ executablePath: String,
        _ args: [String],
        timeout: TimeInterval = 10
    ) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (
            process.terminationStatus,
            output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
