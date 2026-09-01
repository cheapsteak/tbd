import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The row-less holder sweep against **real holder processes**.
///
/// Three cases, and the whole safety argument rests on them being three rather
/// than one. Each spawns a genuine `TBDHolder` through the real `HolderSpawner`,
/// forked onto a real pty, and then reads the kernel's view of the result:
///
///   - a holder this installation owns, past the grace window, claimed by no
///     session row → the child **and** the holder are gone;
///   - the same holder with a different owner token in the `config` row → still
///     running, because a completed handshake proves liveness, not ownership;
///   - the same holder with the *same* owner token but its one client slot
///     already taken → still running, because a rejected connection is terminal
///     in both directions.
///
/// The last two are what make the first one safe to ship. Nothing in an
/// injected-handshake test can prove a real holder refuses a real second client,
/// nor that a real `SIGKILL` reached a real process group.
///
/// **Tier 3**, and serialized: it spawns processes, waits on bounded deadlines,
/// and would not survive the parallel pass.
@Suite(.serialized)
struct OrphanGCRowlessHolderLiveTests {

    /// A job that simply waits to be killed. It writes nothing to the pty, so
    /// nothing here can die of a full terminal buffer instead of the kill.
    private static let job = "exec sleep 300"

    /// The sweep, pointed at the fixture's own holders directory and running the
    /// **production** handshake and killer — the two pieces this suite exists to
    /// exercise, so neither may be injected.
    ///
    /// `now` is pushed a day ahead so the freshly bound socket reads as older
    /// than the GC grace window. The alternative — sleeping out a real grace
    /// window — measures the clock, not the sweep.
    private func makeGC(db: TBDDatabase, home: String) -> OrphanGC {
        let horizon = Date().addingTimeInterval(86_400)
        return OrphanGC(
            db: db, git: GitManager(),
            broadcast: { _ in },
            liveCWDsProvider: { [] },
            scratchpadBase: URL(fileURLWithPath: home + "/s", isDirectory: true),
            now: { horizon },
            profileDirBase: URL(fileURLWithPath: home + "/p", isDirectory: true),
            holdersBase: TBDConstants.holdersDir(
                environment: HolderProcessFixture.environment(home: home)))
    }

    private func armedDatabase(owner: String) async throws -> TBDDatabase {
        let db = try TBDDatabase(inMemory: true)
        _ = try await db.config.ensureHolderOwnerToken(minting: owner)
        try await db.config.setGCRowlessHoldersEnabled(true)
        return db
    }

    private func socketPath(home: String, session: UUID) -> String {
        TBDConstants.holdersDir(environment: HolderProcessFixture.environment(home: home))
            .appendingPathComponent("\(session.uuidString.lowercased()).sock").path
    }

    // MARK: - The kill

