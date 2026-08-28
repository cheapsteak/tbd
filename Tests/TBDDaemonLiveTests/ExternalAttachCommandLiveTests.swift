import Darwin
import Foundation
import Testing
@testable import TBDShared

/// Tier 3 — the external-attach command driven against a real tmux server,
/// with real PTY-backed clients.
///
/// `ExternalAttachCommandTests` asserts the composed *string*. This suite
/// asserts what that string does when a tmux server on the other end executes
/// it, which is the only way to settle the two facts
/// `docs/specs/2026-08-27-external-tmux-attach-shortcut-design.md` left open:
///
///  - **The create-to-attach gap** ("Reclamation" → "Known risk, to be settled
///    by test"). The script creates the session detached, turns
///    `destroy-unattached on`, and only then attaches. The spec calls the
///    window in between a race. Measured here it is not a race at all — see
///    `destroyUnattachedReapsBeforeAnyClientCanArrive`.
///  - **The geometry rule** ("Measurement guidance"). The advice to size the
///    external window exactly like TBD's panel rests entirely on how tmux
///    treats an `ignore-size` client, so that behavior is pinned rather than
///    assumed: a future tmux that changed it would silently invalidate the
///    guidance and nothing else in the tree would notice.
///
/// Live-tmux discipline, per `Tests/CLAUDE.md`:
///
///  - **rc-free bootstrap.** The server starts with `-f /dev/null`, so the
///    developer's `~/.tmux.conf` cannot change a default this suite asserts.
///    Config is server-side and loaded once at server start, so the clients
///    spawned later inherit that same rc-free server.
///  - **Every wait is bounded**, and waits on a *positive* signal (a client
///    appears, a size converges, the shell exits) rather than sleeping a
///    guessed interval. A hung live test holds the shared build lock against
///    every other worktree on this machine.
///  - **The socket is fenced and removed.** tmux never unlinks its socket when
///    a server exits — it only clears a stale one lazily when a new server
///    claims that exact path — so ~7,100 dead sockets once accumulated here in
///    nine days. Each test mints its own directory directly under `/tmp`
///    (short, because a unix socket path is capped at ~104 bytes and a deeper
///    root fails as "File name too long"), kills its server, removes the
///    directory, and *asserts the directory is gone*.
@Suite("External attach command (live tmux)", .serialized, .timeLimit(.minutes(3)))
struct ExternalAttachCommandLiveTests {

    // MARK: - 1. The composed script, against a real server

