import Foundation
import Testing
@testable import TBDDaemonLib

/// Proves the pane-state capture format expands to parseable values on a real
/// tmux server, through a real `-CC` stream (addendum §3: the replay's
/// `list-panes -F` capture rides the FIFO correlator). This is the live check
/// that every format variable in `PaneStateCapture.format` actually exists on
/// the running tmux — an unknown variable expands to empty and the parser
/// throws, so a green run certifies the whole field set.
@Suite("PaneStateCapture integration")
struct PaneStateCaptureIntegrationTests {

    @discardableResult
    private func tmux(_ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux"] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// One-shot tmux command capturing stdout (trimmed).
    private func tmuxCapture(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux"] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private func awaitClient(_ supervisor: TmuxControlSupervisor,
                             server: String) async throws -> TmuxControlCommandClient {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if let client = await supervisor.command(server: server) { return client }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PaneStateTestError.clientNeverReady
    }

    /// Bootstrap a fresh detached session running `command` directly (rc-free:
    /// the interactive user shell never starts — see PasteExecutor tests for
    /// why that discipline is load-bearing under parallel-suite load). Returns
    /// the pane id.
    private func startSession(server: String, command: String) throws -> String {
        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main", "-x", "120", "-y", "40",
                           "/bin/sh", "-c", command]),
                     "failed to bootstrap tmux session")
        return try #require(tmuxCapture(["-L", server, "display-message", "-t", "main", "-p", "#{pane_id}"]),
                            "could not resolve pane id")
    }

    /// Send the capture command through the correlator and parse the reply.
    private func captureState(client: TmuxControlCommandClient, paneID: String) async throws -> PaneState {
        let lines = try await client.send(PaneStateCapture.listPanesCommand(target: paneID))
        return try #require(try PaneStateCapture.state(forPane: paneID, in: lines),
                            "response did not contain pane \(paneID): \(lines)")
    }

    @Test("captures sane primary-screen state over a live -CC stream")
    func primaryScreenState() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else {
            return  // tmux missing or too old — skip
        }

        let server = "tbd-panestate-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }

        let paneID = try startSession(server: server, command: "sleep 30")

        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        let client = try await awaitClient(supervisor, server: server)

        let state = try await captureState(client: client, paneID: paneID)
        #expect(state.paneID == paneID)
        // Session is 120x40; the pane can't exceed that, so coords are bounded.
        #expect((0..<120).contains(state.cursorX))
        #expect((0..<40).contains(state.cursorY))
        #expect(state.alternateOn == false)
        // Fresh pane, never entered the alt screen — no saved cursor.
        #expect(state.alternateSavedX == nil)
        #expect(state.alternateSavedY == nil)
        // Default scroll region spans the whole pane.
        #expect(state.scrollRegionUpper == 0)
        #expect((1..<40).contains(state.scrollRegionLower))
        // Defaults: cursor visible, wraparound on, everything else off.
        #expect(state.cursorVisible == true)
        #expect(state.wraparound == true)
        #expect(state.insertMode == false)
        #expect(state.applicationCursorKeys == false)
        #expect(state.applicationKeypad == false)
        #expect(state.mouseStandard == false)
        #expect(state.mouseButton == false)
        #expect(state.mouseAny == false)
        #expect(state.mouseSGR == false)
        #expect(state.originMode == false)
        #expect(state.paneInMode == 0)
        // pane_width/pane_height (M4.3): the lone pane spans the 120-wide
        // window; height is window height minus any status line.
        #expect(state.width == 120)
        #expect((30...40).contains(state.height))
        // history_size (review H1): the pane has printed nothing, so its
        // primary scrollback is empty — and the variable must EXIST on this
        // tmux (an unknown variable expands empty and the parser throws).
        #expect(state.historySize == 0)

        await supervisor.stopAll()
    }

    @Test("reports alternate_on after the pane enters the alt screen")
    func altScreenState() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else {
            return  // tmux missing or too old — skip
        }

        let server = "tbd-panestate-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }

        // CSI ? 1049 h: save cursor + switch to the alt screen, then hold.
        let paneID = try startSession(
            server: server, command: "printf '\\033[?1049h'; sleep 30")

        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        let client = try await awaitClient(supervisor, server: server)

        // Poll until tmux has processed the escape and flipped alternate_on.
        let deadline = ContinuousClock.now + .seconds(15)
        var state = try await captureState(client: client, paneID: paneID)
        while !state.alternateOn, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            state = try await captureState(client: client, paneID: paneID)
        }
        #expect(state.alternateOn == true)
        // 1049 saves the primary-screen cursor, so a saved position exists now.
        #expect(state.alternateSavedX != nil)
        #expect(state.alternateSavedY != nil)

        await supervisor.stopAll()
    }
}

private enum PaneStateTestError: Error {
    case clientNeverReady
}
