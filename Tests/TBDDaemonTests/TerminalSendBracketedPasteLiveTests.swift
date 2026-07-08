import Foundation
import Testing
@testable import TBDDaemonLib

/// Live-tmux proof of the `--submit` bracketed-paste delivery fix
/// (`handleTerminalSend` → `TmuxManager.pasteText` + separate Enter).
///
/// The daemon delivers a message body via `load-buffer` + `paste-buffer -d -p`
/// then presses Enter as a SEPARATE keystroke. The regression this guards:
/// large/multi-line bodies sent with raw `send-keys -l` were split by the pty
/// into multiple rapid reads, which a TUI's non-bracketed paste-burst detection
/// mistook for a paste and coalesced — absorbing the trailing Enter so nothing
/// submitted. With an explicit bracketed paste the `ESC[201~` terminator puts
/// the Enter provably OUTSIDE the paste.
///
/// Two cases prove the wire bytes at the pty:
///  - bracketed-paste mode ON (agent TUI): body arrives wrapped in
///    `ESC[200~`…`ESC[201~`, and the Enter (`\r`) follows OUTSIDE the wrapper.
///  - bracketed-paste mode OFF (plain shell): body arrives bare + `\r`, with no
///    `ESC[200~` — proving no shell regression.
///
/// The pane captures its own input under a raw tty via `head -c N > file`
/// (rc-free bootstrap: the pane command IS the capture). Body is >1 KB and
/// multi-line to exercise the original failure size. 15s deadlines throughout.
@Suite("terminal.send bracketed paste (live tmux)", .serialized)
struct TerminalSendBracketedPasteLiveTests {

    /// ESC[200~ / ESC[201~ bracketed-paste wrappers.
    private static let bracketStart = Data([0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e])
    private static let bracketEnd = Data([0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e])
    /// Enter → carriage return.
    private static let enter = Data([0x0d])

    /// A multi-line, >1 KB printable-ASCII body (the original failure size).
    private static func makeBody() -> Data {
        var text = ""
        for i in 1...40 {
            text += "Item \(i): the quick brown fox jumps over the lazy dog 0123456789\n"
        }
        text += "When finished reply with exactly: ACK"
        let data = Data(text.utf8)
        precondition(data.count > 1024, "body must exceed the ~1 KB pty split boundary")
        return data
    }

    /// The body AS IT ARRIVES on the wire: tmux `paste-buffer` (without `-r`)
    /// translates every LF (0x0a) to CR (0x0d) — the same behavior as the proven
    /// GUI paste path (`PasteExecutor`, also no `-r`). The TUI treats each CR
    /// inside the bracketed block as a line break in the pasted text (not a
    /// submit), so multi-line messages land intact. Length is preserved.
    private static func pastedForm(_ body: Data) -> Data {
        Data(body.map { $0 == 0x0a ? 0x0d : $0 })
    }

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
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// Poll `#{pane_current_command}` until it equals `command`, or time out.
    private func awaitPaneCommand(server: String, paneID: String, command: String) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if tmuxCapture(["-L", server, "display-message", "-t", paneID,
                            "-p", "#{pane_current_command}"]) == command { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("head never became the pane's foreground command")
    }

    /// Bootstrap a raw-capture pane sized to `count` bytes. When `bracketed` is
    /// true, the pane first enables DECSET 2004 (bracketed-paste mode) so tmux
    /// wraps a later `paste-buffer -p`. Returns the pane id once `head` owns the
    /// tty.
    private func startRawCapture(server: String, count: Int, outputPath: String,
                                 bracketed: Bool) async throws -> String {
        let prefix = bracketed ? "printf '\\033[?2004h' > /dev/tty; " : ""
        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main", "-x", "200", "-y", "50",
                           "/bin/sh", "-c",
                           "\(prefix)stty raw -echo; exec head -c \(count) > \(outputPath)"]),
                     "failed to bootstrap raw-capture tmux session")
        let paneID = try #require(
            tmuxCapture(["-L", server, "display-message", "-t", "main", "-p", "#{pane_id}"]),
            "could not resolve pane id")
        try await awaitPaneCommand(server: server, paneID: paneID, command: "head")
        return paneID
    }

    private func awaitFileBytes(path: String, expected: Data) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if let data = FileManager.default.contents(atPath: path), data == expected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let actual = FileManager.default.contents(atPath: path) ?? Data()
        let expectedBytes = Array(expected)
        let actualBytes = Array(actual)
        var diffHint = ""
        for i in 0..<min(expectedBytes.count, actualBytes.count) where expectedBytes[i] != actualBytes[i] {
            diffHint = "; first diff at byte \(i): expected 0x\(String(expectedBytes[i], radix: 16)), got 0x\(String(actualBytes[i], radix: 16))"
            break
        }
        Issue.record("capture mismatch: expected \(expected.count) bytes, got \(actual.count)\(diffHint)")
    }

    /// Mirror `handleTerminalSend`: bracketed paste of the body, then a separate
    /// Enter keystroke.
    private func sendWithSubmit(server: String, paneID: String, body: Data) async throws {
        let manager = TmuxManager()
        try await manager.pasteText(server: server, paneID: paneID, bytes: body)
        try await manager.sendKey(server: server, paneID: paneID, key: "Enter")
    }

    @Test("bracketed pane: body wrapped in ESC[200~/201~ with Enter OUTSIDE the paste")
    func bracketedPaneEnterOutsidePaste() async throws {
        guard await TmuxVersion.detect() != nil else { return }
        let server = "tbd-test-send-brk-\(UUID().uuidString.prefix(8))"
        let outputPath = NSTemporaryDirectory() + "tbd-send-brk-\(UUID().uuidString).bin"
        defer {
            tmux(["-L", server, "kill-server"])
            try? FileManager.default.removeItem(atPath: outputPath)
        }

        let body = Self.makeBody()
        let expected = Self.bracketStart + Self.pastedForm(body) + Self.bracketEnd + Self.enter
        let paneID = try await startRawCapture(
            server: server, count: expected.count, outputPath: outputPath, bracketed: true)

        try await sendWithSubmit(server: server, paneID: paneID, body: body)
        try await awaitFileBytes(path: outputPath, expected: expected)
    }

    @Test("plain pane: body arrives bare + Enter, no bracketed markers")
    func plainPaneNoBrackets() async throws {
        guard await TmuxVersion.detect() != nil else { return }
        let server = "tbd-test-send-plain-\(UUID().uuidString.prefix(8))"
        let outputPath = NSTemporaryDirectory() + "tbd-send-plain-\(UUID().uuidString).bin"
        defer {
            tmux(["-L", server, "kill-server"])
            try? FileManager.default.removeItem(atPath: outputPath)
        }

        let body = Self.makeBody()
        let expected = Self.pastedForm(body) + Self.enter
        let paneID = try await startRawCapture(
            server: server, count: expected.count, outputPath: outputPath, bracketed: false)

        try await sendWithSubmit(server: server, paneID: paneID, body: body)
        try await awaitFileBytes(path: outputPath, expected: expected)
    }
}