    /// **The discriminating test.** A live holder we own, claimed by no session
    /// row, is reclaimed child-first — and both pids are really gone afterwards.
    ///
    /// Asserted on the process table rather than on a return value: the sweep
    /// reporting `reaped` proves it believed it killed something.
    @Test func aRowlessHolderWeOwnIsKilledChildAndAll() async throws {
        let fixture = try await HolderProcessFixture.start(command: Self.job)
        defer { fixture.tearDown() }
        let holderPID = fixture.handle.holderPID
        let childPID = fixture.handle.childPID

        // The premise, asserted rather than assumed: both are running before the
        // sweep, so their absence afterwards can only be the sweep's doing.
        #expect(holderProcessIsAlive(holderPID))
        #expect(holderProcessIsAlive(childPID))

        // The spawner's handshake connection is the holder's one client slot,
        // and the sweep's probe needs it free — an occupied slot is the
        // `rejected` case, which is a different test.
        await fixture.client.close()

        let db = try await armedDatabase(owner: fixture.owner.rawValue)
        let result = await makeGC(db: db, home: fixture.home).sweep()

        #expect(result.planned.contains(
            "REAP rowless-holder \(socketPath(home: fixture.home, session: fixture.sessionID))"))
        #expect(result.reaped >= 1)

        let childGone = await pollUntil("the job to be killed", timeout: 10.0) {
            !holderProcessIsAlive(childPID)
        }
        #expect(childGone, "the holder's job survived the sweep")

        let holderGone = await pollUntil("the holder to be gone", timeout: 10.0) {
            holderProcessState(holderPID) == nil
        }
        #expect(holderGone, "the holder survived the sweep")
        // Only now: the pid number is free the instant its corpse is collected,
        // and the fixture must not signal it again.
        if holderGone { fixture.noteHolderReaped() }
    }

    // MARK: - The two holders that must survive

    /// A completed handshake is proof of **liveness, not ownership**. The
    /// default `TBD_HOME` is shared by every checkout on a machine, so a
    /// perfectly healthy foreign session presents exactly as "reachable and
    /// absent from my database". Only the owner token tells them apart.
    ///
    /// Identical to the kill test in every respect but the token in the `config`
    /// row.
    @Test func aHolderWithADifferentOwnerTokenIsLeftRunning() async throws {
        let fixture = try await HolderProcessFixture.start(command: Self.job)
        defer { fixture.tearDown() }
        let holderPID = fixture.handle.holderPID
        let childPID = fixture.handle.childPID

        // Free, so the handshake really completes and `foreign-owner` is the
        // only thing standing between this holder and a kill.
        await fixture.client.close()

        let db = try await armedDatabase(owner: "a-different-checkout")
        let result = await makeGC(db: db, home: fixture.home).sweep()

        #expect(result.planned.contains(
            "KEEP foreign-owner \(socketPath(home: fixture.home, session: fixture.sessionID))"))
        #expect(holderProcessIsAlive(holderPID), "a foreign holder was killed")
        #expect(holderProcessIsAlive(childPID), "a foreign holder's job was killed")
        #expect(result.reaped == 0)
    }

    /// **A rejected connection is terminal in both directions** — not exited,
    /// and not killed either. The holder serves one client at a time and answers
    /// a second with the busy sentinel; a stale daemon from a different checkout
    /// is exactly what that looks like from here, and it is a known hazard on a
    /// development machine.
    ///
    /// The owner token matches, so ownership cannot be what saves this holder:
    /// the refusal is.
    @Test func aHolderThatRefusesTheConnectionIsLeftRunning() async throws {
        let fixture = try await HolderProcessFixture.start(command: Self.job)
        defer { fixture.tearDown() }
        let holderPID = fixture.handle.holderPID
        let childPID = fixture.handle.childPID

        // Deliberately NOT closed: the spawner's handshake connection keeps the
        // single client slot, so the sweep's probe is refused.
        let refused = try await HolderClient(
            socketPath: socketPath(home: fixture.home, session: fixture.sessionID),
            receiveTimeout: .seconds(5)
        ).describeExpectingRefusal()
        #expect(refused, "the fixture must be occupying the holder's client slot")

        let db = try await armedDatabase(owner: fixture.owner.rawValue)
        let result = await makeGC(db: db, home: fixture.home).sweep()

        #expect(result.planned.contains(
            "KEEP rejected \(socketPath(home: fixture.home, session: fixture.sessionID))"))
        #expect(holderProcessIsAlive(holderPID), "a holder that refused us was killed")
        #expect(holderProcessIsAlive(childPID), "a refusing holder's job was killed")
        #expect(result.reaped == 0)
    }
}

private extension HolderClient {
    /// Whether this holder answers a second client with the busy sentinel.
    ///
    /// Used to assert the *premise* of the refusal test rather than its
    /// conclusion: without this, a holder that had quietly freed its slot would
    /// make the test pass for the wrong reason.
    func describeExpectingRefusal() async throws -> Bool {
        defer { close() }
        do {
            _ = try await describe()
            return false
        } catch HolderClient.Error.rejected {
            return true
        }
    }
}
