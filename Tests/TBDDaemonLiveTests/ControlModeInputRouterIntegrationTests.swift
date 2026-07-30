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
                                timeout: Duration = .seconds(15)) async throws {
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
                                    timeout: Duration = .seconds(15),
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

    /// Poll `path` until its bytes equal `expected`, or time out. On timeout the
    /// thrown error tells the TRUTH about why: an incomplete-but-correct prefix
    /// (the pane hadn't finished writing → a load/timeout problem) vs a byte
    /// that diverges (a real FIFO ordering bug). The old error re-read the file
    /// AFTER the deadline and reported `expected.count` vs that count — which
    /// were equal when the write completed in the final slice, hiding both.
    private func awaitFileBytes(path: String, expected: Data, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        var lastObserved = Data()
        while ContinuousClock.now < deadline {
            if let data = FileManager.default.contents(atPath: path) {
                if data == expected { return }
                lastObserved = data
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Final read: a completion that landed in the last sleep slice must not
        // be misreported as a mismatch.
        if let data = FileManager.default.contents(atPath: path) {
            if data == expected { return }
            lastObserved = data
        }
        throw InputIntegrationError.fileBytesUnmatched(
            expected: expected.count,
            observed: lastObserved.count,
            correctPrefix: expected.starts(with: lastObserved))
    }

    /// Printable-ASCII payload of exactly `byteCount` bytes.
    private func makePayload(byteCount: Int) -> Data {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789".utf8)
        var bytes = [UInt8]()
        bytes.reserveCapacity(byteCount)
        for i in 0..<byteCount { bytes.append(alphabet[i % alphabet.count]) }
        return Data(bytes)
    }

    /// THE MONEY TEST for the M2 paste ruling: a bulk paste followed IMMEDIATELY
    /// by a keystroke must arrive at the pane as paste-payload-THEN-keystroke,
    /// proving the keystroke is FIFO-behind the paste through the real `-CC`
    /// stream (both ride the router's single ordered consumer → same FIFO).
    ///
    /// The pane captures its raw stdin with `stty raw -echo; head -c N > file`
    /// (raw mode: no ~1 KB cooked-input limit, no echo, `head` exits after
    /// exactly N bytes). Bracketed paste is OFF (bare `head`), so `paste-buffer
    /// -p` emits the payload bare — the file must equal payload + tag verbatim.
    @Test("a keystroke enqueued right after a paste lands AFTER the paste payload (FIFO)")
    func keystrokeFollowsPasteInOrder() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else { return }

        let server = "tbd-input-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }

        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-paste-order-\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let payload = makePayload(byteCount: 6 * 1024)
        let tag = Data("ZZTAIL".utf8)
        let total = payload.count + tag.count

        // rc-free /bin/sh bootstrap whose pane command IS the raw capture, so the
        // pane reaches `head` in milliseconds (de-flake convention).
        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main", "-x", "200", "-y", "50",
                           "/bin/sh", "-c", "stty raw -echo; exec head -c \(total) > \(outPath)"]),
                     "failed to bootstrap raw-capture tmux session")

        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        let client = try await awaitClient(supervisor, server: server)
        let pane = try await firstPaneID(client)
        try await waitForPaneCommand(client, pane: pane) { $0 == "head" }

        let router = makeRouter(supervisor)
        let worktreeID = UUID()
        router.register(worktreeID: worktreeID, paneID: pane, server: server)
        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: pane)

        // Paste, then IMMEDIATELY the keystroke — no await between: the ordering
        // guarantee must come from the FIFO, not from the test serializing them.
        router.enqueuePaste(header: header, bytes: payload)
        router.enqueue(header: header, bytes: tag)

        // 30 s (not 15): this real-tmux integration test's whole pipeline —
        // bootstrap, -CC connect, pane-command settle, then the paste+keystroke
        // round-trip — stretches well past 15 s under parallel-suite load (a CI
        // run took 45.8 s total). A generous deadline for a genuinely slow I/O
        // path, not a masked ordering bug: the error above distinguishes the two.
        try await awaitFileBytes(path: outPath, expected: payload + tag, timeout: .seconds(30))

        router.shutdown()
        await supervisor.stopAll()
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
        // Pane command is a bare POSIX `/bin/sh` (no rc sourcing) rather than the
        // user's interactive zsh: under parallel-suite load, zsh startup alone
        // could blow the pane-command deadline before `cat` ever ran (the old
        // flake). /bin/sh starts in a few ms and still runs `cat` / honors Ctrl-C.
        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24", "/bin/sh"]),
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

    /// Spec (f): input for a dying/nonexistent pane must NOT tear down the
    /// repo's shared `-CC` connection. Enqueue input for a FAKE pane id (its
    /// `send-keys -H -t %999` makes tmux emit a `%error`); because every
    /// keystroke command is issued with `tolerateErrors: true`, the connection
    /// must survive. Prove it by then routing REAL input to the live bootstrap
    /// pane through the SAME connection and watching it render.
    @Test("input to a nonexistent pane errors but does not tear down the -CC connection")
    func deadPaneInputDoesNotKillConnection() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else { return }

        let server = "tbd-input-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }
        // rc-free /bin/sh bootstrap (de-flake convention): starts in a few ms
        // under parallel-suite load, no zsh rc sourcing to race a deadline.
        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main",
                           "-x", "80", "-y", "24", "/bin/sh"]),
                     "failed to bootstrap test tmux server")

        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        let client = try await awaitClient(supervisor, server: server)
        let realPane = try await firstPaneID(client)

        let router = makeRouter(supervisor)
        let worktreeID = UUID()
        // Register BOTH a fake pane and the real one on this one server.
        let fakePane = "%999"
        router.register(worktreeID: worktreeID, paneID: fakePane, server: server)
        router.register(worktreeID: worktreeID, paneID: realPane, server: server)

        // Bad input first: send-keys -H -t %999 → tmux %error (tolerated).
        var bad = Data("DEADPANE".utf8)
        bad.append(0x0a)
        router.enqueue(header: SidecarInputHeader(worktreeID: worktreeID, paneID: fakePane), bytes: bad)

        // Good input to the real pane over the SAME connection. If the %error
        // had torn the -CC connection down, this marker would never render.
        var good = Data("STILLALIVE".utf8)
        good.append(0x0a)
        router.enqueue(header: SidecarInputHeader(worktreeID: worktreeID, paneID: realPane), bytes: good)

        try await waitForCapture(client, pane: realPane, contains: "STILLALIVE")

        router.shutdown()
        await supervisor.stopAll()
    }
}

private enum InputIntegrationError: Error {
    case clientNeverReady
    case noPane
    case markerNeverAppeared(String)
    case paneCommandNeverSettled
    case fileBytesUnmatched(expected: Int, observed: Int, correctPrefix: Bool)
}
