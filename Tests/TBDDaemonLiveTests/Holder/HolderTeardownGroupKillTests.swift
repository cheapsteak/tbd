import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// What a holder teardown leaves running outside the daemon's process table.
///
/// Teardown killed the job by **one pid** — the `sh` at the head of the
/// session — and relied on the pty hang-up to take the rest of the job with it.
/// That is a courtesy the job is free to decline: closing the master delivers
/// `SIGHUP` to the whole foreground process group, so a member at the default
/// disposition dies for free, but `nohup`, a daemonizing agent, or a shell with
/// `huponexit` off survives and is reparented to pid 1. Nothing sweeps it —
/// `WorktreeLifecycle+Reconcile` skips holder rows by construction — so that is
/// one leaked process per teardown, forever.
///
/// The design spec already names the remedy on the sibling holder-death path:
/// kill the job's **process group**, which `forkpty` makes the natural closure
/// of the session. This suite holds the teardown path to the same rule.
///
/// Two properties make the measurement discriminating, and dropping either one
/// makes the test pass against the bug:
///
///   - The grandchild **ignores `SIGHUP`**. One at the default disposition dies
///     of the pty close alone, so it proves nothing about who was signalled.
///   - The grandchild **never writes to the pty** — it holds `/dev/null` on all
///     three descriptors. A writer dies of `EIO` on a revoked terminal, which
///     is again a death the kill did not cause.
///
/// **Tier 3.** It spawns a real `TBDHolder` through the real `HolderSpawner`,
/// forks real processes onto a real pty, and reads the kernel's view of them.
@Suite(.serialized)
struct HolderTeardownGroupKillTests {

    /// A job that forks one `SIGHUP`-proof grandchild, reports its pid on the
    /// filesystem rather than the terminal, and then waits to be killed.
    ///
    /// `trap '' HUP` before `exec` is how `nohup` works: `execve` resets caught
    /// signals to their defaults but leaves **ignored** ones ignored, so the
    /// `sleep` that replaces the subshell inherits `SIG_IGN` for `SIGHUP`. Job
    /// control is off in a non-interactive `sh`, so the background subshell
    /// stays in the job's own process group — in the closure a group kill
    /// reaches, and outside the one a pid kill reaches.
    private static func job(reportingPIDTo pidPath: String) -> String {
        """
        (trap '' HUP; exec sleep 300) </dev/null >/dev/null 2>&1 &
        echo $! > \(pidPath)
        exec sleep 300
        """
    }

    @Test func teardownKillsAJobsProcessGroupNotJustItsLeader() async throws {
        let scratch = "/tmp/tbdgk-\(UUID().uuidString.prefix(8).lowercased())"
        try FileManager.default.createDirectory(
            atPath: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let pidPath = "\(scratch)/grandchild.pid"

        let fixture = try await HolderProcessFixture.start(
            command: Self.job(reportingPIDTo: pidPath))
        defer { fixture.tearDown() }

        var reported: Int32?
        _ = await pollUntil("the job to report its grandchild's pid", timeout: 15.0) {
            reported = readReportedPID(at: pidPath)
            return reported != nil
        }
        let grandchild = try #require(reported, "the job never reported a grandchild pid")

        // Killed by pid on every exit from here, including a failed assertion —
        // unless the teardown under test has been *observed* to have killed it,
        // because the pid number is free the instant it dies and on this box the
        // next process to take it is somebody else's.
        var observedGone = false
        defer {
            if !observedGone, holderProcessIsAlive(grandchild) {
                kill(grandchild, SIGKILL)
            }
        }

        // The premise the fix rests on: the survivor is *in the job's group*, so
        // a group kill is enough to reach it. A deliberate escapee (`setsid`, a
        // double fork) is out of scope by design.
        #expect(
            getpgid(grandchild) == fixture.handle.childPID,
            """
            the grandchild is in process group \(getpgid(grandchild)), not the job's group \
            \(fixture.handle.childPID); this test would then be measuring an escapee rather than \
            the group kill
            """)

        // And the property that makes the measurement discriminating, asserted
        // rather than assumed: a grandchild that still dies of `SIGHUP` would
        // die of the pty close alone and pass against the bug.
        kill(grandchild, SIGHUP)
        try await Task.sleep(for: .milliseconds(300))
        #expect(
            holderProcessIsAlive(grandchild),
            "the grandchild died of SIGHUP, so it cannot discriminate a group kill from a hang-up")

        // The spawner's handshake connection is the holder's one client slot,
        // and an adoption needs it free.
        await fixture.client.close()
        let registry = HolderRegistry(
            owner: fixture.owner,
            environment: HolderProcessFixture.environment(home: fixture.home),
            listTerminals: { [] },
            // A holder learns the previous client has gone on its next poll
            // slice; the production-sized default is not what this measures.
            busyRetryBudget: .seconds(5))
        defer { releaseInBackground(registry) }
        _ = try await registry.adopt(terminal: holderTerminal(id: fixture.sessionID))

        await registry.abandon(terminalID: fixture.sessionID, handle: fixture.handle)

        let reclaimed = await pollUntil("the grandchild to be reclaimed", timeout: 10.0) {
            !holderProcessIsAlive(grandchild)
        }
        #expect(
            reclaimed,
            """
            grandchild pid \(grandchild) outlived the teardown of session \
            \(fixture.sessionID.uuidString) as \(holderProcessState(grandchild) ?? "gone"); every \
            session whose job ignores SIGHUP would leak one, and no sweep covers holder rows
            """)
        if reclaimed { observedGone = true }
    }

    // MARK: - Support

    private func readReportedPID(at path: String) -> Int32? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A holder-transport row. `tmuxWindowID`/`tmuxPaneID` are empty because
    /// those columns are NOT NULL from the v1 schema and a holder row has no
    /// tmux coordinate to put in them.
    private func holderTerminal(id: UUID) -> Terminal {
        Terminal(
            id: id, worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "", transport: .holder)
    }
}

/// Releases a registry's readers from a `defer`, which cannot `await`.
/// A reader left running leaks its drain thread and a pty descriptor for the
/// rest of the suite.
private func releaseInBackground(_ registry: HolderRegistry) {
    Task.detached { await registry.releaseAll() }
}
