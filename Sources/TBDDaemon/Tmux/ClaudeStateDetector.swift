import Foundation
import TBDShared

public struct ClaudeStateDetector: Sendable {
    // MARK: - Pattern Constants
    nonisolated(unsafe) static let claudeProcessRegex = try! Regex(#"^\d+\.\d+\.\d+"#)

    // MARK: - Pure Static Methods

    public static func isClaudeProcess(_ command: String) -> Bool {
        command.firstMatch(of: claudeProcessRegex) != nil
    }

    public static func parseSessionID(from json: String) -> String? {
        struct SessionFile: Decodable { let sessionId: String }
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(SessionFile.self, from: data) else {
            return nil
        }
        return parsed.sessionId
    }

    // MARK: - Instance Methods (require TmuxManager)
    private let tmux: TmuxManager
    private let environment: [String: String]

    /// - Parameter environment: the environment the host Claude store is
    ///   resolved from, defaulted so no call site changes. Present so a test
    ///   can assert BOTH branches of that resolution with an explicit
    ///   dictionary instead of mutating the process-global variable, which
    ///   would hand every concurrently running suite the real `~/.claude`.
    public init(tmux: TmuxManager, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.tmux = tmux
        self.environment = environment
    }

    /// Where Claude writes the session file for `pid`, inside the host store.
    ///
    /// Resolved through `TBDConstants.claudeHostHome(environment:)` — the
    /// single resolution point for `TBD_CLAUDE_HOST_HOME`, package-wide — and
    /// not hand-built from the home directory. Production behaviour is
    /// unchanged: with no override set, that resolver returns
    /// `homeDirectoryForCurrentUser/.claude`, which is the path this used to
    /// assemble itself. What changes is that the override now reaches here too,
    /// so the read lands inside `scripts/test.sh`'s scratch store rather than
    /// failing on the mode-000 decoy the fence puts in its place.
    ///
    /// This reads the **host** store even for a session spawned under a TBD
    /// profile, whose `CLAUDE_CONFIG_DIR` is `~/tbd/profiles/<id>/claude`. That
    /// used to miss for every profile terminal, so session-ID recapture after a
    /// `--fork-session` resume (`HibernationCoordinator`,
    /// `SessionRecaptureScheduler`) silently found nothing there and fell back.
    /// It resolves now only because `ClaudeProfileConfigDirManager` mirrors the
    /// `sessions/` slot: each profile's `sessions/` is a symlink to the host
    /// one, so a profile session's row lands at this path. Removing that mirror
    /// slot would quietly re-break recapture — `ClaudeStateDetectorTests` pins
    /// the coupling.
    ///
    /// Internal rather than private so `ClaudeStateDetectorTests` can assert
    /// the path without a real session file to read.
    func sessionFilePath(forPID pid: Int) -> URL {
        TBDConstants.claudeHostHome(environment: environment)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(pid).json")
    }

    /// The session id of the Claude process a recapture target names, on either
    /// transport.
    public func captureSessionID(target: SessionRecaptureTarget) async -> String? {
        switch target {
        case .tmuxPane(let server, let paneID):
            return await captureSessionID(server: server, paneID: paneID)
        case .holderChild(let pid):
            return await captureSessionID(rootPID: Int(pid))
        }
    }

    public func captureSessionID(server: String, paneID: String) async -> String? {
        guard let pidStr = try? await tmux.panePID(server: server, paneID: paneID),
              let panePID = Int(pidStr) else { return nil }
        return await captureSessionID(rootPID: panePID)
    }

    /// Resolve a session id from the root pid of a session's own process tree.
    ///
    /// The same ladder serves both transports because the pid means the same
    /// shape of thing on each. On tmux the root is `#{pane_pid}`: with
    /// `zsh -i -l -c "claude …"` (see `TmuxManager.shellFlags(forShell:)`) zsh
    /// may exec into Claude directly, so that pid IS the Claude process, and
    /// otherwise it is the shell that started one. On the holder the root is
    /// the job the holder forked — the `zsh -c` shell composed by
    /// `holderLaunch`, or Claude itself once that shell execs into it — which
    /// is the identical pair of cases. So: read the root's session file first,
    /// and fall back to the single `claude` child beneath it.
    func captureSessionID(rootPID: Int) async -> String? {
        if let id = readSessionID(forPID: rootPID) { return id }

        // Fallback: the root is a shell and Claude is a child process.
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(rootPID), "-x", "claude"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch { return nil }
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let pids = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").compactMap { Int($0) }
        guard pids.count == 1, let claudePID = pids.first else { return nil }

        return readSessionID(forPID: claudePID)
    }

    /// Read a Claude session file for a given PID. Returns nil if file doesn't exist or is invalid.
    ///
    /// Internal rather than private so `ClaudeStateDetectorTests` can pin the
    /// profile-mirror coupling described on `sessionFilePath(forPID:)` — that a
    /// profile session's row really is readable through the host store.
    func readSessionID(forPID pid: Int) -> String? {
        let sessionPath = sessionFilePath(forPID: pid)
        guard let json = try? String(contentsOf: sessionPath, encoding: .utf8) else { return nil }
        return Self.parseSessionID(from: json)
    }
}
