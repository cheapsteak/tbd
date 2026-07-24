import Darwin
import Foundation
import Testing

@testable import TBDDaemonLib

/// ONE live-tmux smoke for the attach orchestration v2 (M4.3): a real `-CC`
/// attach through the supervisor to a pane with known scrollback, driving the
/// full attach.ready sequence (pause → capture → replay → gate → unpause) and
/// asserting the replay bytes on the vended pipe. The fuller matrix (alt
/// screen, mid-stream fullscreen Claude, pending output) is the next task.
///
/// Live-test discipline: unique `-L tbd-orch-<uuid8>` socket, rc-free
/// `/bin/sh` panes (the interactive user shell never starts), 15 s deadlines,
/// `defer` kill-server.
@Suite("Attach replay orchestration integration")
struct AttachReplayOrchestrationIntegrationTests {

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
        throw OrchestrationSmokeError.clientNeverReady
    }

    @Test("live -CC attach.ready replays known scrollback and ends with a CUP")
    func liveReplaySmoke() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else {
            return  // tmux missing or too old — skip
        }

        let server = "tbd-orch-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }

        // rc-free pane printing three known lines, then holding.
        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24",
                           "/bin/sh", "-c", "printf '%s\\n' orch-one orch-two orch-three; sleep 60"]),
                     "failed to bootstrap tmux session")
        let paneID = try #require(
            tmuxCapture(["-L", server, "display-message", "-t", "main", "-p", "#{pane_id}"]),
            "could not resolve pane id")

        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        let client = try await awaitClient(supervisor, server: server)

        // Wait until the pane has processed the printf (its content is what
        // the replay must reproduce).
        let contentDeadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < contentDeadline {
            let lines = try await client.send("capture-pane -p -t \(paneID)")
            if lines.contains(where: { $0.contains("orch-three") }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        // Real attach → vended read end, then the full attach.ready sequence
        // exactly as handleAttachReady drives it.
        let (readFD, _) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }
        let orchestrator = AttachReplayOrchestrator(
            supervisor: supervisor,
            commandProvider: { [supervisor] in await supervisor.command(server: $0) })
        let outcome = try await orchestrator.performAttachReady(server: server, paneID: paneID)
        #expect(outcome == .ready)
        #expect(await supervisor.isReady(server: server, paneID: paneID) == true)

        // Drain the replay from the pipe (nonblocking + poll, 15 s deadline):
        // read until the accumulated bytes end with a CUP (the replay's final
        // bytes) — live output can't precede it, the gate opened after it.
        let flags = fcntl(readFD, F_GETFL)
        _ = fcntl(readFD, F_SETFL, flags | O_NONBLOCK)
        var replay = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let readDeadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < readDeadline {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
            if n > 0 { replay.append(contentsOf: buffer[0..<n]) }
            if endsWithCUP(String(decoding: replay, as: UTF8.self)) { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let text = String(decoding: replay, as: UTF8.self)
        #expect(text.hasPrefix(ReplayWriter.resetPrelude), "replay must start with the reset prelude")
        for known in ["orch-one", "orch-two", "orch-three"] {
            #expect(text.contains(known), "replay missing known scrollback line \(known)")
        }
        #expect(endsWithCUP(text), "replay must end with a CUP; got tail \(text.suffix(24).debugDescription)")

        await supervisor.stopAll()
    }

    /// True when `text` ends with `ESC [ <row> ; <col> H`.
    private func endsWithCUP(_ text: String) -> Bool {
        text.range(of: "\u{1b}\\[[0-9]+;[0-9]+H$", options: .regularExpression) != nil
    }
}

private enum OrchestrationSmokeError: Error {
    case clientNeverReady
}
