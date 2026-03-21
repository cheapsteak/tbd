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

    public static func serverName(forRepoID id: UUID) -> String {
        let hex = id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "tbd-\(hex)"
    }

    public static func newServerCommand(server: String, session: String, cwd: String) -> String {
        "tmux -L \(server) new-session -d -s \(session) -c \(cwd)"
    }

    public static func newWindowCommand(server: String, session: String, cwd: String, shellCommand: String) -> String {
        "tmux -L \(server) new-window -t \(session) -c \(cwd) -PF '#{window_id} #{pane_id}' \(shellCommand)"
    }

    public static func killWindowCommand(server: String, windowID: String) -> String {
        "tmux -L \(server) kill-window -t \(windowID)"
    }

    public static func sendKeysCommand(server: String, paneID: String, text: String) -> String {
        "tmux -L \(server) send-keys -l -t \(paneID) \(text)"
    }

    public static func listWindowsCommand(server: String, session: String) -> String {
        "tmux -L \(server) list-windows -t \(session) -F '#{window_id} #{pane_id}'"
    }

    // MARK: - Instance Execution Methods

    public func ensureServer(server: String, session: String, cwd: String) async throws {
        if dryRun { return }
        let cmd = Self.newServerCommand(server: server, session: session, cwd: cwd)
        try await runShell(cmd)
    }

    public func createWindow(server: String, session: String, cwd: String, shellCommand: String) async throws -> (windowID: String, paneID: String) {
        if dryRun {
            let n = counter.next()
            return (windowID: "@mock-\(n)", paneID: "%mock-\(n)")
        }
        let cmd = Self.newWindowCommand(server: server, session: session, cwd: cwd, shellCommand: shellCommand)
        let output = try await runShell(cmd)
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 2 else {
            throw TmuxError.unexpectedOutput(output)
        }
        return (windowID: String(parts[0]), paneID: String(parts[1]))
    }

    public func killWindow(server: String, windowID: String) async throws {
        if dryRun { return }
        let cmd = Self.killWindowCommand(server: server, windowID: windowID)
        try await runShell(cmd)
    }

    public func sendKeys(server: String, paneID: String, text: String) async throws {
        if dryRun { return }
        let cmd = Self.sendKeysCommand(server: server, paneID: paneID, text: text)
        try await runShell(cmd)
    }

    public func listWindows(server: String, session: String) async throws -> [(windowID: String, paneID: String)] {
        if dryRun { return [] }
        let cmd = Self.listWindowsCommand(server: server, session: session)
        let output = try await runShell(cmd)
        return output
            .split(separator: "\n")
            .compactMap { line -> (windowID: String, paneID: String)? in
                let parts = line.split(separator: " ")
                guard parts.count == 2 else { return nil }
                return (windowID: String(parts[0]), paneID: String(parts[1]))
            }
    }

    // MARK: - Private

    @discardableResult
    private func runShell(_ command: String) async throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw TmuxError.commandFailed(command: command, status: process.terminationStatus, output: output)
        }
        return output
    }
}

public enum TmuxError: Error, Sendable {
    case commandFailed(command: String, status: Int32, output: String)
    case unexpectedOutput(String)
}
