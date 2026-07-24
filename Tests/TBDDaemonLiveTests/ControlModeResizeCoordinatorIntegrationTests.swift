import Foundation
import Testing
@testable import TBDDaemonLib

/// Proves the resize path — `resize-window` + echo fence through the FIFO
/// correlator — against a real `tmux -CC` server (M3.1). Mirrors
/// `ControlModeInputRouterIntegrationTests`' rc-free bootstrap + 15s deadlines.
@Suite("ControlModeResizeCoordinator integration")
struct ControlModeResizeCoordinatorIntegrationTests {

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
        throw ResizeIntegrationError.clientNeverReady
    }

    /// Resolve the bootstrap session's single window id over the control stream.
    private func firstWindowID(_ client: TmuxControlCommandClient) async throws -> String {
        let lines = try await client.send("list-windows -F '#{window_id}'")
        guard let window = lines.first, window.hasPrefix("@") else {
            throw ResizeIntegrationError.noWindow
        }
        return window
    }

    /// Poll `list-windows` until the target window reports `WxH`.
    private func waitForWindowSize(_ client: TmuxControlCommandClient, window: String,
                                   equals expected: String,
                                   timeout: Duration = .seconds(15)) async throws {
        let deadline = ContinuousClock.now + timeout
        var last = "?"
        while ContinuousClock.now < deadline {
            let lines = try await client.send(
                "list-windows -F '#{window_id} #{window_width}x#{window_height}'",
                tolerateErrors: true)
            if let line = lines.first(where: { $0.hasPrefix(window + " ") }) {
                last = String(line.dropFirst(window.count + 1))
                if last == expected { return }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ResizeIntegrationError.windowSizeNeverSettled(expected: expected, last: last)
    }

    private func makeCoordinator(_ supervisor: TmuxControlSupervisor)
        -> ControlModeResizeCoordinator {
        ControlModeResizeCoordinator(
            commandProvider: { server in await supervisor.command(server: server) })
    }

    @Test("resize-window through the coordinator resizes a live window")
    func resizeRoundTrip() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else { return }

        let server = "tbd-resize-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }
        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main",
                           "-x", "200", "-y", "50", "/bin/sh"]),
                     "failed to bootstrap test tmux server")

        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        let client = try await awaitClient(supervisor, server: server)
        let window = try await firstWindowID(client)

        // The daemon sets this per-window at attach; do the same so
        // resize-window is authoritative rather than clamped to a client size.
        _ = try await client.send(
            "set-window-option -t \(window) window-size manual", tolerateErrors: true)

        let coordinator = makeCoordinator(supervisor)
        await coordinator.resize(server: server, windowID: window, cols: 100, rows: 30)

        try await waitForWindowSize(client, window: window, equals: "100x30")

        await supervisor.stopAll()
    }

    @Test("two rapid resizes converge at the last requested size (no fighting)")
    func echoStormConverges() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else { return }

        let server = "tbd-resize-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }
        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main",
                           "-x", "200", "-y", "50", "/bin/sh"]),
                     "failed to bootstrap test tmux server")

        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        let client = try await awaitClient(supervisor, server: server)
        let window = try await firstWindowID(client)
        _ = try await client.send(
            "set-window-option -t \(window) window-size manual", tolerateErrors: true)

        let coordinator = makeCoordinator(supervisor)
        // Rapid-fire, no await between: the FIFO orders them; last one wins.
        await coordinator.resize(server: server, windowID: window, cols: 120, rows: 40)
        await coordinator.resize(server: server, windowID: window, cols: 100, rows: 30)

        try await waitForWindowSize(client, window: window, equals: "100x30")

        await supervisor.stopAll()
    }

    @Test("the attach handler's window-size command makes the window manual")
    func attachSetsWindowSizeManual() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else { return }

        let server = "tbd-resize-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }
        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main",
                           "-x", "200", "-y", "50", "/bin/sh"]),
                     "failed to bootstrap test tmux server")

        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        let client = try await awaitClient(supervisor, server: server)
        let window = try await firstWindowID(client)

        // Exactly the command `handleAttachRequest` issues at attach time.
        _ = try await client.send(
            "set-window-option -t \(window) window-size manual", tolerateErrors: true)

        let shown = try await client.send("show-options -w -t \(window) window-size")
        // Format is "window-size manual".
        #expect(shown.contains(where: { $0.contains("window-size manual") }))

        await supervisor.stopAll()
    }
}

private enum ResizeIntegrationError: Error {
    case clientNeverReady
    case noWindow
    case windowSizeNeverSettled(expected: String, last: String)
}
