import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("TmuxControlConnection integration")
struct TmuxControlConnectionIntegrationTests {

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

    @Test("observes window and output events from a live tmux server")
    func observesLiveEvents() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else {
            return  // tmux missing or too old — skip
        }

        let server = "tbd-test-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }

        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24"]),
                     "failed to bootstrap test tmux server")

        let connection = TmuxControlConnection(serverName: server)
        try connection.start()
        defer { connection.stop() }

        let collected = EventBox()
        let collector = Task {
            for await event in connection.events { await collected.append(event) }
        }

        // Let the control client attach, then drive observable events.
        try await Task.sleep(for: .milliseconds(400))
        tmux(["-L", server, "new-window"])
        tmux(["-L", server, "send-keys", "echo tbd-marker", "Enter"])
        try await Task.sleep(for: .milliseconds(800))

        connection.sendCommand("list-windows")
        try await Task.sleep(for: .milliseconds(400))

        connection.stop()
        collector.cancel()

        let events = await collected.events
        #expect(events.contains { if case .windowAdd = $0 { return true } else { return false } },
                "expected a %window-add event")
        #expect(events.contains { if case .output = $0 { return true } else { return false } },
                "expected at least one %output event")
        #expect(events.contains { if case .commandSucceeded = $0 { return true } else { return false } },
                "expected a %begin/%end command block from sendCommand")
    }
}

/// Minimal actor inbox so the collector task and the test can share events
/// without a data race.
private actor EventBox {
    private(set) var events: [TmuxControlEvent] = []
    func append(_ event: TmuxControlEvent) { events.append(event) }
}