    /// The spec's requirement: running the composed script leaves a client
    /// attached to the terminal's `tbd-ext-*` session, and that session holds
    /// the terminal's window and nothing else.
    ///
    /// **This does not hold today, and the failure is deterministic** — hence
    /// `withKnownIssue`. `destroy-unattached on` is set on a session that is
    /// still detached, tmux collects it on the same server tick, and the attach
    /// on the next line dies with `can't find session`. The attempt is repeated
    /// because the spec expected a *race* and a single miss would have been
    /// ambiguous; it is not a race, it is every time.
    ///
    /// The fix — moving the option onto the attach command
    /// (`attach … \; set-option … destroy-unattached on`) — changes the
    /// committed composer, so it belongs to a follow-up rather than to this
    /// test. When it lands, the known issue stops being recorded, this test
    /// goes red saying so, and the `withKnownIssue` wrapper is what gets
    /// deleted. Nothing else here changes.
    ///
    /// A green control for the harness itself lives in
    /// `ignoreSizeIsDisregardedWhileAnotherClientContributesASize`: it attaches
    /// two real PTY clients through the same code path, so "no client ever
    /// appeared" here cannot be a broken harness reading as a product bug.
    @Test("the composed script attaches a client to the terminal's own window")
    func composedScriptAttachesToTheTerminalsWindow() async throws {
        let server = try TmuxServer.start()
        defer { server.tearDown() }
        let window = try server.createWindowInMain()

        struct Attempt {
            let attached: Bool
            /// Every window id the session held, one per line.
            let windows: String
            /// What the script printed before it gave up, for the diagnostic.
            let output: String
        }

        let attemptCount = 20
        var attempts: [Attempt] = []
        for _ in 0..<attemptCount {
            let terminalID = UUID()
            let session = ExternalAttachCommand.sessionName(for: terminalID)
            let script = ExternalAttachCommand.script(
                socketPath: server.socketPath,
                sessionName: session,
                windowID: window)

            let client = try PTYProcess(
                executable: "/bin/sh",
                arguments: ["-c", script],
                size: Size(columns: 100, rows: 30))
            let attached = await server.awaitClient(
                onSession: session, orExitOf: client, within: .seconds(5))
            attempts.append(Attempt(
                attached: attached,
                windows: server.windowIDs(inSession: session),
                output: client.capturedOutput))
            client.terminate()
        }

        let attachedCount = attempts.filter(\.attached).count
        withKnownIssue("""
            The create-to-attach gap the spec flagged as a risk is a certainty: \
            `destroy-unattached on` is set while the session is still detached, \
            so tmux reaps it before the attach on the next line runs. Remove \
            this wrapper when the composer sets the option on the attach itself.
            """) {
            #expect(
                attachedCount == attemptCount,
                """
                only \(attachedCount) of \(attemptCount) runs of the composed \
                script left a client attached. First script output: \
                \(attempts.first?.output ?? "<none>")
                """)
            #expect(
                attempts.allSatisfy { $0.windows == window },
                """
                every session should hold exactly the linked window \(window); \
                observed \(Set(attempts.map(\.windows)))
                """)
        }
    }

    // MARK: - 2. Why: the gap is not a race

    /// The mechanism behind the known issue above, isolated from the composer
    /// so it stays true and green whatever the composer does next.
    ///
    /// tmux collects an unattached session with `destroy-unattached on` on a
    /// server tick, and setting the option is itself enough to schedule that
    /// tick — no client ever has to come and go. So a session created detached
    /// with the option already on cannot survive long enough for a separate
    /// `tmux attach` process to reach it, and the "in principle" of the spec's
    /// risk paragraph is in practice.
    ///
    /// This deliberately builds the session with tmux directly rather than
    /// through `ExternalAttachCommand.script`: the point is to pin one tmux
    /// behavior, not to re-test the script the previous test drives.
    @Test("destroy-unattached reaps a detached session before any client can arrive")
    func destroyUnattachedReapsBeforeAnyClientCanArrive() async throws {
        let server = try TmuxServer.start()
        defer { server.tearDown() }
        let window = try server.createWindowInMain()

        let session = ExternalAttachCommand.sessionName(for: UUID())
        server.tmux(["new-session", "-d", "-s", session, "-c", "/tmp"])
        server.tmux(["link-window", "-s", window, "-t", session + ":"])
        server.tmux(["kill-window", "-t", session + ":0"])

        // The gap the script leaves open starts here: the session exists, holds
        // the window, and has no client.
        #expect(server.hasSession(session), "the session must exist before the option is set")
        #expect(server.clientTTYs(onSession: session).isEmpty, "nothing has attached yet")

        server.tmux(["set-option", "-t", session, "destroy-unattached", "on"])

        let gone = await server.awaitSessionGone(session, within: .seconds(5))
        #expect(gone, """
            tmux kept an unattached `destroy-unattached on` session alive — if this \
            ever goes green, the composer's create-then-attach order is safe and the \
            known issue on the previous test can be retired.
            """)
        // Discriminates a reap from a dead server: `main` never carries the
        // option, so it must be untouched.
        #expect(server.hasSession("main"), """
            the sibling session without the option must survive, or this measured \
            a server that died rather than a session that was reaped
            """)
    }

    // MARK: - 3. The geometry rule the measurement guidance rests on

    /// The rule, stated as a rule: **an `ignore-size` client's dimensions are
    /// disregarded while another client is contributing a size, and adopted
    /// once it is the only client left.**
    ///
    /// That is the whole load-bearing premise of the spec's "Measurement
    /// guidance": it is why attaching the external client cannot reflow TBD's
    /// panel mid-measurement (condition B), and equally why "external alone"
    /// (condition C) runs at a *different* geometry unless the external window
    /// was sized to match exactly.
    ///
    /// The two client sizes below are the ones the spec measured by hand, but
    /// nothing is asserted against those numbers directly. The status-line
    /// allowance is *derived* from the first observation — tmux reserves rows
    /// for the status line, so a window is shorter than its client — and both
    /// halves of the rule are then stated in terms of the client sizes and that
    /// derived allowance. A tmux that changed the reservation still passes; a
    /// tmux that changed the `ignore-size` rule fails, which is the point.
    @Test("ignore-size is disregarded while another client contributes a size, and adopted when alone")
    func ignoreSizeIsDisregardedWhileAnotherClientContributesASize() async throws {
        let server = try TmuxServer.start()
        defer { server.tearDown() }
        let window = try server.createWindowInMain()

        // The premise the rule sits on. TBD sets this nowhere, so the guidance
        // depends on tmux's default staying `latest`.
        #expect(
            server.globalOption("window-size") == "latest",
            "the sizing rule below only describes `window-size latest`")

        // One window displayed through two single-window sessions — TBD's own
        // panel recipe on one side, the external attach's on the other. Sizing
        // is a property of the clients showing the window, not of the sessions,
        // and this is the arrangement the guidance describes.
        try server.makeLinkedSession(named: "tbd-view-geometry", window: window)
        try server.makeLinkedSession(named: ExternalAttachCommand.sessionPrefix + "geometry", window: window)

        let normalClientSize = Size(columns: 100, rows: 30)
        let ignoringClientSize = Size(columns: 180, rows: 45)
        #expect(
            normalClientSize.columns != ignoringClientSize.columns
                && normalClientSize.rows != ignoringClientSize.rows,
            "the two clients must differ in both axes or neither half of the rule discriminates")

        // --- The normal client alone: it sets the window size, and the gap
        // between its height and the window's height is the status-line
        // allowance every expectation below is expressed in terms of.
        let normalClient = try PTYProcess(
            executable: "/usr/bin/env",
            arguments: ["tmux", "-u", "-S", server.socketPath, "attach", "-t", "tbd-view-geometry"],
            size: normalClientSize)
        defer { normalClient.terminate() }
        try #require(
            await server.awaitClientSize(normalClientSize, onSession: "tbd-view-geometry", within: .seconds(10)),
            "the normal client never attached at \(normalClientSize)")

        let withNormalAlone = try #require(server.windowSize(window))
        #expect(
            withNormalAlone.columns == normalClientSize.columns,
            "the sole client's width should be the window's width")
        let statusLines = normalClientSize.rows - withNormalAlone.rows
        #expect(statusLines >= 0, "a window cannot be taller than the client showing it")

        // --- Both attached: the ignoring client is disregarded.
        let ignoringClient = try PTYProcess(
            executable: "/usr/bin/env",
            arguments: [
                "tmux", "-u", "-S", server.socketPath,
                "attach", "-t", ExternalAttachCommand.sessionPrefix + "geometry",
                "-f", "ignore-size",
            ],
            size: ignoringClientSize)
        defer { ignoringClient.terminate() }
        // Waiting until tmux reports the client at its own dimensions is the
        // positive signal that tmux has taken the new client's geometry into
        // account — whatever it decided to do with it. Reading the window size
        // after that needs no settle interval.
        try #require(
            await server.awaitClientSize(
                ignoringClientSize,
                onSession: ExternalAttachCommand.sessionPrefix + "geometry",
                within: .seconds(10)),
            "the ignore-size client never attached at \(ignoringClientSize)")
        #expect(
            server.clientFlags(onSession: ExternalAttachCommand.sessionPrefix + "geometry")
                .contains("ignore-size"),
            "`-f ignore-size` did not take effect, so nothing below is about ignore-size")

        let withBothAttached = try #require(server.windowSize(window))
        #expect(
            withBothAttached == Size(columns: normalClientSize.columns, rows: normalClientSize.rows - statusLines),
            """
            with both attached the window must keep the NON-ignoring client's size; \
            got \(withBothAttached)
            """)
        #expect(
            withBothAttached.columns != ignoringClientSize.columns,
            "the ignoring client's width must not have reached the window")

        // --- The ignoring client alone: its size is adopted.
        server.tmux(["detach-client", "-s", "tbd-view-geometry"])
        let expectedAlone = Size(
            columns: ignoringClientSize.columns,
            rows: ignoringClientSize.rows - statusLines)
        let withIgnoringAlone = await server.awaitWindowSize(expectedAlone, of: window, within: .seconds(10))
        #expect(
            withIgnoringAlone == expectedAlone,
            """
            once it is the only client left the ignoring client's size must be adopted \
            (the reason "external alone" is a different geometry, and the reason the \
            spec tells you to size the external window exactly like TBD's panel); \
            got \(String(describing: withIgnoringAlone))
            """)
    }
}

// MARK: - Fixtures

private struct Size: Equatable, CustomStringConvertible {
    let columns: Int
    let rows: Int

    var description: String { "\(columns)x\(rows)" }

    /// Parses tmux's `#{..._width}x#{..._height}` output.
    init?(tmuxFormat text: String) {
        let parts = text.split(separator: "x")
        guard parts.count == 2, let columns = Int(parts[0]), let rows = Int(parts[1]) else { return nil }
        self.init(columns: columns, rows: rows)
    }

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

/// A throwaway tmux server on a socket of this suite's own choosing, addressed
/// by absolute path exactly the way the composed script addresses it.
///
/// `-S <path>` rather than `-L <name>` is not a stylistic choice: the script
/// under test pins the socket path, so the fixture has to hand it a real one.
/// The directory sits directly under `/tmp` because a unix socket path is
/// capped at ~104 bytes on darwin and a deeper root fails as
/// "error connecting to … (File name too long)".
private struct TmuxServer {
    let directory: URL
    let socketPath: String

    static func start() throws -> TmuxServer {
        let directory = URL(
            fileURLWithPath: "/tmp/tbd-extlive-\(UUID().uuidString.prefix(8).lowercased())",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let server = TmuxServer(
            directory: directory,
            socketPath: directory.appendingPathComponent("s").path)
        // `-f /dev/null`: the developer's ~/.tmux.conf must not reach a suite
        // that asserts tmux defaults. Config is loaded once, server-side, so
        // every client attaching later inherits this rc-free server.
        // `main` carries no `destroy-unattached`, which is what makes it a
        // usable control for "was the server still alive?".
        server.tmux([
            "-f", "/dev/null",
            "new-session", "-d", "-s", "main", "-x", "80", "-y", "24",
            "sleep", "600",
        ])
        return server
    }

    /// A second window in `main`, standing in for a TBD terminal's window: the
    /// thing the external session links and the clients then display.
    func createWindowInMain() throws -> String {
        let (status, output) = capture([
            "new-window", "-d", "-t", "main:", "-P", "-F", "#{window_id}", "sleep", "600",
        ])
        guard status == 0, output.hasPrefix("@") else {
            throw Failure("could not create a window in `main` (status \(status)): \(output)")
        }
        return output
    }

    /// TBD's panel recipe: an isolated session holding exactly one linked
    /// window, throwaway window 0 killed. Deliberately without
    /// `destroy-unattached`, so the geometry test can detach a client without
    /// the session evaporating underneath the measurement.
    func makeLinkedSession(named name: String, window: String) throws {
        tmux(["new-session", "-d", "-s", name, "-c", "/tmp"])
        tmux(["link-window", "-s", window, "-t", name + ":"])
        tmux(["kill-window", "-t", name + ":0"])
        guard windowIDs(inSession: name) == window else {
            throw Failure("session \(name) does not hold \(window): \(windowIDs(inSession: name))")
        }
    }

    // MARK: Observations

    func hasSession(_ name: String) -> Bool {
        capture(["has-session", "-t", name]).status == 0
    }

    func windowIDs(inSession name: String) -> String {
        capture(["list-windows", "-t", name, "-F", "#{window_id}"]).output
    }

    func clientTTYs(onSession name: String) -> String {
        capture(["list-clients", "-t", name, "-F", "#{client_tty}"]).output
    }

    func clientFlags(onSession name: String) -> String {
        capture(["list-clients", "-t", name, "-F", "#{client_flags}"]).output
    }

    func clientSize(onSession name: String) -> Size? {
        Size(tmuxFormat: capture([
            "list-clients", "-t", name, "-F", "#{client_width}x#{client_height}",
        ]).output)
    }

    func windowSize(_ window: String) -> Size? {
        Size(tmuxFormat: capture([
            "display-message", "-p", "-t", window, "#{window_width}x#{window_height}",
        ]).output)
    }

    func globalOption(_ name: String) -> String {
        let value = capture(["show-options", "-g", name]).output
        return value.hasPrefix(name + " ") ? String(value.dropFirst(name.count + 1)) : value
    }

    // MARK: Bounded waits

    /// True as soon as a client is attached to `session`. Gives up early — not
    /// only at the deadline — when the script's shell has already exited, so a
    /// failed attach costs milliseconds rather than the whole budget.
    func awaitClient(
        onSession session: String,
        orExitOf process: PTYProcess,
        within limit: Duration
    ) async -> Bool {
        await poll(within: limit) { () -> Bool? in
            if !clientTTYs(onSession: session).isEmpty { return true }
            if !process.isRunning { return false }
            return nil
        } ?? false
    }

    func awaitClientSize(_ size: Size, onSession session: String, within limit: Duration) async -> Bool {
        await poll(within: limit) { () -> Bool? in clientSize(onSession: session) == size ? true : nil } ?? false
    }

    func awaitSessionGone(_ session: String, within limit: Duration) async -> Bool {
        await poll(within: limit) { () -> Bool? in hasSession(session) ? nil : true } ?? false
    }

    /// Polls until the window reaches `size`, then returns it — or returns
    /// whatever it last saw when the deadline passes, so the failure message
    /// names the size tmux actually settled on.
    func awaitWindowSize(_ size: Size, of window: String, within limit: Duration) async -> Size? {
        var last = windowSize(window)
        _ = await poll(within: limit) { () -> Bool? in
            last = windowSize(window)
            return last == size ? true : nil
        }
        return last
    }

    /// Bounded polling loop. `probe` returns nil to keep waiting; the loop
    /// returns nil when the deadline passes, so no caller can wait forever.
    private func poll<T>(within limit: Duration, probe: () -> T?) async -> T? {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if let value = probe() { return value }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return probe()
    }

    // MARK: Running tmux

    @discardableResult
    func tmux(_ arguments: [String]) -> Int32 {
        capture(arguments).status
    }

    func capture(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "-S", socketPath] + arguments
        process.environment = sanitizedEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus, output)
        } catch {
            return (-1, "\(error)")
        }
    }

    // MARK: Teardown

    /// Kills the server and removes the fenced directory — including the socket
    /// file, which tmux itself never unlinks — then asserts the removal, so a
    /// leak fails the run that caused it instead of accumulating quietly.
    func tearDown() {
        tmux(["kill-server"])
        try? FileManager.default.removeItem(at: directory)
        #expect(
            !FileManager.default.fileExists(atPath: directory.path),
            "the fenced socket directory \(directory.path) survived the test")
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

/// A child process holding a real PTY, sized before it starts.
///
/// A tmux client refuses to attach to anything that is not a terminal, and it
/// reports its geometry from the PTY's window size — so `Process` with plain
/// pipes cannot stand in here, and the sizes this suite asserts on come from
/// the `TIOCSWINSZ` baked into `openpty`.
///
/// The primary end is drained on a dedicated thread. Nothing here reads the
/// screen — the captured bytes exist only so a failed attach can quote what
/// tmux printed ("can't find session: …") in its diagnostic. That is a
/// diagnostic, never a signal: every assertion in this suite comes from tmux's
/// own format strings, per the repo's no-TUI-scraping rule.
private final class PTYProcess: @unchecked Sendable {

    private let process = Process()
    private let primaryFD: Int32
    private let buffer = OutputBuffer()
    private let terminationLock = NSLock()
    private var isTerminated = false

    init(executable: String, arguments: [String], size: Size) throws {
        var primary: Int32 = -1
        var replica: Int32 = -1
        var term = termios()
        cfmakeraw(&term)
        var windowSize = winsize(
            ws_row: UInt16(size.rows),
            ws_col: UInt16(size.columns),
            ws_xpixel: 0,
            ws_ypixel: 0)
        guard openpty(&primary, &replica, nil, &term, &windowSize) == 0 else {
            throw TmuxServer.Failure("openpty failed: \(String(cString: strerror(errno)))")
        }
        primaryFD = primary

        let replicaHandle = FileHandle(fileDescriptor: replica, closeOnDealloc: false)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = sanitizedEnvironment()
        process.standardInput = replicaHandle
        process.standardOutput = replicaHandle
        process.standardError = replicaHandle
        do {
            try process.run()
        } catch {
            close(primary)
            close(replica)
            throw error
        }
        // The child holds its own dup of the replica; the parent's copy would
        // otherwise keep the PTY from ever reporting EOF.
        close(replica)

        let sink = buffer
        let readEnd = primaryFD
        Thread.detachNewThread {
            var scratch = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = scratch.withUnsafeMutableBytes { read(readEnd, $0.baseAddress, 4096) }
                guard count > 0 else { return }
                sink.append(scratch.prefix(count))
            }
        }
    }

    var isRunning: Bool { process.isRunning }

    var capturedOutput: String { buffer.text }

    /// SIGTERM, then SIGKILL on a bounded wait — a client that ignored the
    /// first must not park teardown, and teardown runs from `defer` on paths
    /// where the test has already failed.
    func terminate() {
        terminationLock.lock()
        let alreadyTerminated = isTerminated
        isTerminated = true
        terminationLock.unlock()
        guard !alreadyTerminated else { return }

        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                usleep(20_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        // Closing the primary ends the drain thread's blocking read.
        close(primaryFD)
    }

    /// Head-capped so a chatty tmux client cannot grow this without bound; the
    /// first few KB are where an attach failure announces itself anyway.
    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [UInt8] = []

        func append(_ chunk: ArraySlice<UInt8>) {
            lock.lock()
            defer { lock.unlock() }
            guard bytes.count < 4096 else { return }
            bytes.append(contentsOf: chunk)
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

/// `$TMUX` set — this suite may well be running inside a TBD terminal — makes
/// every `tmux attach` below refuse to nest. `TERM` is pinned so a harness that
/// exports none still gets a client tmux will talk to.
private func sanitizedEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "TMUX")
    environment.removeValue(forKey: "TMUX_PANE")
    environment["TERM"] = "xterm-256color"
    return environment
}
