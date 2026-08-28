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
///    by test"). The spec called the window between creating the session
///    detached and attaching to it a race. Measured here it is not a race at
///    all — `destroyUnattachedReapsBeforeAnyClientCanArrive` shows the session
///    is reaped every time, which is why the composer now chains
///    `destroy-unattached on` onto the attach instead of setting it in the
///    setup block. `composedScriptAttachesToTheTerminalsWindow` is the other
///    half: the composed script, run for real, attaches.
///  - **Landing on the verified window and nothing else.** Three ways the
///    script could put a person on the throwaway `/tmp` shell instead of their
///    agent — a non-zero `base-index` in the user's `~/.tmux.conf`, a window
///    that died between the daemon's probe and the paste, and a surviving
///    session built around a window that has since been replaced — each get a
///    test, because each was a real defect and none is visible in the composed
///    string.
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
///    spawned later inherit that same rc-free server. The one test that needs
///    a *configured* server passes `TmuxServer.start(config:)`, which writes
///    the config into that server's own fenced directory — the real
///    `~/.tmux.conf` is neither read nor written anywhere here.
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
    /// The composer chains `set-option … destroy-unattached on` onto the attach
    /// rather than setting it on the still-detached session in the setup block,
    /// which is what makes this hold. Setting it early is not a race the attach
    /// usually wins — tmux reaps the session on that same server tick and every
    /// attempt dies with `can't find session` (measured: 0 of 20). The attempt
    /// is repeated here because the spec expected a *race*, so a single pass
    /// would not have distinguished "fixed" from "got lucky once".
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

    // MARK: - 1b. Nothing but the verified window, on any server

    /// **`base-index` must not change where the client lands.** The daemon's
    /// tmux servers are started by `TmuxManager`, which passes no `-f`, so they
    /// load the user's `~/.tmux.conf` — and `set -g base-index 1` is one of the
    /// most common lines in one. Under it the throwaway window is at index 1,
    /// so the `kill-window -t <session>:0` this composer used to emit failed
    /// with `can't find window: 0`, tmux abandoned the rest of the `\;` chain,
    /// and the session kept a bare `/tmp` shell alongside the agent's window
    /// for the client to wander into — which the spec's "the session holds one
    /// window, so there is nowhere to wander" says must not happen.
    ///
    /// This is the one test in the suite that deliberately runs a server that
    /// is *not* rc-free, so the config is written into the server's own fenced
    /// directory. The `base-index` reading below is not decoration: without it
    /// a config that silently failed to load would make this pass while
    /// measuring the default server the other tests already cover.
    @Test("a non-zero base-index still leaves the session holding only the terminal's window")
    func composedScriptSurvivesANonZeroBaseIndex() async throws {
        let server = try TmuxServer.start(config: "set -g base-index 1\n")
        defer { server.tearDown() }
        try #require(
            server.globalOption("base-index") == "1",
            "the fenced config did not load, so this would measure a default server")
        let window = try server.createWindowInMain()

        let session = ExternalAttachCommand.sessionName(for: UUID())
        let client = try PTYProcess(
            executable: "/bin/sh",
            arguments: ["-c", ExternalAttachCommand.script(
                socketPath: server.socketPath,
                sessionName: session,
                windowID: window)],
            size: Size(columns: 100, rows: 30))
        defer { client.terminate() }

        #expect(
            await server.awaitClient(onSession: session, orExitOf: client, within: .seconds(10)),
            "no client attached under `base-index 1`: \(client.capturedOutput)")
        #expect(
            server.windowIDs(inSession: session) == window,
            """
            the session must hold the terminal's window and nothing else; \
            held \(server.windowIDs(inSession: session)) — a leftover throwaway \
            window means the index-dependent `kill-window` is back
            """)
        #expect(
            server.clientWindowIDs(onSession: session) == window,
            "the client is showing \(server.clientWindowIDs(onSession: session)), not \(window)")
    }

    // MARK: - 1c. Failing loudly rather than landing on a shell

    /// **A setup that fails must not be followed by an attach.** The window can
    /// die between the daemon's probe and the person's paste — a closed tab, a
    /// respawn, a reconcile pass, a slow hand — and `link-window` then fails.
    /// While setup and attach were two bare statements the attach ran anyway
    /// and put a client on the throwaway `/tmp` shell, with one line of tmux
    /// stderr, scrolled off by the attach's own redraw, as the only signal.
    ///
    /// A vanished window is simulated here with an id no window has, which
    /// reaches `link-window` in exactly the same state a real one would.
    ///
    /// The session assertion is the second half and is not incidental: a
    /// half-built session would be a client-less `tbd-ext-*` holding a bare
    /// shell under this terminal's own name, waiting for the reconciler.
    @Test("a window that no longer exists leaves neither a client nor a session")
    func aVanishedWindowLeavesNeitherClientNorSession() async throws {
        let server = try TmuxServer.start()
        defer { server.tearDown() }
        let liveWindow = try server.createWindowInMain()

        let missingWindow = "@999999"
        try #require(
            !server.windowIDs(inSession: "main").contains(missingWindow),
            "the id chosen to stand for a vanished window must not name a real one")

        let session = ExternalAttachCommand.sessionName(for: UUID())
        let client = try PTYProcess(
            executable: "/bin/sh",
            arguments: ["-c", ExternalAttachCommand.script(
                socketPath: server.socketPath,
                sessionName: session,
                windowID: missingWindow)],
            size: Size(columns: 100, rows: 30))
        defer { client.terminate() }

        #expect(
            !(await server.awaitClient(onSession: session, orExitOf: client, within: .seconds(10))),
            """
            a client attached after `link-window` failed — it is sitting on the \
            throwaway /tmp shell believing it is an agent session. Script output: \
            \(client.capturedOutput)
            """)
        #expect(
            !server.hasSession(session),
            "the failed build left \(session) behind holding \(server.windowIDs(inSession: session))")
        // Discriminates "the script declined to attach" from "the server died",
        // which would make every assertion above vacuously true.
        #expect(server.hasSession("main"), "the server must still be alive")
        #expect(server.windowIDs(inSession: "main").contains(liveWindow))
    }

    // MARK: - 1d. A surviving session is reused only if it is the right one

    /// **A session that already exists must never be attached to unverified.**
    /// The terminal-keyed name outlives the window it was built around: a
    /// terminal's window can die and be recreated under a new id, with the DB
    /// updated and the pane re-stamped, so the daemon's probe passes cleanly
    /// and names the *new* window. A `has-session ||` guard would then see the
    /// old session, skip setup entirely, and attach the person to the window
    /// nobody is using any more — with no error anywhere.
    ///
    /// Comparing the session's window list against the verified window instead
    /// makes the stale case rebuild.
    @Test("a session holding the wrong window is rebuilt, not reused")
    func aSessionHoldingTheWrongWindowIsRebuilt() async throws {
        let server = try TmuxServer.start()
        defer { server.tearDown() }
        let staleWindow = try server.createWindowInMain()
        let currentWindow = try server.createWindowInMain()
        #expect(staleWindow != currentWindow)

        // The session as a previous attach left it: right name, dead window.
        let session = ExternalAttachCommand.sessionName(for: UUID())
        try server.makeLinkedSession(named: session, window: staleWindow)

        let client = try PTYProcess(
            executable: "/bin/sh",
            arguments: ["-c", ExternalAttachCommand.script(
                socketPath: server.socketPath,
                sessionName: session,
                windowID: currentWindow)],
            size: Size(columns: 100, rows: 30))
        defer { client.terminate() }

        #expect(
            await server.awaitClient(onSession: session, orExitOf: client, within: .seconds(10)),
            "no client attached: \(client.capturedOutput)")
        #expect(
            server.windowIDs(inSession: session) == currentWindow,
            """
            the surviving session was reused as-is: it holds \
            \(server.windowIDs(inSession: session)) rather than the verified \
            window \(currentWindow)
            """)
        #expect(
            server.clientWindowIDs(onSession: session) == currentWindow,
            """
            the client is showing \(server.clientWindowIDs(onSession: session)) — \
            the stale window — instead of \(currentWindow)
            """)
    }

    /// The other half of that choice, and the reason it is verify-then-rebuild
    /// rather than the unconditional kill `TmuxBridge` performs: a session that
    /// *does* hold the verified window is reused, so a second invocation cannot
    /// evict an external client that is already attached and measuring.
    @Test("a session already holding the verified window is reused, sparing its client")
    func aSessionHoldingTheVerifiedWindowIsReused() async throws {
        let server = try TmuxServer.start()
        defer { server.tearDown() }
        let window = try server.createWindowInMain()

        let session = ExternalAttachCommand.sessionName(for: UUID())
        try server.makeLinkedSession(named: session, window: window)

        // Somebody is already attached — a measurement in progress.
        let firstClient = try PTYProcess(
            executable: "/usr/bin/env",
            arguments: ["tmux", "-u", "-S", server.socketPath, "attach", "-t", session, "-f", "ignore-size"],
            size: Size(columns: 100, rows: 30))
        defer { firstClient.terminate() }
        try #require(
            await server.awaitClient(onSession: session, orExitOf: firstClient, within: .seconds(10)),
            "the standing client never attached: \(firstClient.capturedOutput)")
        let standingTTYs = Set(server.clientTTYs(onSession: session).split(separator: "\n").map(String.init))
        try #require(standingTTYs.count == 1, "expected exactly one standing client, got \(standingTTYs)")

        let secondClient = try PTYProcess(
            executable: "/bin/sh",
            arguments: ["-c", ExternalAttachCommand.script(
                socketPath: server.socketPath,
                sessionName: session,
                windowID: window)],
            size: Size(columns: 100, rows: 30))
        defer { secondClient.terminate() }

        let bothAttached = await server.poll(within: .seconds(10)) { () -> Bool? in
            let ttys = Set(server.clientTTYs(onSession: session).split(separator: "\n").map(String.init))
            return ttys.count >= 2 ? true : nil
        } ?? false
        #expect(bothAttached, "the second client never attached: \(secondClient.capturedOutput)")
        #expect(
            standingTTYs.isSubset(of: Set(server.clientTTYs(onSession: session).split(separator: "\n").map(String.init))),
            """
            the standing client was evicted — an unconditional rebuild would \
            interrupt a measurement in progress. Clients now: \
            \(server.clientTTYs(onSession: session))
            """)
        #expect(server.windowIDs(inSession: session) == window)
    }

    // MARK: - 2. Why: the gap is not a race

    /// One tmux behavior, pinned on its own: **a detached session with
    /// `destroy-unattached on` is collected before any client can reach it.**
    /// Setting the option is itself enough to schedule the tick that collects
    /// it — no client ever has to come and go — so a session created detached
    /// with the option already on cannot survive long enough for a separate
    /// `tmux attach` process to arrive.
    ///
    /// **What this does and does not prove.** It builds its session with raw
    /// tmux calls and never invokes `ExternalAttachCommand.script`, so it is
    /// *not* a regression guard on where the composer puts the option: move
    /// `set-option` back into the setup block and this test still passes,
    /// unchanged. It proves only the tmux rule that makes that placement
    /// wrong, which is why the rule is worth writing down separately — a
    /// future tmux that stopped collecting detached sessions would make the
    /// placement a free choice, and this is the test that would notice.
    ///
    /// The guards on the composer itself are elsewhere:
    /// `scriptMatchesSpecVerbatim` in
    /// `Tests/TBDSharedTests/ExternalAttachCommandTests.swift` pins the string
    /// whole, and `composedScriptAttachesToTheTerminalsWindow` runs it twenty
    /// times against a real server. A composer that set the option early would
    /// redden both.
    @Test("destroy-unattached reaps a detached session before any client can arrive")
    func destroyUnattachedReapsBeforeAnyClientCanArrive() async throws {
        let server = try TmuxServer.start()
        defer { server.tearDown() }
        let window = try server.createWindowInMain()

        let session = ExternalAttachCommand.sessionName(for: UUID())
        server.tmux(["new-session", "-d", "-s", session, "-c", "/tmp"])
        server.tmux(["link-window", "-s", window, "-t", session + ":"])
        server.tmux(["kill-window", "-a", "-t", session + ":" + window])

        // The gap the script leaves open starts here: the session exists, holds
        // the window, and has no client.
        #expect(server.hasSession(session), "the session must exist before the option is set")
        #expect(server.clientTTYs(onSession: session).isEmpty, "nothing has attached yet")

        server.tmux(["set-option", "-t", session, "destroy-unattached", "on"])

        let gone = await server.awaitSessionGone(session, within: .seconds(5))
        #expect(gone, """
            tmux kept an unattached `destroy-unattached on` session alive — if this \
            ever fails, setting the option before a client arrives would be safe after \
            all, and the composer would be free to move it back into the setup block.
            """)
        // Discriminates a reap from a dead server: `main` never carries the
        // option, so it must be untouched.
        #expect(server.hasSession("main"), """
            the sibling session without the option must survive, or this measured \
            a server that died rather than a session that was reaped
            """)
    }

    // MARK: - 2b. Why a `\;` chain is a guard at all

    /// The tmux rule three of the guards above are built on, pinned on its own:
    /// **a `\;` chain stops at its first failing command, and everything after
    /// it is abandoned.** It is why a failed `link-window` cannot be followed by
    /// a `kill-window`, why the index-dependent `kill-window -t <session>:0`
    /// took the rest of its chain down with it, and why putting `select-window`
    /// *ahead* of the attach turns it into the last check on the window still
    /// being there — the residual gap between the daemon's probe and the
    /// person's paste.
    ///
    /// Asserted here with no composer involved, on the shape that matters: an
    /// attach chain whose leading `select-window` names a window the session
    /// does not hold. If a future tmux ran the rest of a failed chain anyway,
    /// that gap would reopen silently, and this is the test that would say so.
    @Test("a failing select-window abandons the rest of the chain, so no client attaches")
    func aFailingSelectWindowAbandonsTheAttachChain() async throws {
        let server = try TmuxServer.start()
        defer { server.tearDown() }
        let window = try server.createWindowInMain()

        let session = ExternalAttachCommand.sessionName(for: UUID())
        try server.makeLinkedSession(named: session, window: window)

        let client = try PTYProcess(
            executable: "/usr/bin/env",
            arguments: [
                "tmux", "-u", "-S", server.socketPath,
                "select-window", "-t", session + ":@999999", ";",
                "attach", "-t", session, "-f", "ignore-size", ";",
                "set-option", "-t", session, "destroy-unattached", "on",
            ],
            size: Size(columns: 100, rows: 30))
        defer { client.terminate() }

        #expect(
            !(await server.awaitClient(onSession: session, orExitOf: client, within: .seconds(10))),
            """
            tmux ran an attach that followed a failed `select-window` in the same \
            chain. Client output: \(client.capturedOutput)
            """)
        // The session is untouched — this pins chain abandonment, not a reap.
        #expect(server.windowIDs(inSession: session) == window)
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

    /// - Parameter config: tmux configuration to start the server with, for the
    ///   one test that needs a *non*-default server. Written into this server's
    ///   own fenced directory — never `~/.tmux.conf`, which this suite must
    ///   neither read nor write. Omitted, the server is rc-free.
    static func start(config: String? = nil) throws -> TmuxServer {
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
        // `-f /dev/null` by default: the developer's ~/.tmux.conf must not
        // reach a suite that asserts tmux defaults. Config is loaded once,
        // server-side, so every client attaching later inherits this server.
        // `main` carries no `destroy-unattached`, which is what makes it a
        // usable control for "was the server still alive?".
        var configPath = "/dev/null"
        if let config {
            let file = directory.appendingPathComponent("tmux.conf")
            try config.write(to: file, atomically: true, encoding: .utf8)
            configPath = file.path
        }
        server.tmux([
            "-f", configPath,
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
        // `-a` — kill every window except the target — for the same reason the
        // composer uses it: `:0` names the throwaway only when `base-index` is
        // 0, and a fixture that quietly left a second window behind would let
        // an assertion about "the session's window" mean something else.
        tmux(["kill-window", "-a", "-t", name + ":" + window])
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

    /// The window each client attached to `name` is currently displaying — the
    /// only thing that answers "did the person land where they asked to land?".
    func clientWindowIDs(onSession name: String) -> String {
        capture(["list-clients", "-t", name, "-F", "#{window_id}"]).output
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
    func poll<T>(within limit: Duration, probe: () -> T?) async -> T? {
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
    ///
    /// **Every wait here is bounded, the final one included, and that is what
    /// rules out `Process.waitUntilExit()`.** That call spins the *calling*
    /// thread's run loop until the task-death source fires on it, and a test
    /// body runs on a cooperative thread where that source is not scheduled —
    /// so unless Foundation happened to notice the exit already, it parks in
    /// `mach_msg` and never returns. Nothing rescues it afterwards: the suite's
    /// `.timeLimit` cannot cancel a blocked thread, so the whole run wedges
    /// while holding the machine-global build lock. Measured here: a run left
    /// sitting in that call for thirteen minutes with no child process left
    /// alive, killed by hand. Polling `isRunning` against a deadline reaps in
    /// the same few hundred milliseconds on the ordinary path and gives up
    /// rather than hanging on the pathological one.
    func terminate() {
        terminationLock.lock()
        let alreadyTerminated = isTerminated
        isTerminated = true
        terminationLock.unlock()
        guard !alreadyTerminated else { return }

        if process.isRunning {
            process.terminate()
            if !awaitExit(within: 2) {
                kill(process.processIdentifier, SIGKILL)
                _ = awaitExit(within: 2)
            }
        }
        // Closing the primary ends the drain thread's blocking read.
        close(primaryFD)
    }

    /// True once the child is no longer running, false when `limit` elapses
    /// first. Bounded by construction — see `terminate()` for why the obvious
    /// `waitUntilExit()` is not usable here.
    private func awaitExit(within limit: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline {
            if !process.isRunning { return true }
            usleep(20_000)
        }
        return !process.isRunning
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
