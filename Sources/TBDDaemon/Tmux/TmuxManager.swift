import Foundation
import os

public struct TmuxManager: Sendable {
    public let dryRun: Bool
    private let counter: Counter

    // Thread-safe counter for generating unique mock IDs
    private final class Counter: Sendable {
        private let _value = OSAllocatedUnfairLock(initialState: 0)

        func next() -> Int {
            _value.withLock { value in
                let current = value
                value += 1
                return current
            }
        }
    }

    public init(dryRun: Bool = false) {
        self.dryRun = dryRun
        self.counter = Counter()
    }

    // MARK: - Static Command Builders

    /// Derive tmux server name from repo path (stable across DB recreations AND process restarts).
    /// Uses a simple deterministic hash (djb2) — NOT Swift's Hasher which is randomized per process.
    public static func serverName(forRepoPath path: String) -> String {
        var hash: UInt64 = 5381
        for byte in path.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte) // hash * 33 + byte
        }
        let hex = String(hash & 0xFFFFFFFF, radix: 16, uppercase: false)
        return "tbd-\(hex)"
    }

    /// Legacy: derive from UUID (for tests and backwards compat)
    public static func serverName(forRepoID id: UUID) -> String {
        let hex = id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "tbd-\(hex)"
    }

    public static func newServerCommand(server: String, session: String, cwd: String) -> [String] {
        ["-L", server, "new-session", "-d", "-s", session, "-c", cwd, "-PF", "#{window_id}"]
    }

    public static func hasSessionCommand(server: String, session: String) -> [String] {
        ["-L", server, "has-session", "-t", session]
    }

    public static func newWindowCommand(server: String, session: String, cwd: String, shellCommand: String) -> [String] {
        // Use shell -ic so commands with arguments work (e.g. "claude --dangerously-skip-permissions")
        // -i keeps it interactive (loads .zshrc), -c runs the command
        // After the command exits, the pane closes (tmux default behavior)
        let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return ["-L", server, "new-window", "-t", session, "-c", cwd, "-PF", "#{window_id} #{pane_id}", userShell, "-ic", shellCommand]
    }

    public static func killWindowCommand(server: String, windowID: String) -> [String] {
        ["-L", server, "kill-window", "-t", windowID]
    }

    public static func sendKeysCommand(server: String, paneID: String, text: String) -> [String] {
        ["-L", server, "send-keys", "-l", "-t", paneID, text]
    }

    public static func listWindowsCommand(server: String, session: String) -> [String] {
        ["-L", server, "list-windows", "-t", session, "-F", "#{window_id} #{pane_id}"]
    }

    // MARK: - Instance Execution Methods

    /// Ensures a tmux server and session exist.
    /// - Returns: The initial window ID if a new session was created (caller should kill it after
    ///   creating real windows), or `nil` if the session already existed.
    @discardableResult
    public func ensureServer(server: String, session: String, cwd: String) async throws -> String? {
        if dryRun { return nil }
        // Check if the session already exists before creating
        let hasSessionArgs = Self.hasSessionCommand(server: server, session: session)
        do {
            try await runTmux(hasSessionArgs)
            // Session already exists, nothing to do
            return nil
        } catch {
            // Session does not exist, create it — capture the initial window ID
            let args = Self.newServerCommand(server: server, session: session, cwd: cwd)
            let output = try await runTmux(args)
            // Hide tmux chrome globally — TBD app provides its own UI
            try? await runTmux(["-L", server, "set", "-g", "status", "off"])
            try? await runTmux(["-L", server, "set", "-g", "pane-border-style", "fg=black"])
            try? await runTmux(["-L", server, "set", "-g", "pane-border-indicators", "off"])
            try? await runTmux(["-L", server, "set", "-g", "default-terminal", "xterm-256color"])
            // Enable mouse so scroll wheel enters copy-mode and scrolls history
            try? await runTmux(["-L", server, "set", "-g", "mouse", "on"])
            // Enable extended key sequences so Shift+Arrow etc. pass through to applications
            try? await runTmux(["-L", server, "set", "-g", "xterm-keys", "on"])
            // Enable Kitty keyboard protocol so apps can distinguish Shift+Enter from Enter
            try? await runTmux(["-L", server, "set", "-g", "extended-keys", "on"])
            try? await runTmux(["-L", server, "set", "-g", "extended-keys-format", "kitty"])
            // Set SSH_AUTH_SOCK to stable symlink so shells get a resilient path
            try? await runTmux(["-L", server, "setenv", "-g", "SSH_AUTH_SOCK", SSHAgentResolver.defaultSymlinkPath])
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Kills an entire tmux server and all its sessions.
    public func killServer(server: String) async throws {
        if dryRun { return }
        try await runTmux(["-L", server, "kill-server"])
    }

    public func createWindow(server: String, session: String, cwd: String, shellCommand: String) async throws -> (windowID: String, paneID: String) {
        if dryRun {
            let n = counter.next()
            return (windowID: "@mock-\(n)", paneID: "%mock-\(n)")
        }
        let args = Self.newWindowCommand(server: server, session: session, cwd: cwd, shellCommand: shellCommand)
        let output = try await runTmux(args)
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 2 else {
            throw TmuxError.unexpectedOutput(output)
        }
        return (windowID: String(parts[0]), paneID: String(parts[1]))
    }

    public func killWindow(server: String, windowID: String) async throws {
        if dryRun { return }
        let args = Self.killWindowCommand(server: server, windowID: windowID)
        try await runTmux(args)
    }

    public func sendKeys(server: String, paneID: String, text: String) async throws {
        if dryRun { return }
        let args = Self.sendKeysCommand(server: server, paneID: paneID, text: text)
        try await runTmux(args)
    }

    public func listWindows(server: String, session: String) async throws -> [(windowID: String, paneID: String)] {
        if dryRun { return [] }
        let args = Self.listWindowsCommand(server: server, session: session)
        let output = try await runTmux(args)
        return output
            .split(separator: "\n")
            .compactMap { line -> (windowID: String, paneID: String)? in
                let parts = line.split(separator: " ")
                guard parts.count == 2 else { return nil }
                return (windowID: String(parts[0]), paneID: String(parts[1]))
            }
    }

    /// Check whether a tmux window exists by querying list-panes.
    public func windowExists(server: String, windowID: String) async -> Bool {
        if dryRun { return true }
        do {
            let args = ["-L", server, "list-panes", "-t", windowID]
            _ = try await runTmux(args)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Private

    /// Resolves the path to the tmux binary, checking common locations.
    private static func tmuxPath() -> String {
        for candidate in ["/usr/bin/tmux", "/usr/local/bin/tmux", "/opt/homebrew/bin/tmux"] {
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return "/usr/bin/tmux"
    }

    @discardableResult
    private func runTmux(_ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: Self.tmuxPath())
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let commandDescription = "tmux " + arguments.joined(separator: " ")

            process.terminationHandler = { _ in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                let output = stdout.isEmpty ? stderr : stdout

                if process.terminationStatus != 0 {
                    continuation.resume(throwing: TmuxError.commandFailed(
                        command: commandDescription,
                        status: process.terminationStatus,
                        output: output
                    ))
                } else {
                    continuation.resume(returning: stdout)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

public enum TmuxError: Error, Sendable {
    case commandFailed(command: String, status: Int32, output: String)
    case unexpectedOutput(String)
}
