import Foundation
import Testing
import TBDShared
@testable import TBDDaemonLib

/// Proves the full daemon input path — sidecar frame → router → `send-keys -H`
/// through the FIFO correlator → live `tmux -CC` — against a real tmux server.
/// Mirrors `TmuxControlCommandClientIntegrationTests`' bootstrap exactly.
@Suite("ControlModeInputRouter integration")
struct ControlModeInputRouterIntegrationTests {

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

    private func awaitClient(_ supervisor: TmuxControlSupervisor,
                             server: String) async throws -> TmuxControlCommandClient {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let client = await supervisor.command(server: server) { return client }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw InputIntegrationError.clientNeverReady
    }

    /// Resolve the bootstrap session's single pane id over the control stream.
    private func firstPaneID(_ client: TmuxControlCommandClient) async throws -> String {
        let lines = try await client.send("list-panes -F '#{pane_id}'")
        guard let pane = lines.first, pane.hasPrefix("%") else {
            throw InputIntegrationError.noPane
        }
        return pane
    }

    /// Poll `capture-pane -p` (over the control stream) until a visible line
    /// contains `marker`, proving the typed bytes reached the pane in order.
    private func waitForCapture(_ client: TmuxControlCommandClient, pane: String,
                                contains marker: String,
                                timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let lines = try await client.send("capture-pane -p -t \(pane)", tolerateErrors: true)
            if lines.contains(where: { $0.contains(marker) }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw InputIntegrationError.markerNeverAppeared(marker)
    }

    /// Poll `#{pane_current_command}` until it satisfies `predicate`.
    private func waitForPaneCommand(_ client: TmuxControlCommandClient, pane: String,
                                    timeout: Duration = .seconds(5),
                                    _ predicate: @escaping (String) -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let lines = try await client.send(
                "list-panes -F '#{pane_id} #{pane_current_command}'", tolerateErrors: true)
            if let line = lines.first(where: { $0.hasPrefix(pane + " ") }) {
                let command = String(line.dropFirst(pane.count + 1))
                if predicate(command) { return }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw InputIntegrationError.paneCommandNeverSettled
    }

    private func makeRouter(_ supervisor: TmuxControlSupervisor, chunkSize: Int = 330)
        -> ControlModeInputRouter {
        ControlModeInputRouter(
            commandProvider: { server in await supervisor.command(server: server) },
            chunkSize: chunkSize)
    }

    @Test("typed keystrokes render in the pane (single chunk)")
    func singleChunkDelivery() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else { return }

        let server = "tbd-input-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }
        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24"]),
                     "failed to bootstrap test tmux server")

        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        let client = try await awaitClient(supervisor, server: server)
        let pane = try await firstPaneID(client)

        let router = makeRouter(supervisor)
        let worktreeID = UUID()
        router.register(worktreeID: worktreeID, paneID: pane, server: server)

        // Type the marker then Enter (0x0a). Terminal echo alone proves the
        // bytes were delivered by send-keys -H.
        var bytes = Data("TBDM22OK".utf8)
        bytes.append(0x0a)
        router.enqueue(header: SidecarInputHeader(worktreeID: worktreeID, paneID: pane), bytes: bytes)

        try await waitForCapture(client, pane: pane, contains: "TBDM22OK")

        router.shutdown()
        await supervisor.stopAll()
    }

    @Test("cross-chunk byte order is preserved through the FIFO (tiny chunks)")
    func crossChunkOrder() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else { return }

        let server = "tbd-input-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }
        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24"]),
                     "failed to bootstrap test tmux server")

        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        let client = try await awaitClient(supervisor, server: server)
        let pane = try await firstPaneID(client)

        // chunkSize 4 forces the ~16-char marker across ~4 send-keys commands;
        // a reordering bug would scramble the echoed string.
        let router = makeRouter(supervisor, chunkSize: 4)
        let worktreeID = UUID()
        router.register(worktreeID: worktreeID, paneID: pane, server: server)

        var bytes = Data("TBDM22MULTICHUNK".utf8)
        bytes.append(0x0a)
        router.enqueue(header: SidecarInputHeader(worktreeID: worktreeID, paneID: pane), bytes: bytes)

        try await waitForCapture(client, pane: pane, contains: "TBDM22MULTICHUNK")

        router.shutdown()
        await supervisor.stopAll()
    }

    @Test("a control byte (Ctrl-C) acts as an interrupt, not literal text")
    func controlByteInterrupts() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else { return }

        let server = "tbd-input-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }
        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24"]),
                     "failed to bootstrap test tmux server")

        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        let client = try await awaitClient(supervisor, server: server)
        let pane = try await firstPaneID(client)

        let router = makeRouter(supervisor)
        let worktreeID = UUID()
        router.register(worktreeID: worktreeID, paneID: pane, server: server)
        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: pane)

        // Run `cat` so a foreground process holds the pane.
        var startCat = Data("cat".utf8)
        startCat.append(0x0a)
        router.enqueue(header: header, bytes: startCat)
        try await waitForPaneCommand(client, pane: pane) { $0 == "cat" }

        // Type some text (no newline, sits in cat's line buffer) then Ctrl-C
        // (0x03). If 0x03 were literal, cat would keep running.
        var interrupt = Data("trailing".utf8)
        interrupt.append(0x03)
        router.enqueue(header: header, bytes: interrupt)
        try await waitForPaneCommand(client, pane: pane) { $0 != "cat" }

        router.shutdown()
        await supervisor.stopAll()
    }
}

private enum InputIntegrationError: Error {
    case clientNeverReady
    case noPane
    case markerNeverAppeared(String)
    case paneCommandNeverSettled
}
