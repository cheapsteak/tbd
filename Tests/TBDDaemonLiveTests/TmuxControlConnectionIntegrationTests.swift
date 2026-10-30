import Foundation
import TestSupport
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

        // Wait for the control client to attach — its first notification, the
        // attach greeting, says it is talking to the server — then drive
        // observable events and wait for each to arrive.
        await awaitEvents(in: collected, "any notification after the attach") { !$0.isEmpty }
        tmux(["-L", server, "new-window"])
        tmux(["-L", server, "send-keys", "echo tbd-marker", "Enter"])
        await awaitEvents(in: collected, "a %window-add and an %output") { events in
            events.contains(where: isWindowAdd) && events.contains(where: isOutput)
        }

        connection.sendCommand("list-windows")
        await awaitEvents(in: collected, "the reply block to list-windows") { events in
            events.contains(where: isClientReply)
        }

        connection.stop()
        collector.cancel()

        let events = await collected.events
        #expect(events.contains(where: isWindowAdd), "expected a %window-add event")
        #expect(events.contains(where: isOutput), "expected at least one %output event")
        // The client's own reply, not the attach greeting: that block is a
        // `%begin`/`%end` too, but tmux flags it as not this client's command.
        #expect(
            events.contains(where: isClientReply),
            "expected a %begin/%end command block from sendCommand")
    }
}

private func isWindowAdd(_ event: TmuxControlEvent) -> Bool {
    if case .windowAdd = event { return true } else { return false }
}

private func isOutput(_ event: TmuxControlEvent) -> Bool {
    if case .output = event { return true } else { return false }
}

private func isClientReply(_ event: TmuxControlEvent) -> Bool {
    if case .commandSucceeded(_, let fromClient, _) = event { return fromClient } else { return false }
}

/// Minimal actor inbox so the collector task and the test can share events
/// without a data race.
private actor EventBox {
    private(set) var events: [TmuxControlEvent] = []
    func append(_ event: TmuxControlEvent) { events.append(event) }
}

/// Waits until the collected events satisfy `predicate`, and reports what was
/// collected if they never do. A hang guard rather than pacing: a live tmux
/// server answers in milliseconds, and the wait ends on its first satisfying
/// probe.
private func awaitEvents(
    in box: EventBox,
    _ what: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    until predicate: ([TmuxControlEvent]) -> Bool
) async {
    let outcome = await pollUntilTrue(timeout: .seconds(10), pollInterval: .milliseconds(20)) {
        predicate(await box.events)
    }
    if outcome == .timedOut {
        Issue.record(
            EventsNeverArrived(what: what, observed: await box.events),
            sourceLocation: sourceLocation)
    }
}

/// A bounded wait for tmux notifications expired. An `Error` so its text lands
/// on the primary failure line a CI summary keeps.
private struct EventsNeverArrived: Error, CustomStringConvertible {
    let what: String
    let observed: [TmuxControlEvent]

    var description: String {
        "tmux -CC never delivered \(what) within 10 s; collected \(observed.count) events: \(observed)"
    }
}
