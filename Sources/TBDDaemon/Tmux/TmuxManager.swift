import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "TmuxManager")

public struct TmuxManager: Sendable {
    public let dryRun: Bool
    private let counter: Counter
    /// Optional test hook that records every dryRun command invocation. When set,
    /// dry-run paths still no-op, but the recorder receives the argv that would
    /// have been passed to tmux. Used by spawn / swap integration tests to assert
    /// command shapes without spawning an actual tmux server.
    public let dryRunRecorder: (@Sendable ([String]) -> Void)?

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

    public init(dryRun: Bool = false, dryRunRecorder: (@Sendable ([String]) -> Void)? = nil) {
        self.dryRun = dryRun
        self.counter = Counter()
        self.dryRunRecorder = dryRunRecorder
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

    /// Minimum sane terminal size. Smaller values are ignored — tmux's own
    /// default (80x24) is preferable to a degenerate value.
    public static let minCols: Int = 80
    public static let minRows: Int = 24

    /// Default pane size used when a caller does not supply explicit
    /// dimensions. Larger than tmux's own 80x24 default so Claude doesn't
    /// render into hard-wrapped scrollback that can't be reflowed once a
    /// wider SwiftTerm view attaches.
    public static let defaultCols: Int = 220
    public static let defaultRows: Int = 50

    /// Returns the explicit `-x N -y M` flags to pass to tmux when the caller
    /// supplied a usable size. Returns an empty array when either dimension
    /// is nil or below the minimum, leaving tmux to use its own default.
    private static func sizeFlags(cols: Int?, rows: Int?) -> [String] {
        guard let cols, let rows, cols >= minCols, rows >= minRows else { return [] }
        return ["-x", "\(cols)", "-y", "\(rows)"]
    }

    public static func newServerCommand(server: String, session: String, cwd: String, cols: Int? = nil, rows: Int? = nil) -> [String] {
        // Place size flags before -PF so the format spec stays last (consistent
        // with tmux argument-order conventions).
        ["-L", server, "new-session", "-d", "-s", session, "-c", cwd]
            + sizeFlags(cols: cols, rows: rows)
            + ["-PF", "#{window_id}"]
    }

    public static func hasSessionCommand(server: String, session: String) -> [String] {
        ["-L", server, "has-session", "-t", session]
    }

    public static func newWindowCommand(server: String, session: String, cwd: String, shellCommand: String, env: [String: String] = [:], sensitiveEnv: [String: String] = [:], cols: Int? = nil, rows: Int? = nil) -> [String] {
        // Use shell -ic so commands with arguments work (e.g. "claude --dangerously-skip-permissions")
        // -i keeps it interactive (loads .zshrc), -c runs the command
        // After the command exits, the pane closes (tmux default behavior)
        let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var envPrefix = ""
        for (key, value) in env.sorted(by: { $0.key < $1.key }) {
            let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
            envPrefix += "export \(key)='\(escaped)'; "
        }
        let fullCommand = envPrefix.isEmpty ? shellCommand : "\(envPrefix)\(shellCommand)"
        // Sensitive env vars use tmux's -e KEY=VALUE flag so the secret is set in
        // the spawned window's environment directly, NOT inlined into the shell
        // command argv. This keeps the secret out of `ps aux` for the
        // long-running shell/claude process. (The secret still appears briefly
        // in the tmux invocation's own argv during fork/exec, but tmux re-execs
        // and its server process does not retain the original argv visibly.)
        var eFlags: [String] = []
        for (key, value) in sensitiveEnv.sorted(by: { $0.key < $1.key }) {
            eFlags.append("-e")
            eFlags.append("\(key)=\(value)")
        }
        // Note: size flags (-x/-y) are intentionally NOT emitted here. tmux's
        // `new-window` does not support those flags (only `new-session`,
        // `split-window`, `resize-window`, and `resize-pane` do). The session's
        // `-x`/`-y` from `new-session` governs the initial size, and once the
        // SwiftTerm client attaches it issues TIOCSWINSZ to resize the pane to
        // the actual viewport. The cols/rows parameters are kept on this
        // function for now since callers still pass them; we just don't emit.
        _ = cols
        _ = rows
        return ["-L", server, "new-window", "-t", session, "-c", cwd]
            + eFlags
            + ["-PF", "#{window_id} #{pane_id}", userShell, "-ic", fullCommand]
    }

    /// Resize an existing tmux window to the given cell dimensions.
    public static func resizeWindowCommand(server: String, windowID: String, cols: Int, rows: Int) -> [String] {
        ["-L", server, "resize-window", "-t", windowID, "-x", "\(cols)", "-y", "\(rows)"]
    }

    /// Switch a window out of `window-size manual` mode so attached clients
    /// can drive the size via their own TIOCSWINSZ. tmux's `resize-window`
    /// implicitly sets manual mode, which freezes the window at that size
    /// and prevents SwiftTerm's per-pane ioctl from shrinking it back when
    /// the actual rendered area is smaller than the broadcast measurement.
    public static func setWindowSizeLatestCommand(server: String, windowID: String) -> [String] {
        ["-L", server, "set-option", "-wt", windowID, "window-size", "latest"]
    }

    public static func killWindowCommand(server: String, windowID: String) -> [String] {
        ["-L", server, "kill-window", "-t", windowID]
    }

    public static func sendKeysCommand(server: String, paneID: String, text: String) -> [String] {
        ["-L", server, "send-keys", "-l", "-t", paneID, text]
    }

    /// Send a tmux key name (e.g. "Enter", "Escape") without the -l (literal) flag.
    public static func sendKeyCommand(server: String, paneID: String, key: String) -> [String] {
        ["-L", server, "send-keys", "-t", paneID, key]
    }

    public static func listWindowsCommand(server: String, session: String) -> [String] {
        ["-L", server, "list-windows", "-t", session, "-F", "#{window_id} #{pane_id}"]
    }

    public static func capturePaneCommand(server: String, paneID: String) -> [String] {
        ["-L", server, "capture-pane", "-p", "-t", paneID]
    }

    /// Capture pane content with ANSI escape sequences and joined wrapped lines preserved.
    public static func capturePaneWithAnsiCommand(server: String, paneID: String) -> [String] {
        ["-L", server, "capture-pane", "-p", "-e", "-J", "-t", paneID]
    }

    public static func paneCurrentCommandQuery(server: String, paneID: String) -> [String] {
        ["-L", server, "list-panes", "-t", paneID, "-F", "#{pane_current_command}"]
    }

    public static func panePIDQuery(server: String, paneID: String) -> [String] {
        ["-L", server, "list-panes", "-t", paneID, "-F", "#{pane_pid}"]
    }

    /// send-keys without -l so "Enter" is interpreted as a key name, not literal text.
    public static func sendCommandArgs(server: String, paneID: String, command: String) -> [String] {
        ["-L", server, "send-keys", "-t", paneID, command, "Enter"]
    }

    // MARK: - Instance Execution Methods

    /// Ensures a tmux server and session exist.
    /// - Returns: The initial window ID if a new session was created (caller should kill it after
    ///   creating real windows), or `nil` if the session already existed.
    @discardableResult
    public func ensureServer(server: String, session: String, cwd: String, cols: Int? = nil, rows: Int? = nil) async throws -> String? {
        if dryRun {
            // Even in dry-run, still record the new-session shape so tests can
            // assert that size flags propagate.
            let args = Self.newServerCommand(server: server, session: session, cwd: cwd, cols: cols, rows: rows)
            dryRunRecorder?(args)
            return nil
        }
        // Check if the session already exists before creating
        let hasSessionArgs = Self.hasSessionCommand(server: server, session: session)
        do {
            try await runTmux(hasSessionArgs)
            // Session already exists, nothing to do
            return nil
        } catch {
            // Session does not exist, create it — capture the initial window ID
            let args = Self.newServerCommand(server: server, session: session, cwd: cwd, cols: cols, rows: rows)
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

    public func createWindow(server: String, session: String, cwd: String, shellCommand: String, env: [String: String] = [:], sensitiveEnv: [String: String] = [:], cols: Int? = nil, rows: Int? = nil) async throws -> (windowID: String, paneID: String) {
        let result: (windowID: String, paneID: String)
        if dryRun {
            let args = Self.newWindowCommand(server: server, session: session, cwd: cwd, shellCommand: shellCommand, env: env, sensitiveEnv: sensitiveEnv, cols: cols, rows: rows)
            dryRunRecorder?(args)
            let n = counter.next()
            result = (windowID: "@mock-\(n)", paneID: "%mock-\(n)")
        } else {
            let args = Self.newWindowCommand(server: server, session: session, cwd: cwd, shellCommand: shellCommand, env: env, sensitiveEnv: sensitiveEnv, cols: cols, rows: rows)
            let output = try await runTmux(args)
            let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            guard parts.count == 2 else {
                throw TmuxError.unexpectedOutput(output)
            }
            result = (windowID: String(parts[0]), paneID: String(parts[1]))
        }

        // tmux's `new-window` does NOT accept -x/-y, and a freshly-created
        // window inherits its size from the session's attached client. The TBD
        // `main` session has no attached clients (we only ever attach to
        // grouped `view-*` sessions), so tmux falls back to its 80x24 default
        // for the new window — leaving never-viewed terminals frozen at that
        // size with permanent hard-wraps in scrollback. Issue an explicit
        // `resize-window` immediately after creation to lock in the requested
        // size. Failures here are non-fatal: the window itself was created
        // successfully, so we log a warning and continue.
        if let cols, let rows, cols >= Self.minCols, rows >= Self.minRows {
            do {
                try await resizeWindow(server: server, windowID: result.windowID, cols: cols, rows: rows)
            } catch {
                logger.warning("resize-window after createWindow failed for \(result.windowID, privacy: .public) on server \(server, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return result
    }

    public func killWindow(server: String, windowID: String) async throws {
        if dryRun { return }
        let args = Self.killWindowCommand(server: server, windowID: windowID)
        try await runTmux(args)
    }

    /// Resize an existing tmux window. Used by the main-window resize
    /// broadcast and after `new-window`, so detached panes get a sensible
    /// cell size before any SwiftTerm client attaches. Each call is paired
    /// with `set-option ... window-size latest` to immediately leave manual
    /// size mode — otherwise tmux pins the window at the broadcast value
    /// and an attached SwiftTerm client (whose actual pane is usually
    /// smaller after accounting for tab bars, dividers, file panels, etc.)
    /// can't shrink it back, clipping the bottom rows.
    public func resizeWindow(server: String, windowID: String, cols: Int, rows: Int) async throws {
        let resizeArgs = Self.resizeWindowCommand(server: server, windowID: windowID, cols: cols, rows: rows)
        let unfreezeArgs = Self.setWindowSizeLatestCommand(server: server, windowID: windowID)
        if dryRun {
            dryRunRecorder?(resizeArgs)
            dryRunRecorder?(unfreezeArgs)
            return
        }
        try await runTmux(resizeArgs)
        // Best-effort: the resize itself succeeded, so don't fail the call
        // if the option flip stumbles. Detached panes still keep the
        // resize-window dimensions; only client-driven re-sizing depends on
        // window-size being non-manual.
        try? await runTmux(unfreezeArgs)
    }

    public func sendKeys(server: String, paneID: String, text: String) async throws {
        if dryRun { return }
        let args = Self.sendKeysCommand(server: server, paneID: paneID, text: text)
        try await runTmux(args)
    }

    public func sendKey(server: String, paneID: String, key: String) async throws {
        let args = Self.sendKeyCommand(server: server, paneID: paneID, key: key)
        if dryRun {
            dryRunRecorder?(args)
            return
        }
        try await runTmux(args)
    }

    public func capturePaneOutput(server: String, paneID: String) async throws -> String {
        if dryRun { return "" }
        let args = Self.capturePaneCommand(server: server, paneID: paneID)
        return try await runTmux(args)
    }

    /// Capture pane content with ANSI escape sequences preserved for snapshot display.
    public func capturePaneWithAnsi(server: String, paneID: String) async throws -> String {
        if dryRun { return "" }
        let args = Self.capturePaneWithAnsiCommand(server: server, paneID: paneID)
        return try await runTmux(args)
    }

    public func paneCurrentCommand(server: String, paneID: String) async throws -> String {
        if dryRun { return "zsh" }
        let args = Self.paneCurrentCommandQuery(server: server, paneID: paneID)
        return try await runTmux(args).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func panePID(server: String, paneID: String) async throws -> String {
        if dryRun { return "0" }
        let args = Self.panePIDQuery(server: server, paneID: paneID)
        return try await runTmux(args).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func sendCommand(server: String, paneID: String, command: String) async throws {
        let args = Self.sendCommandArgs(server: server, paneID: paneID, command: command)
        if dryRun {
            dryRunRecorder?(args)
            return
        }
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

    /// Check whether a tmux server is running by querying list-sessions.
    public func serverExists(server: String) async -> Bool {
        if dryRun { return true }
        do {
            let args = ["-L", server, "list-sessions"]
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
