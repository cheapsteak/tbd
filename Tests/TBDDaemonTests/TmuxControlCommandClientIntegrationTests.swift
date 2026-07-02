import Foundation
import Testing
@testable import TBDDaemonLib

/// Proves the correlation layer against a real `tmux -CC` server, driven the way
/// production does — through the supervisor's per-connection command client.
@Suite("TmuxControlCommandClient integration")
struct TmuxControlCommandClientIntegrationTests {

    /// Run a one-shot tmux command synchronously; returns true on exit code 0.
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

    /// Poll the supervisor until it has a command client for `server` (the
    /// `-CC` attach has settled), or time out.
    private func awaitClient(_ supervisor: TmuxControlSupervisor,
                             server: String) async throws -> TmuxControlCommandClient {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let client = await supervisor.command(server: server) { return client }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CommandClientTestError.clientNeverReady
    }

    @Test("round-trips a display-message command through the supervisor")
    func roundTrip() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else {
            return  // tmux missing or too old — skip
        }

        let server = "tbd-cmd-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }
        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24"]),
                     "failed to bootstrap test tmux server")

        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        let client = try await awaitClient(supervisor, server: server)

        let lines = try await client.send("display-message -p tbd-m1-marker")
        #expect(lines == ["tbd-m1-marker"])

        await supervisor.stopAll()
    }

    @Test("command list responses arrive in submission order")
    func commandListOrder() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else {
            return
        }

        let server = "tbd-cmd-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }
        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24"]),
                     "failed to bootstrap test tmux server")

        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        let client = try await awaitClient(supervisor, server: server)

        let box = OrderedResults()
        await client.sendList([
            TmuxCommand(text: "display-message -p one") { box.record($0) },
            TmuxCommand(text: "display-message -p two") { box.record($0) },
            TmuxCommand(text: "display-message -p three") { box.record($0) }
        ])

        try await box.waitForCount(3, timeout: .seconds(3))
        #expect(box.lines == [["one"], ["two"], ["three"]])

        await supervisor.stopAll()
    }

    @Test("a tolerated error completes without killing the connection")
    func toleratedErrorSurvives() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else {
            return
        }

        let server = "tbd-cmd-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }
        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24"]),
                     "failed to bootstrap test tmux server")

        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        let client = try await awaitClient(supervisor, server: server)

        // An unknown command yields a %error block; tolerateErrors keeps the
        // connection alive so the follow-up round-trips.
        await #expect(throws: TmuxCommandError.self) {
            _ = try await client.send("bogus-command-tbd", tolerateErrors: true)
        }

        let lines = try await client.send("display-message -p still-alive")
        #expect(lines == ["still-alive"])

        await supervisor.stopAll()
    }

    @Test("a connection re-established immediately after stopAll survives the old drain's cleanup")
    func reconnectSurvivesStaleDrainCleanup() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else {
            return
        }

        let server = "tbd-cmd-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }
        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24"]),
                     "failed to bootstrap test tmux server")

        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        _ = try await awaitClient(supervisor, server: server)

        // stopAll only kills the -CC client; the tmux server itself stays alive.
        // Re-establishing immediately installs a fresh connection whose entries
        // the OLD connection's drain task must not evict when its stream ends.
        await supervisor.stopAll()
        await supervisor.ensureConnection(serverName: server)

        // Let the superseded drain task run its end-of-stream cleanup.
        try await Task.sleep(for: .milliseconds(500))

        let client = try #require(await supervisor.command(server: server),
                                  "reconnected command client was evicted by the stale drain")
        let lines = try await client.send("display-message -p survived")
        #expect(lines == ["survived"])

        await supervisor.stopAll()
    }
}

private enum CommandClientTestError: Error { case clientNeverReady }

/// Thread-safe collector that preserves completion order for the command-list
/// assertion.
private final class OrderedResults: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [[String]] = []

    func record(_ result: Result<[String], TmuxCommandError>) {
        lock.lock(); defer { lock.unlock() }
        if case .success(let lines) = result { _lines.append(lines) }
    }
    var lines: [[String]] { lock.lock(); defer { lock.unlock() }; return _lines }
    private var count: Int { lock.lock(); defer { lock.unlock() }; return _lines.count }

    func waitForCount(_ target: Int, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if count >= target { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
