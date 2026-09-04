import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The gates that stop the row sweep judging a session somebody still holds —
/// and the probe that no longer destroys the screen it exists to preserve.
///
/// `HolderReconcileInventoryTests` covers the classification with pinned
/// answers and no holder at all. These four need registry state that only a
/// real hand-over produces: a viewer owning the pty, a live reader draining it,
/// a status collected from a holder that has since wound down. There is no seam
/// that fakes any of them, and each is a gate whose deletion would let the
/// sweep delete a row out from under a live session.
///
/// **Tier 3.** A real `TBDHolder`, a real pty, and a real job.
@Suite(.serialized)
struct HolderReconcileGateTests {

    // MARK: - Gate 2: a viewer owning the pty ends it

    /// After `confirmAttach` the app holds the descriptor and the daemon has no
    /// reader at all, so every probe below this gate would be asking about a
    /// session somebody is looking at right now.
    @Test func aViewerHoldingTheDescriptorEndsTheQuestioning() async throws {
        let fixture = try await HolderProcessFixture.start(command: "sleep 120")
        defer { fixture.tearDown() }
        await fixture.client.close()

        let registry = makeRegistry(owner: fixture.owner, home: fixture.home)
        defer { releaseInBackground(registry) }
        _ = try await registry.adopt(terminal: holderTerminal(id: fixture.sessionID))

        let vend = try await registry.beginAttach(terminalID: fixture.sessionID)
        defer { close(vend.ptyFD) }
        try await registry.confirmAttach(
            terminalID: fixture.sessionID, generation: vend.generation)

        let verdict = await (try makeLifecycle(registry: registry))
            .holderRowVerdict(for: holderTerminal(id: fixture.sessionID))
        #expect(
            verdict == .keep(reason: "viewer-attached"),
            """
            the sweep judged a session whose pty a viewer owns: \
            \(String(describing: verdict))
            """)
    }

    // MARK: - Gate 3: a live reader ends it

    /// The daemon is draining this pty right now. The gate stays true after the
    /// job exits, deliberately — a drained screen is a readable gravestone that
    /// `reclaimIfSessionEnded` owns, not this sweep.
    @Test func aLiveReaderEndsTheQuestioning() async throws {
        let fixture = try await HolderProcessFixture.start(command: "sleep 120")
        defer { fixture.tearDown() }
        await fixture.client.close()

        let registry = makeRegistry(owner: fixture.owner, home: fixture.home)
        defer { releaseInBackground(registry) }
        _ = try await registry.adopt(terminal: holderTerminal(id: fixture.sessionID))

        let verdict = await (try makeLifecycle(registry: registry))
            .holderRowVerdict(for: holderTerminal(id: fixture.sessionID))
        #expect(
            verdict == .keep(reason: "reader-live"),
            """
            the sweep judged a session this daemon is draining: \
            \(String(describing: verdict))
            """)
    }

    // MARK: - Gate 4: a recorded status is answered without a round trip

    /// A holder winds itself down the moment an answer carrying the status
    /// reaches a client, so by the time the reclaimer has released the reader
    /// there is nobody left at the rendezvous to ask. The remembered status is
    /// the only place the real exit code still exists — a probe at this point
    /// would answer `exitedStatusUnknown` and lose it.
    @Test func aRecordedExitIsAnsweredWithoutARoundTrip() async throws {
        // `sleep 1` so the job outlives the spawner's own handshake: a holder
        // whose child is already gone answers that handshake with the terminal
        // status and winds itself down, and the fixture would then be a
        // rendezvous nobody could adopt rather than the case under test.
        let fixture = try await HolderProcessFixture.start(command: "sleep 1; exit 7")
        defer { fixture.tearDown() }
        await fixture.client.close()

        #expect(await pollUntil("the job to finish exiting") {
            !holderProcessIsAlive(fixture.handle.childPID)
        })

        let registry = makeRegistry(owner: fixture.owner, home: fixture.home)
        defer { releaseInBackground(registry) }
        _ = try await registry.adopt(terminal: holderTerminal(id: fixture.sessionID))
        #expect(await pollUntil("the reclaimer to release the finished session") {
            await registry.reader(for: fixture.sessionID) == nil
        })

        let verdict = await (try makeLifecycle(registry: registry))
            .holderRowVerdict(for: holderTerminal(id: fixture.sessionID))
        #expect(
            verdict == .sessionOver(.exited(code: 7)),
            """
            a status this daemon had already collected was re-derived from the \
            rendezvous and lost its exit code: \(String(describing: verdict))
            """)
    }

    // MARK: - The probe that asks nothing

    /// **The sweep must not ask a question whose answer would destroy the
    /// screen.** A holder winds itself down the moment an answer carrying the
    /// terminal status reaches a client, which is why adoption asks for the
    /// hand-over rather than a description and why
    /// `HolderRegistry.confirmChildExit` may only describe past the exhausted
    /// edge. A row this daemon has never taken the master of is on the wrong
    /// side of that rule, and the reconcile pass at startup meets every row in
    /// exactly that state.
    ///
    /// So an un-adopted row is probed by *connecting*, and the reason string is
    /// the discriminator: a `describe` against this fixture would answer, and
    /// the verdict would read `alive` rather than `listening`. The rest asserts
    /// the consequence — the holder is still standing afterwards and its screen
    /// is still there to hand over.
    @Test func anUnadoptedRowIsProbedWithoutBeingAskedAnything() async throws {
        let fixture = try await HolderProcessFixture.start(
            command: "printf 'LAST-SCREEN\\n'; sleep 120")
        defer { fixture.tearDown() }
        await fixture.client.close()

        // Nothing has been adopted, so the registry remembers nothing about
        // this row — which is exactly the state the startup sweep meets.
        let registry = makeRegistry(owner: fixture.owner, home: fixture.home)
        defer { releaseInBackground(registry) }
        #expect(await registry.lastKnownStatus(for: fixture.sessionID) == nil)

        let verdict = await (try makeLifecycle(registry: registry))
            .holderRowVerdict(for: holderTerminal(id: fixture.sessionID))
        #expect(
            verdict == .keep(reason: "listening"),
            """
            an un-adopted row was described rather than merely connected to: \
            \(String(describing: verdict))
            """)
        #expect(
            holderProcessIsAlive(fixture.handle.holderPID),
            "the sweep's probe wound the holder down before anybody took its pty")

        let reader = try await registry.adopt(terminal: holderTerminal(id: fixture.sessionID))
        #expect(await pollUntil("the screen the probe left alone to reach the emulator") {
            await reader.renderScreen().contains("LAST-SCREEN")
        })
    }

    // MARK: - Support

    /// A holder-transport row with **no recorded child pid**, so the last gate
    /// — "a row whose job is still running is kept" — never reaches the process
    /// table. A fixture pid handed to the production signaller would be asking
    /// about whatever the developer's machine had reused it for.
    private func holderTerminal(id: UUID) -> Terminal {
        Terminal(
            id: id, worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "", transport: .holder)
    }

    private func makeRegistry(owner: HolderOwnerToken, home: String) -> HolderRegistry {
        HolderRegistry(
            owner: owner,
            environment: HolderProcessFixture.environment(home: home),
            listTerminals: { [] })
    }

    /// A lifecycle that exists only to carry the registry into
    /// `holderRowVerdict(for:)`. Nothing here touches git, tmux or the
    /// database: the verdict is decided entirely by registry state and the
    /// rendezvous.
    private func makeLifecycle(registry: HolderRegistry) throws -> WorktreeLifecycle {
        var lifecycle = WorktreeLifecycle(
            db: try TBDDatabase(inMemory: true), git: GitManager(),
            tmux: TmuxManager(dryRun: true), hooks: HookResolver())
        lifecycle.holderRegistry = registry
        return lifecycle
    }
}

/// Releases a registry's readers from a `defer`, which cannot `await`.
private func releaseInBackground(_ registry: HolderRegistry) {
    Task.detached { await registry.releaseAll() }
}
