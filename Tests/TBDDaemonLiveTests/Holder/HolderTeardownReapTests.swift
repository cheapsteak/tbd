import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// What a holder teardown leaves behind in the daemon's own process table.
///
/// A holder is `posix_spawn`ed by the daemon, so it is the daemon's child and
/// nobody else can collect it. Teardown told it to `forget` and killed the job,
/// which is everything the *outside* world needed — and left a corpse in the
/// daemon's process table for every session ever torn down, until the daemon
/// itself exited. The spawner's never-bound failure path already reaps for
/// exactly this reason (`HolderSpawner.resolveUnreachableHolder`); this is the
/// same obligation on the path that runs every time.
///
/// **Tier 3.** It spawns a real `TBDHolder` through the real `HolderSpawner` and
/// reads the kernel's view of a real pid.
@Suite(.serialized)
struct HolderTeardownReapTests {

    @Test func teardownReapsTheHolderItSpawned() async throws {
        let fixture = try await HolderProcessFixture.start(command: "sleep 30")
        defer { fixture.tearDown() }
        // The spawner's handshake connection is the holder's one client slot,
        // and an adoption needs it free.
        await fixture.client.close()

        let registry = HolderRegistry(
            owner: fixture.owner,
            environment: HolderProcessFixture.environment(home: fixture.home),
            listTerminals: { [] },
            // A holder learns the previous client has gone on its next poll
            // slice, and until then it answers the busy sentinel. The default
            // budget is sized for production, where that is one slice; this test
            // runs on a box that may be running dozens of other sessions, and
            // waiting out that window is not what it is measuring.
            busyRetryBudget: .seconds(5))
        defer { releaseInBackground(registry) }
        _ = try await registry.adopt(terminal: holderTerminal(id: fixture.sessionID))

        await registry.abandon(terminalID: fixture.sessionID, handle: fixture.handle)

        // `kill(pid, 0)` cannot answer this: a zombie answers it happily. Only
        // the pid naming nothing at all means the corpse was collected.
        let reaped = await pollUntil("the holder pid to be reaped", timeout: 10.0) {
            holderProcessState(fixture.handle.holderPID) == nil
        }
        #expect(
            reaped,
            """
            the holder was left as \(holderProcessState(fixture.handle.holderPID) ?? "gone") after \
            teardown; every session ever torn down would leave one
            """)
        // Only once the reap is observed, and never otherwise: the pid number is
        // free the instant its corpse is collected, so `tearDown` must not go on
        // to signal it.
        if reaped { fixture.noteHolderReaped() }
    }

    // MARK: - Support

    /// A holder-transport row. `tmuxWindowID`/`tmuxPaneID` are empty because
    /// those columns are NOT NULL from the v1 schema and a holder row has no
    /// tmux coordinate to put in them.
    private func holderTerminal(id: UUID) -> Terminal {
        Terminal(
            id: id, worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "", transport: .holder)
    }
}

/// Releases a registry's readers from a `defer`, which cannot `await`.
/// Idempotent, and a reader left running leaks its drain thread and a pty
/// descriptor for the rest of the suite.
private func releaseInBackground(_ registry: HolderRegistry) {
    Task.detached { await registry.releaseAll() }
}
