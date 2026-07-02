import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib

/// Proves `PasteExecutor` delivers bulk paste bytes to a pane over a real
/// `tmux -CC` stream (addendum §2, the >4 KB paste rule: `load-buffer` +
/// `paste-buffer` WITHOUT `-p`). The pane captures its input with
/// `head -c N > file` under a **raw** tty (`stty raw -echo`): raw mode has no
/// canonical line queue, so the 6 KB burst can't trip the ~1 KB cooked-mode
/// input limit (`TTYHOG`), and `head -c N` exits deterministically after
/// exactly N bytes (no Ctrl-D needed — raw mode wouldn't honor it anyway).
/// The bytes must arrive verbatim — which also proves no `-p` double-wrap (a
/// pane that never enabled bracketed paste would otherwise see `\e[200~`
/// markers surrounding the payload, changing its length and content).
@Suite("PasteExecutor integration")
struct PasteExecutorIntegrationTests {

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
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let client = await supervisor.command(server: server) { return client }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PasteTestError.clientNeverReady
    }

    /// Poll `path` until its bytes equal `expected`, or time out.
    private func awaitFileBytes(path: String, expected: Data, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let data = FileManager.default.contents(atPath: path), data == expected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let actual = FileManager.default.contents(atPath: path) ?? Data()
        throw PasteTestError.contentMismatch(expected: expected.count, actual: actual.count)
    }

    /// Printable-ASCII payload of exactly `byteCount` bytes (a rolling
    /// alphanumeric pattern so any dropped/reordered run is easy to spot).
    private func makePayload(byteCount: Int) -> Data {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789".utf8)
        var bytes = [UInt8]()
        bytes.reserveCapacity(byteCount)
        for i in 0..<byteCount { bytes.append(alphabet[i % alphabet.count]) }
        return Data(bytes)
    }

    /// Bootstrap a fresh tmux session whose **pane command is the raw capture
    /// itself** — `/bin/sh -c 'stty raw -echo; exec head -c count > path'` —
    /// then block until `head` is the pane's foreground process. Returns the
    /// pane id.
    ///
    /// Passing the command straight to `new-session` skips the user's
    /// interactive zsh and its rc sourcing entirely: the pane reaches `head` in
    /// milliseconds instead of racing a multi-second shell startup under
    /// parallel-suite load (the old flake). The `exec` matters: a
    /// non-interactive `sh -c` does no job control, so a *forked* `head` never
    /// gets `tcsetpgrp`'d into the tty's foreground group and
    /// `#{pane_current_command}` would keep reporting `sh`/`bash`. `exec`
    /// replaces the shell in place, making `head` the pane's own process so the
    /// command reads back as `head`.
    ///
    /// Raw mode (`stty raw -echo`) has no canonical line queue, so the multi-KB
    /// burst can't trip the ~1 KB cooked-mode limit (`TTYHOG`); `head -c count`
    /// exits deterministically after exactly `count` bytes, so the capture file
    /// settles on its own — no interactive EOF. `head` stays the foreground
    /// process for the whole paste (it only exits once the final byte arrives),
    /// so the pane exiting afterwards is harmless — the tests read the on-disk
    /// file, not the pane.
    ///
    /// The `awaitPaneCommand` gate stays load-bearing: pasting before `head`
    /// owns the tty would dump the payload into the shell's line editor instead
    /// of `head`'s raw stdin. Polling `#{pane_current_command}` makes the
    /// handoff deterministic instead of sleep-timed.
    private func startRawCapture(server: String, count: Int, outputPath: String) async throws -> String {
        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main", "-x", "200", "-y", "50",
                           "/bin/sh", "-c", "stty raw -echo; exec head -c \(count) > \(outputPath)"]),
                     "failed to bootstrap raw-capture tmux session")
        let paneID = try #require(tmuxCapture(["-L", server, "display-message", "-t", "main", "-p", "#{pane_id}"]),
                                  "could not resolve pane id")
        try await awaitPaneCommand(server: server, paneID: paneID, command: "head", timeout: .seconds(15))
        return paneID
    }

    /// Poll `#{pane_current_command}` until it equals `command`, or time out.
    private func awaitPaneCommand(server: String, paneID: String,
                                  command: String, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let current = tmuxCapture(
                ["-L", server, "display-message", "-t", paneID, "-p", "#{pane_current_command}"])
            if current == command { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PasteTestError.paneCommandNeverStarted(command)
    }

    @Test("round-trips a >4 KB paste verbatim through load-buffer + paste-buffer")
    func roundTripVerbatim() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else {
            return  // tmux missing or too old — skip
        }

        let server = "tbd-paste-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }

        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-paste-out-\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let payload = makePayload(byteCount: 6 * 1024)
        let paneID = try await startRawCapture(server: server, count: payload.count, outputPath: outPath)

        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        let client = try await awaitClient(supervisor, server: server)

        try await PasteExecutor.paste(client: client, paneID: paneID, bytes: payload)

        try await awaitFileBytes(path: outPath, expected: payload, timeout: .seconds(15))
        await supervisor.stopAll()
    }

    @Test("two back-to-back pastes use unique buffers and land both payloads in order")
    func uniqueBuffersInOrder() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else {
            return
        }

        let server = "tbd-paste-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }

        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-paste-out-\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let first = makePayload(byteCount: 5 * 1024)
        let second = makePayload(byteCount: 5 * 1024)
        let paneID = try await startRawCapture(
            server: server, count: first.count + second.count, outputPath: outPath)

        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        let client = try await awaitClient(supervisor, server: server)

        try await PasteExecutor.paste(client: client, paneID: paneID, bytes: first)
        try await PasteExecutor.paste(client: client, paneID: paneID, bytes: second)

        try await awaitFileBytes(path: outPath, expected: first + second, timeout: .seconds(15))
        await supervisor.stopAll()
    }
}

private enum PasteTestError: Error {
    case clientNeverReady
    case contentMismatch(expected: Int, actual: Int)
    case paneCommandNeverStarted(String)
}
