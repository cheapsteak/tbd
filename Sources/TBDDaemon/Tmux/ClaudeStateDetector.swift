import Foundation

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

    public init(tmux: TmuxManager) { self.tmux = tmux }

    public func captureSessionID(server: String, paneID: String) async -> String? {
        do {
            let pidStr = try await tmux.panePID(server: server, paneID: paneID)
            guard let panePID = Int(pidStr) else { return nil }

            // With `zsh -ic "claude ..."`, zsh may exec into Claude directly,
            // so pane_pid IS the Claude process (not a shell parent).
            // Try the pane PID's session file first.
            if let id = readSessionID(forPID: panePID) { return id }

            // Fallback: pane_pid is a shell, Claude is a child process.
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-P", String(panePID), "-x", "claude"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()

            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let pids = output.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").compactMap { Int($0) }
            guard pids.count == 1, let claudePID = pids.first else { return nil }

            return readSessionID(forPID: claudePID)
        } catch { return nil }
    }

    /// Read a Claude session file for a given PID. Returns nil if file doesn't exist or is invalid.
    private func readSessionID(forPID pid: Int) -> String? {
        let sessionPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions/\(pid).json")
        guard let json = try? String(contentsOf: sessionPath, encoding: .utf8) else { return nil }
        return Self.parseSessionID(from: json)
    }
}
