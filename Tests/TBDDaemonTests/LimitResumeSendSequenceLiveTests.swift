import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib

/// Live-tmux proof of the auto-resume send sequence (spec §Actuation 4):
/// Escape → 150ms → literal "continue" → 150ms → Enter must arrive as the
/// bytes ESC + "continue" + "\r" — no bracketed-paste wrapping, no dropped
/// keys. The pane captures its own input under a raw tty via
/// `head -c N > file` (rc-free bootstrap: the pane command IS the capture,
/// so no interactive shell startup can race the test under parallel-suite
/// load). 15s deadlines throughout.
@Suite("LimitResume send sequence (live tmux)", .serialized)
struct LimitResumeSendSequenceLiveTests {

    /// ESC + "continue" + CR = 10 bytes.
    private static let expectedBytes = Data([0x1b]) + Data("continue".utf8) + Data([0x0d])

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

    /// Bootstrap a raw-capture pane; block (≤15s) until `head` owns the tty.
    private func startRawCapture(server: String, outputPath: String) async throws -> String {
        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24",
                           "/bin/sh", "-c",
                           "stty raw -echo; exec head -c \(Self.expectedBytes.count) > \(outputPath)"]),
                     "failed to bootstrap raw-capture tmux session")
        let paneID = try #require(
            tmuxCapture(["-L", server, "display-message", "-t", "main", "-p", "#{pane_id}"]),
            "could not resolve pane id")
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if tmuxCapture(["-L", server, "list-panes", "-t", paneID,
                            "-F", "#{pane_current_command}"]) == "head" {
                return paneID
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("head never became the pane's foreground command")
        return paneID
    }

    private func awaitFileBytes(path: String, expected: Data) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if let data = FileManager.default.contents(atPath: path), data == expected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let actual = FileManager.default.contents(atPath: path) ?? Data()
        Issue.record("capture mismatch: expected \(expected.count) bytes, got \(actual.count): \(Array(actual))")
    }

    private func runSequence(server: String, paneID: String) async throws {
        let manager = TmuxManager()
        try await LimitResumeActuator.sendContinueSequence(
            tmux: manager, server: server, paneID: paneID,
            waiter: { duration in _ = try? await Task.sleep(for: duration) })
    }

    @Test func sequenceArrivesVerbatim() async throws {
        let server = "tbd-test-resume-\(UUID().uuidString.prefix(8))"
        let outputPath = NSTemporaryDirectory() + "tbd-resume-capture-\(UUID().uuidString).bin"
        defer {
            tmux(["-L", server, "kill-server"])
            try? FileManager.default.removeItem(atPath: outputPath)
        }
        let paneID = try await startRawCapture(server: server, outputPath: outputPath)
        try await runSequence(server: server, paneID: paneID)
        try await awaitFileBytes(path: outputPath, expected: Self.expectedBytes)
    }

    @Test func sequenceArrivesVerbatimWithControlModeClientAttached() async throws {
        let server = "tbd-test-resume-cc-\(UUID().uuidString.prefix(8))"
        let outputPath = NSTemporaryDirectory() + "tbd-resume-capture-\(UUID().uuidString).bin"
        // A live `tmux -CC` client on the same server — the "control-mode on"
        // coexistence case. Daemon-initiated send-keys must land identically.
        let ccClient = Process()
        ccClient.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let ccIn = Pipe(); let ccOut = Pipe()
        ccClient.standardInput = ccIn
        ccClient.standardOutput = ccOut
        ccClient.standardError = FileHandle.nullDevice
        defer {
            if ccClient.isRunning { ccClient.terminate() }
            tmux(["-L", server, "kill-server"])
            try? FileManager.default.removeItem(atPath: outputPath)
        }
        let paneID = try await startRawCapture(server: server, outputPath: outputPath)
        ccClient.arguments = ["tmux", "-CC", "-L", server, "attach", "-t", "main"]
        try ccClient.run()
        try await Task.sleep(for: .milliseconds(300))   // let the client attach
        try await runSequence(server: server, paneID: paneID)
        try await awaitFileBytes(path: outputPath, expected: Self.expectedBytes)
    }
}
