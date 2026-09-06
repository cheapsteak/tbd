import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 3 — a real throwaway tmux server, driven through the production
/// `TmuxManager.ensureServer` seam.
///
/// The unit suite (`TmuxServerEnvironmentRepairTests`) pins the SHAPE of the
/// repair invocation and the by-value `CLAUDE_CONFIG_DIR` judgment. Neither can
/// answer the question this file exists for: whether tmux, handed that
/// invocation, actually removes those names from a *running* server's global
/// environment — and leaves everything else in it alone.
///
/// Why an in-place repair is needed at all: a tmux server bakes the environment
/// it was spawned with into its global environment and hands that to every
/// window it creates afterwards, and servers outlive daemon restarts. A server
/// created by a daemon that carried its launcher's identity keeps handing that
/// identity to new panes for as long as it lives, so scrubbing the base at
/// server-creation time alone never reaches it.
@Suite("tmux server environment repair (live)")
struct TmuxServerEnvironmentRepairLiveTests {

    /// One-shot tmux command via the same binary TmuxManager uses,
    /// capturing trimmed stdout (nil on nonzero exit).
    ///
    /// The child inherits this process's environment, so `TMUX_TMPDIR` — which
    /// `scripts/test.sh` points at the run's scratch dir — reaches it and every
    /// `-L <name>` socket this file creates lands inside the fence.
    private func tmuxCapture(_ args: [String]) -> String? {
        guard let tmuxPath = TmuxManager.tmuxPath() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// Poll a tmux query until it returns `expected`, or throw at the deadline.
    /// Bounded, never an unbounded wait — a server that never converges must
    /// fail the test rather than hang the run.
    private func awaitTmuxValue(_ args: [String], expected: String,
                                what: String,
                                timeout: Duration = .seconds(15)) async throws {
        let deadline = ContinuousClock.now + timeout
        var last: String?
        while ContinuousClock.now < deadline {
            last = tmuxCapture(args)
            if last == expected { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw TmuxEnvironmentRepairTestError.valueMismatch(
            what: what, expected: expected, actual: last ?? "<nonzero exit or no output>"
        )
    }

    /// Poll until `name` is gone from the server's GLOBAL environment, or throw
    /// at the deadline.
    ///
    /// Two readings count as gone, because tmux has two ways of not having a
    /// variable and only one of them prints anything. Measured against tmux
    /// 3.6a: after `set-environment -gu NAME` — what the repair issues, and what
    /// tmux(1) documents as "unsets a variable" — the entry is removed outright
    /// and `show-environment -g NAME` reports `unknown variable: NAME` on stderr
    /// and exits 1, which `tmuxCapture` surfaces as nil. After
    /// `set-environment -gr NAME`, which instead marks the variable *to be
    /// removed from the environment before starting a new process*, the same
    /// query exits 0 and prints `-NAME`. Accepting either keeps this assertion
    /// pinned to the outcome that matters — the name cannot reach a pane created
    /// from now on — rather than to which of the two spellings the repair
    /// happens to use. It stays discriminating because every caller first proves
    /// the value was there as `NAME=<sentinel>`.
    private func awaitTmuxNotInGlobalEnvironment(
        server: String, name: String, timeout: Duration = .seconds(15)
    ) async throws {
        let query = ["-L", server, "show-environment", "-g", name]
        let deadline = ContinuousClock.now + timeout
        var last: String?
        while ContinuousClock.now < deadline {
            last = tmuxCapture(query)
            if last == nil || last == "-\(name)" { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw TmuxEnvironmentRepairTestError.stillSet(name: name, actual: last ?? "<none>")
    }

    /// A socket name no other run can collide with. Kept short on purpose: tmux
    /// resolves `-L <name>` under `$TMUX_TMPDIR/tmux-<uid>/`, and that path is
    /// bound by darwin's ~104-byte `sun_path` cap.
    private func throwawayServerName() -> String {
        "tbd-envrepair-" + UUID().uuidString
            .replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
    }

    /// The config dir shape TBD mints for one profile-bound Claude spawn, under
    /// the profiles root of the installation THIS PROCESS names — the fenced
    /// `TBD_HOME` under `scripts/test.sh` — because that is the installation
    /// `ensureServer` judges the server's value against.
    private func mintedProfileConfigDir() -> String {
        TBDConstants.configDir(environment: ProcessInfo.processInfo.environment)
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("live-test-profile", isDirectory: true)
            .appendingPathComponent("claude", isDirectory: true)
            .path
    }

    @Test func ensureServerRepairsAnExistingServersGlobalEnvironmentInPlace() async throws {
        let server = throwawayServerName()
        let tmux = TmuxManager()
        defer {
            // Best-effort teardown — the throwaway server must not outlive the
            // test even when an assertion above throws.
            _ = tmuxCapture(["-L", server, "kill-server"])
        }

        // Create the server through the production seam (create branch).
        _ = try await tmux.ensureServer(
            server: server, session: "main", cwd: "/tmp", cols: 220, rows: 50)

        // Stand in for a server a daemon created while carrying its launcher's
        // identity. Planting the markers with one-shot `set-environment -g`
        // reproduces the end state exactly — a tmux server's global environment
        // is the same table whether the names arrived from the spawn env or
        // from a client — without needing a daemon that inherited them.
        let incarnation = "live-test-incarnation-\(UUID().uuidString)"
        let thread = "live-test-thread-\(UUID().uuidString)"
        let minted = mintedProfileConfigDir()
        // If the fence ever stops making this value minted, fail here with the
        // path in the message rather than mysteriously at the repair assertion.
        #expect(
            SpawnBaseEnvironment.isTBDMintedProfileDir(
                minted, base: ProcessInfo.processInfo.environment),
            "\(minted) must be judged TBD-minted for the repair to be expected")

        for (name, value) in [
            ("TBD_TERMINAL_INCARNATION_ID", incarnation),
            ("CODEX_THREAD_ID", thread),
            ("CLAUDE_CODE_CHILD_SESSION", "1"),
            ("CLAUDE_CONFIG_DIR", minted),
        ] {
            _ = tmuxCapture(["-L", server, "set-environment", "-g", name, value])
            try await awaitTmuxValue(
                ["-L", server, "show-environment", "-g", name],
                expected: "\(name)=\(value)",
                what: "planted global \(name)")
        }

        // Second call: the session exists, so `ensureServer` takes the repair
        // branch. A nil return is that branch's own signature.
        let secondCall = try await tmux.ensureServer(
            server: server, session: "main", cwd: "/tmp", cols: 220, rows: 50)
        #expect(secondCall == nil, "an existing session must not report a new bootstrap window")

        // TBD's and Codex's markers are gone from the global environment, so no
        // window the server creates from now on inherits the launcher's identity.
        try await awaitTmuxNotInGlobalEnvironment(server: server, name: "TBD_TERMINAL_INCARNATION_ID")
        try await awaitTmuxNotInGlobalEnvironment(server: server, name: "CODEX_THREAD_ID")
        // And the TBD-minted config dir, which is judged by value: only TBD ever
        // writes a directory under this installation's profiles root, so such a
        // value is per-spawn identity by construction.
        try await awaitTmuxNotInGlobalEnvironment(server: server, name: "CLAUDE_CONFIG_DIR")

        // Claude Code's markers are deliberately spared on a server repaired in
        // place. A pane that predates the repair already holds its own copy, and
        // an interactive `claude` reads that copy as ambient — the server's,
        // not its own — only while the server's global copy is there too.
        // Removing the global copy would make a `claude` started later in such a
        // pane conclude it is a nested child, which is the exact failure the
        // scrub exists to prevent. They go away when the server is recycled, by
        // which time no pane predates the scrub.
        try await awaitTmuxValue(
            ["-L", server, "show-environment", "-g", "CLAUDE_CODE_CHILD_SESSION"],
            expected: "CLAUDE_CODE_CHILD_SESSION=1",
            what: "spared Claude Code marker")
    }

    @Test func aUsersOwnConfigDirSurvivesTheRepair() async throws {
        let server = throwawayServerName()
        let tmux = TmuxManager()
        defer { _ = tmuxCapture(["-L", server, "kill-server"]) }

        _ = try await tmux.ensureServer(
            server: server, session: "main", cwd: "/tmp", cols: 220, rows: 50)

        // Not under this installation's profiles root, so it is the user's own
        // configuration, which TBD honours rather than strips.
        let userConfigDir = "/tmp/example-user-config"
        #expect(
            SpawnBaseEnvironment.isTBDMintedProfileDir(
                userConfigDir, base: ProcessInfo.processInfo.environment) == false,
            "the discriminating half needs a value TBD did not mint")

        _ = tmuxCapture(["-L", server, "set-environment", "-g", "CLAUDE_CONFIG_DIR", userConfigDir])
        try await awaitTmuxValue(
            ["-L", server, "show-environment", "-g", "CLAUDE_CONFIG_DIR"],
            expected: "CLAUDE_CONFIG_DIR=\(userConfigDir)",
            what: "planted user CLAUDE_CONFIG_DIR")

        let secondCall = try await tmux.ensureServer(
            server: server, session: "main", cwd: "/tmp", cols: 220, rows: 50)
        #expect(secondCall == nil, "an existing session must not report a new bootstrap window")

        // The repair ran (it is unconditional on this branch) and left the value
        // alone. Polling rather than a single read so the assertion is made
        // against a settled server, the same way the positive cases are.
        try await awaitTmuxValue(
            ["-L", server, "show-environment", "-g", "CLAUDE_CONFIG_DIR"],
            expected: "CLAUDE_CONFIG_DIR=\(userConfigDir)",
            what: "user CLAUDE_CONFIG_DIR after the repair")
    }

    @Test func aFreshServerIsCreatedUnderThePinnedBase() async throws {
        let server = throwawayServerName()
        let tmux = TmuxManager()
        defer { _ = tmuxCapture(["-L", server, "kill-server"]) }

        let initialWindowID = try await tmux.ensureServer(
            server: server, session: "main", cwd: "/tmp", cols: 220, rows: 50)
        _ = try #require(
            initialWindowID,
            "fresh server must report the new-session bootstrap window ID")

        // The server process is the one `SpawnBaseEnvironment.inheriting` builds
        // the environment for, and tmux copies its own environment into the
        // global environment at startup (measured against 3.6a: a fresh server
        // lists TERM there) — so this reads the pin back out.
        //
        // `ensureServer` also sets `default-terminal xterm-256color`, which is
        // where a PANE's TERM comes from; that is a server OPTION, a different
        // table entirely. This assertion is about the environment. It is the
        // weaker half of this test, since a dev or CI shell may legitimately
        // already carry `TERM=xterm-256color` — passthrough would look identical
        // to the pin — which is why the TMUX half below carries the discrimination.
        try await awaitTmuxValue(
            ["-L", server, "show-environment", "-g", "TERM"],
            expected: "TERM=xterm-256color",
            what: "pinned TERM in the created server's global environment")

        // The enclosing pane's coordinates never reach the server. Measured
        // against 3.6a, a client that has `TMUX`/`TMUX_PANE` set DOES plant them
        // in the global environment of the server it starts, so this fails
        // without the scrub whenever the run itself was started from inside tmux
        // — the normal case for this repo — and is a non-regression check
        // otherwise. The test must not arrange that itself: a `setenv("TMUX")`
        // here would set it for the whole test binary, and every tmux client any
        // concurrently running suite spawns would then refuse to nest.
        try await awaitTmuxNotInGlobalEnvironment(server: server, name: "TMUX")
    }
}

private enum TmuxEnvironmentRepairTestError: Error, CustomStringConvertible {
    case valueMismatch(what: String, expected: String, actual: String)
    case stillSet(name: String, actual: String)

    var description: String {
        switch self {
        case let .valueMismatch(what, expected, actual):
            return "\(what): expected \(expected), got \(actual)"
        case let .stillSet(name, actual):
            return "\(name) is still in the server's global environment: \(actual)"
        }
    }
}
