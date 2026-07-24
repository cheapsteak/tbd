import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("TmuxControlConnection teardown")
struct TmuxControlConnectionTeardownTests {

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

    @Test("stop() completes within 1s under normal termination")
    func stopCompletesQuickly() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else { return }
        let server = "tbd-teardown-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }
        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24"]))

        let connection = TmuxControlConnection(serverName: server)
        try connection.start()
        try await Task.sleep(for: .milliseconds(300))

        let started = Date()
        connection.stop()
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 1.0, "stop() took \(elapsed)s")
    }

    @Test("trailing %output events are delivered before the stream finishes")
    func trailingOutputPreserved() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else { return }
        let server = "tbd-trailing-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }
        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24"]))

        let connection = TmuxControlConnection(serverName: server)
        try connection.start()

        let box = TeardownEventBox()
        let collector = Task {
            for await event in connection.events { await box.append(event) }
            await box.markFinished()
        }
        try await Task.sleep(for: .milliseconds(400))
        tmux(["-L", server, "send-keys", "echo trailing-marker-\(UUID().uuidString.prefix(6))", "Enter"])
        try await Task.sleep(for: .milliseconds(300))
        connection.stop()

        // Give the collector up to 1 s to observe the finished stream.
        for _ in 0..<20 {
            if await box.finished { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        collector.cancel()

        let outputCount = await box.outputEventCount
        #expect(await box.finished, "collector should observe stream finish")
        #expect(outputCount > 0, "at least one %output event should arrive")
    }
}

private actor TeardownEventBox {
    private(set) var outputEventCount = 0
    private(set) var finished = false
    func append(_ event: TmuxControlEvent) {
        if case .output = event { outputEventCount += 1 }
    }
    func markFinished() { finished = true }
}
