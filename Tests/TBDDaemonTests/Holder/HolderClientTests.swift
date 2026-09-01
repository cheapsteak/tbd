import Clocks
import Darwin
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The daemon-side half of the holder rendezvous, driven against real holder
/// processes spawned through the real `HolderSpawner`.
///
/// Four rules shape the suite, each one a bug it would otherwise ship:
///
///   1. **Every wait is a bounded poll.** A holder that wedges must fail a test
///      with a named diagnostic, not hang the suite with no output.
///   2. **Every bootstrap is rc-free.** `/bin/sh` with an explicit environment,
///      never a login shell — a developer's profile must not decide whether a
///      test passes.
///   3. **Every test kills its holder AND its job.** Holder death is
///      deliberately not child death, so a test that terminates a holder
///      orphans a `sleep` that no reconciler covers yet.
///   4. **No `setenv`.** The rendezvous paths come from an explicit environment
///      dictionary handed to `spawn`, so nothing here can reach the developer's
///      real `~/tbd` even for an instant.
@Suite(.serialized)
struct HolderClientTests {

    // MARK: - Spawning

    @Test func spawnsAHolderAndDescribesItsChild() async throws {
        let fixture = try await SpawnedHolderFixture.start(command: "sleep 30")
        defer { fixture.tearDown() }

        #expect(fixture.handle.childPID > 0)
        #expect(fixture.handle.holderPID > 0)
        #expect(processIsAlive(fixture.handle.childPID))
        #expect(processIsAlive(fixture.handle.holderPID))

        // The spawner hands its handshake connection on, so the holder is
        // already attached and answering before the caller asks anything —
        // which is what every later daemon-side consumer relies on.
        let description = try await fixture.client.describe()
        #expect(description.childPID == fixture.handle.childPID)
        #expect(description.status == .alive)
        #expect(description.ttyName.hasPrefix("/dev/"))
        // `--owner` is passed through as given: it names the installation, not
        // the process, so a restarted daemon still recognises its own holders.
        #expect(description.owner == fixture.owner)
    }

    @Test func handsOverAReadablePTY() async throws {
        let fixture = try await SpawnedHolderFixture.start(command: "printf HOLDER-OK; sleep 30")
        defer { fixture.tearDown() }

        // Straight onto the spawner's own connection, with no reconnect in
        // between. This used to dial the socket again and fail about one run in
        // five with the busy sentinel, because the holder had not yet read EOF
        // on the connection the spawner closed a moment earlier.
        let (description, ptyFD) = try await fixture.client.handOverPTY()
        defer { Darwin.close(ptyFD) }
        await fixture.client.close()
        #expect(description.childPID == fixture.handle.childPID)
        #expect(ptyFD >= 0)

        var seen = Data()
        let sawMarker = waitUntilTrue("the job's output on the handed-over pty") {
            drainPTYInto(ptyFD, &seen)
            return String(decoding: seen, as: UTF8.self).contains("HOLDER-OK")
        }
        #expect(sawMarker, "read \(seen.count) bytes: \(String(decoding: seen, as: UTF8.self).debugDescription)")
    }

    /// Handing the handshake connection on must not soften the busy sentinel.
    ///
    /// The sentinel is the only thing standing between one pty master and two
    /// readers, and "two readers" is silent byte theft rather than an error
    /// anyone would notice. So the fix for the spawn race is checked against
    /// its opposite: while the spawner's connection is genuinely attached, a
    /// second client is refused — and once that connection is let go, the slot
    /// really does become free, which is what makes the refusal a statement
    /// about occupancy rather than a permanent lockout.
    @Test func refusesASecondClientWhileTheSpawnersConnectionIsHeld() async throws {
        let fixture = try await SpawnedHolderFixture.start(command: "sleep 30")
        defer { fixture.tearDown() }

        // Not merely constructed: a round trip proves the spawner's connection
        // is the live one occupying the holder's single slot.
        let held = try await fixture.client.describe()
        #expect(held.status == .alive)

        let second = HolderClient(socketPath: fixture.handle.socketPath, receiveTimeout: .seconds(5))
        await #expect(throws: HolderClient.Error.rejected(version: HolderProtocolVersion.busySentinel)) {
            _ = try await second.describe()
        }
        await second.close()

        // The other half: the refusal tracks occupancy. Polled rather than
        // asserted once, because the holder learns the slot is free only when
        // its poll loop next reads EOF — the very latency that made a
        // reconnecting caller flaky, here waited out on purpose.
        await fixture.client.close()
        let socketPath = fixture.handle.socketPath
        let reattached = await pollUntil("the holder to free its client slot") {
            let probe = HolderClient(socketPath: socketPath, receiveTimeout: .seconds(5))
            let answered = (try? await probe.describe()) != nil
            await probe.close()
            return answered
        }
        #expect(reattached, "the holder never freed its client slot")
    }

    // MARK: - The creation lock

    /// The regression test for the exact hazard the lock exists to prevent.
    ///
    /// A socket file cannot distinguish a live holder from the corpse of a
    /// SIGKILLed one, so "unlink the stale socket, then bind" is a race two
    /// spawners can both win. A spawner that cannot take the lock has already
    /// learned a live holder owns this UUID and must touch nothing.
    @Test func refusesToClearASocketWhoseLockIsHeld() async throws {
        let home = SpawnedHolderFixture.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let environment = SpawnedHolderFixture.environment(home: home)
        try FileManager.default.createDirectory(
            atPath: TBDConstants.holdersDir(environment: environment).path,
            withIntermediateDirectories: true)

        let session = UUID()
        let socketPath = try HolderRendezvous.socketPath(sessionID: session, environment: environment)
        let lockPath = try HolderRendezvous.lockPath(sessionID: session, environment: environment)

        // Stand in for a live holder's bound socket. What matters to the
        // assertion is only that *something* occupies the path.
        try Data("not really a socket".utf8).write(to: URL(fileURLWithPath: socketPath))

        let lock = try HolderLock.acquire(path: lockPath)
        defer { lock.release() }

        let spawner = try SpawnedHolderFixture.makeSpawner()
        var thrown: Swift.Error?
        do {
            _ = try await spawner.spawn(
                sessionID: session,
                launch: SpawnedHolderFixture.launch(command: "sleep 30", home: home),
                owner: HolderOwnerToken(rawValue: "acme-installation"),
                environment: environment)
        } catch {
            thrown = error
        }

        guard case .lockHeldByLiveHolder(let reported, _)? = thrown as? HolderSpawner.Error else {
            Issue.record("expected .lockHeldByLiveHolder, got \(String(describing: thrown))")
            return
        }
        #expect(reported == session)
        // The other half of the assertion, and the one that actually guards the
        // hazard: the pre-existing socket is still there, byte for byte.
        #expect(FileManager.default.fileExists(atPath: socketPath))
        let survivor = try? Data(contentsOf: URL(fileURLWithPath: socketPath))
        #expect(survivor == Data("not really a socket".utf8))
    }

    /// The other half of the lock's contract, and the branch the held-lock test
    /// above never reaches: a socket with **no** lock file beside it.
    ///
    /// Absence of a lock is not evidence of absence of a holder — `flock` lives
    /// on the open file description, so a holder whose lock file was swept out
    /// from under it keeps the lock while the path is free for anyone to
    /// recreate. A spawner that read "no lock file" as "no holder" would unlink
    /// a live session's rendezvous. The probe is what stops it.
    @Test func refusesToClearASocketAnAliveHolderStillAnswers() async throws {
        let fixture = try await SpawnedHolderFixture.start(command: "sleep 30")
        defer { fixture.tearDown() }
        let environment = SpawnedHolderFixture.environment(home: fixture.home)
        let lockPath = try HolderRendezvous.lockPath(
            sessionID: fixture.sessionID, environment: environment)

        // Sweep the lock file. The live holder keeps its lock; the path is now
        // free, so the next spawner takes a *different* one and learns nothing
        // from having got it.
        try FileManager.default.removeItem(atPath: lockPath)

        let spawner = try SpawnedHolderFixture.makeSpawner()
        var thrown: Swift.Error?
        do {
            _ = try await spawner.spawn(
                sessionID: fixture.sessionID,
                launch: SpawnedHolderFixture.launch(command: "sleep 30", home: fixture.home),
                owner: fixture.owner,
                environment: environment)
        } catch {
            thrown = error
        }

        guard case .lockHeldByLiveHolder? = thrown as? HolderSpawner.Error else {
            Issue.record("expected .lockHeldByLiveHolder, got \(String(describing: thrown))")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fixture.handle.socketPath))
        #expect(processIsAlive(fixture.handle.holderPID))

        // The assertion that matters: the session the probe protected is still
        // usable, not merely still on disk.
        let description = try await fixture.client.describe()
        #expect(description.childPID == fixture.handle.childPID)
        #expect(description.status == .alive)
    }

    /// The branch that *does* license clearing: a bound path whose server is
    /// gone answers `ECONNREFUSED`, and nothing is left to protect.
    ///
    /// The holder that gets launched here never binds, so the spawn fails — and
    /// that is what makes the assertion direct. A real holder unlinks the path
    /// itself before binding, which would leave "the socket is gone" true no
    /// matter what the spawner decided.
    @Test func clearsASocketWhoseListenerIsGone() async throws {
        let home = SpawnedHolderFixture.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let environment = SpawnedHolderFixture.environment(home: home)
        try FileManager.default.createDirectory(
            atPath: TBDConstants.holdersDir(environment: environment).path,
            withIntermediateDirectories: true)

        let session = UUID()
        let socketPath = try HolderRendezvous.socketPath(sessionID: session, environment: environment)
        // Bind, listen, close: the socket file survives its server, which is
        // exactly what a SIGKILLed holder leaves behind.
        Darwin.close(try bindUnixListener(at: socketPath, backlog: 4))
        try #require(FileManager.default.fileExists(atPath: socketPath))

        let spawner = HolderSpawner(
            executableURL: try SpawnedHolderFixture.writeNeverBindingHolder(into: home),
            bindTimeout: .milliseconds(200),
            bindPollInterval: .milliseconds(20),
            handshakeTimeout: .milliseconds(50))
        var thrown: Swift.Error?
        do {
            _ = try await spawner.spawn(
                sessionID: session,
                launch: SpawnedHolderFixture.launch(command: "sleep 30", home: home),
                owner: HolderOwnerToken(rawValue: "acme-installation"),
                environment: environment)
        } catch {
            thrown = error
        }

        guard case .holderDidNotBind? = thrown as? HolderSpawner.Error else {
            Issue.record("expected .holderDidNotBind, got \(String(describing: thrown))")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    /// Every other errno must NOT license clearing: an unreadable socket is not
    /// a dead one.
    ///
    /// A regular file at the rendezvous path answers `connect` with `ENOTSOCK`,
    /// which is neither of the two answers that mean "nothing is listening". A
    /// spawner that treated any failed connect as permission to unlink would
    /// destroy whatever that path really is.
    @Test func refusesToClearAPathThatIsNotASocket() async throws {
        let home = SpawnedHolderFixture.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let environment = SpawnedHolderFixture.environment(home: home)
        try FileManager.default.createDirectory(
            atPath: TBDConstants.holdersDir(environment: environment).path,
            withIntermediateDirectories: true)

        let session = UUID()
        let socketPath = try HolderRendezvous.socketPath(sessionID: session, environment: environment)
        let contents = Data("not really a socket".utf8)
        try contents.write(to: URL(fileURLWithPath: socketPath))

        let spawner = try SpawnedHolderFixture.makeSpawner()
        var thrown: Swift.Error?
        do {
            _ = try await spawner.spawn(
                sessionID: session,
                launch: SpawnedHolderFixture.launch(command: "sleep 30", home: home),
                owner: HolderOwnerToken(rawValue: "acme-installation"),
                environment: environment)
        } catch {
            thrown = error
        }

        guard case .lockHeldByLiveHolder? = thrown as? HolderSpawner.Error else {
            Issue.record("expected .lockHeldByLiveHolder, got \(String(describing: thrown))")
            return
        }
        #expect((try? Data(contentsOf: URL(fileURLWithPath: socketPath))) == contents)
    }

    // MARK: - Forget

    @Test func forgetStopsReporting() async throws {
        let fixture = try await SpawnedHolderFixture.start(command: "sleep 30")
        defer { fixture.tearDown() }
        let childPID = fixture.handle.childPID

        try await fixture.client.forget()
        await fixture.client.close()

        // A forgotten holder has nothing left to say, so it drops its pty and
        // exits, unlinking the socket on the way out.
        //
        // Exit is observed by reaping rather than by `kill(pid, 0)`: the holder
        // is this process's own child, so until somebody waits on it, it is a
        // zombie — and a zombie answers signal-zero exactly like a live process.
        #expect(fixture.reapHolder(), "the forgotten holder never exited")
        #expect(waitUntilTrue("the holder socket to be unlinked") {
            !FileManager.default.fileExists(atPath: fixture.handle.socketPath)
        })

        let reconnect = HolderClient(socketPath: fixture.handle.socketPath, receiveTimeout: .seconds(1))
        await #expect(throws: HolderClient.Error.self) {
            _ = try await reconnect.describe()
        }
        await reconnect.close()

        // And the job can be killed without anything resurrecting it — the
        // whole point of `forget` (iTerm2's preemptive wait, adopted for the
        // same reason).
        kill(childPID, SIGKILL)
        #expect(waitUntilTrue("the forgotten job to die") { !processIsAlive(childPID) })
    }

    // MARK: - The bind budget

    /// Proves the budget runs on the **injected** clock: the fake executable
    /// exits before it could bind anything, and the spawn only gives up once
    /// virtual time is advanced past `bindTimeout`. On wall time this test
    /// would take 200 ms of real waiting; on a `TestClock` it takes none, and a
    /// spawner that consulted `ContinuousClock` instead could not pass inside
    /// the helper's own real-time guard.
    @Test func spawnTimesOutIfTheHolderNeverBinds() async throws {
        let home = SpawnedHolderFixture.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let environment = SpawnedHolderFixture.environment(home: home)

        let clock = TestClock<Duration>()
        let spawner = HolderSpawner(
            // Exits immediately and binds nothing. `/usr/bin/true` rather than a
            // written script so nothing about the fixture's own file creation
            // can be what the test measures.
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            bindTimeout: .milliseconds(200),
            bindPollInterval: .milliseconds(20),
            clock: clock)

        let outcome = ResultBox()
        let task = Task {
            do {
                _ = try await spawner.spawn(
                    sessionID: UUID(),
                    launch: SpawnedHolderFixture.launch(command: "sleep 30", home: home),
                    owner: HolderOwnerToken(rawValue: "acme-installation"),
                    environment: environment)
                outcome.finish(nil)
            } catch {
                outcome.finish(error)
            }
        }

        let ranOut = await clock.advanceUntil("the bind budget to run out", by: .milliseconds(20)) {
            outcome.isFinished
        }
        #expect(ranOut)
        await task.value

        guard case .holderDidNotBind? = outcome.error as? HolderSpawner.Error else {
            Issue.record("expected .holderDidNotBind, got \(String(describing: outcome.error))")
            return
        }
    }

    /// A holder that never created its socket is killed, and that is the *only*
    /// state in which killing is licensed.
    ///
    /// `Holder.run()` binds and listens before it `forkpty`s and only ever
    /// `accept`s from inside `serve()`, after the fork — so an absent socket is
    /// proof no job exists to orphan. Leaving such a holder alive would be the
    /// real hazard: it holds the creation lock, and this session UUID could
    /// then never be spawned or reclaimed again.
    ///
    /// The fake holder stays alive on purpose. A stand-in that exited by itself
    /// would leave the same "process is gone" observation whether the spawner
    /// killed it or not.
    @Test func killsAHolderThatNeverCreatedItsSocket() async throws {
        let home = SpawnedHolderFixture.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let environment = SpawnedHolderFixture.environment(home: home)

        let spawner = HolderSpawner(
            executableURL: try SpawnedHolderFixture.writeNeverBindingHolder(into: home),
            bindTimeout: .milliseconds(200),
            bindPollInterval: .milliseconds(20),
            handshakeTimeout: .milliseconds(50))
        var thrown: Swift.Error?
        do {
            _ = try await spawner.spawn(
                sessionID: UUID(),
                launch: SpawnedHolderFixture.launch(command: "sleep 30", home: home),
                owner: HolderOwnerToken(rawValue: "acme-installation"),
                environment: environment)
        } catch {
            thrown = error
        }

        guard case .holderDidNotBind(let holderPID, _, _)? = thrown as? HolderSpawner.Error else {
            Issue.record("expected .holderDidNotBind, got \(String(describing: thrown))")
            return
        }
        // Reaped as well as killed, so nothing is signallable: the holder is
        // the spawner's own child, and an unreaped corpse answers `kill(pid, 0)`
        // exactly like a live process.
        defer { reapIfAlive(holderPID) }
        #expect(holderPID > 0)
        #expect(!processIsAlive(holderPID))
    }

    /// A holder that DID create its socket must survive the failed spawn.
    ///
    /// Binding happens before `forkpty`, so a holder that got this far may
    /// already be supervising a job — and the loaded machine that made it miss
    /// the budget is exactly when that is most likely. Milestone A has no
    /// holder reconciler, so a blind kill here orphans that job permanently and
    /// erases the only evidence of it. The spawn still fails; what it must
    /// carry is enough to find what it left behind.
    ///
    /// The state is built the way it really occurs rather than by racing a real
    /// holder into wedging: a listener that accepts and never answers, and a
    /// stand-in process that stays alive. The unheld lock file is what steers
    /// `spawn` past the probe-and-unlink branch so the listener is still there
    /// when the holder is launched.
    @Test func leavesAHolderThatBoundButNeverAnsweredAlive() async throws {
        let home = SpawnedHolderFixture.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let environment = SpawnedHolderFixture.environment(home: home)
        try FileManager.default.createDirectory(
            atPath: TBDConstants.holdersDir(environment: environment).path,
            withIntermediateDirectories: true)

        let session = UUID()
        let socketPath = try HolderRendezvous.socketPath(sessionID: session, environment: environment)
        let lockPath = try HolderRendezvous.lockPath(sessionID: session, environment: environment)
        try HolderLock.acquire(path: lockPath).release()

        // Bound and listening, never accepting: connects succeed from the
        // backlog and no request is ever answered.
        let listener = try bindUnixListener(at: socketPath, backlog: 64)
        defer {
            Darwin.close(listener)
            unlink(socketPath)
        }

        let spawner = HolderSpawner(
            executableURL: try SpawnedHolderFixture.writeNeverBindingHolder(into: home),
            bindTimeout: .milliseconds(200),
            bindPollInterval: .milliseconds(20),
            handshakeTimeout: .milliseconds(50))
        var thrown: Swift.Error?
        do {
            _ = try await spawner.spawn(
                sessionID: session,
                launch: SpawnedHolderFixture.launch(command: "sleep 30", home: home),
                owner: HolderOwnerToken(rawValue: "acme-installation"),
                environment: environment)
        } catch {
            thrown = error
        }

        guard case .holderBoundButUnresponsive(let holderPID, let reportedSocket, _)?
            = thrown as? HolderSpawner.Error else {
            Issue.record("expected .holderBoundButUnresponsive, got \(String(describing: thrown))")
            return
        }
        // This test owns the process now — nothing in the daemon reaps it.
        defer { reapIfAlive(holderPID) }
        #expect(holderPID > 0)
        #expect(reportedSocket == socketPath)
        #expect(processIsAlive(holderPID), "the spawner killed a holder that may have owned a job")
    }

    // MARK: - The pending-message queue

    /// One `recvmsg` routinely carries a response and the holder's unsolicited
    /// exit push together — the holder answers a request and reports a status
    /// microseconds apart, and the kernel coalesces them.
    ///
    /// A client that returned the first frame and dropped the tail would then
    /// have to read again for a message it had already been handed, and since a
    /// holder closes right after reporting an exit that read is an EOF: the
    /// caller gets "the peer closed" for a report that did arrive. That was a
    /// real load-dependent flake in the holder's own harness.
    ///
    /// The peer here is a stub rather than a real holder precisely so the
    /// coalescing is *arranged* instead of raced: it writes both frames in a
    /// single `write` and then answers nothing else ever. The push is nobody's
    /// answer — it is retired and surfaced as `lastPushedDescription` — but a
    /// client that decoded only the first frame and discarded the rest of the
    /// read would have lost the exit entirely.
    @Test func keepsAnExitPushCoalescedWithAnAnswerInsteadOfLosingIt() async throws {
        let home = SpawnedHolderFixture.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let socketPath = home + "/stub.sock"

        let alive = SpawnedHolderFixture.description(childPID: 4242, home: home)
        var exited = alive
        exited.status = .exited(code: 7)

        var coalesced = Data()
        coalesced += try HolderFraming.frame(HolderResponse.described(alive))
        coalesced += try HolderFraming.frame(HolderResponse.described(exited))

        let peer = try ScriptedStubPeer(
            socketPath: socketPath,
            answers: [ScriptedStubPeer.Answer(payload: coalesced)])
        defer { peer.tearDown() }

        let client = HolderClient(socketPath: socketPath, receiveTimeout: .seconds(2))
        let first = try await client.describe()
        #expect(first.status == .alive)
        #expect(first.childPID == 4242)

        // The discriminating half: the second frame arrived in the same read
        // and the stub has stopped writing, so anything known about the exit
        // now can only have come from that read.
        await client.close()
        let pushed = await client.lastPushedDescription
        #expect(pushed?.status == .exited(code: 7))
        #expect(pushed?.childPID == 4242)
    }

    /// The coalesced push must not become the **next** verb's answer.
    ///
    /// Mixing verbs across the push is what makes this visible: two `describe`s
    /// cannot, because `describe` accepts either frame shape and a stale
    /// `.described` therefore looks exactly like a correct reply. A hand-over
    /// followed by a `forget` cannot hide it — a queue served first-in-first-out
    /// answers the `forget` with the hand-over's trailing exit push, so the call
    /// throws `unexpectedResponse` for a verb the holder performed correctly,
    /// the real `.forgotten` is left on the wire for whatever asks next, and the
    /// connection never resynchronises.
    @Test func doesNotAnswerForgetWithTheHandOversCoalescedExitPush() async throws {
        let home = SpawnedHolderFixture.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let socketPath = home + "/stub.sock"

        let alive = SpawnedHolderFixture.description(childPID: 4242, home: home)
        var exited = alive
        exited.status = .exited(code: 7)

        // Stands in for the pty master. Any descriptor will do: what is under
        // test is which frame the client attributes to which request, not what
        // the transferred fd points at.
        let carried = open("/dev/null", O_RDWR)
        try #require(carried >= 0, "could not open a descriptor to hand over")
        defer { Darwin.close(carried) }

        let peer = try ScriptedStubPeer(
            socketPath: socketPath,
            answers: [
                // The hand-over's answer, with the exit push written straight
                // after it so both land in one read.
                ScriptedStubPeer.Answer(
                    descriptor: carried,
                    payload: try HolderFraming.frame(HolderResponse.handedOverPTY(alive)),
                    trailer: try HolderFraming.frame(HolderResponse.described(exited))),
                ScriptedStubPeer.Answer(payload: try HolderFraming.frame(HolderResponse.forgotten)),
            ])
        defer { peer.tearDown() }

        let client = HolderClient(socketPath: socketPath, receiveTimeout: .seconds(2))
        let (description, ptyFD) = try await client.handOverPTY()
        defer { Darwin.close(ptyFD) }
        #expect(description.status == .alive)
        #expect(ptyFD >= 0)

        // The assertion: `forget` is answered by the holder's `.forgotten`, not
        // by the exit push the hand-over left behind.
        try await client.forget()

        // And the push is not simply thrown away to achieve that.
        let pushed = await client.lastPushedDescription
        #expect(pushed?.status == .exited(code: 7))
        await client.close()
    }

    /// The same misattribution, from a push that never reached the queue.
    ///
    /// The coalesced case above is only half the hazard, and the easier half: a
    /// push that shared a read with the answer it trailed is already decoded,
    /// so draining the queue at send time is enough to retire it. The holder
    /// does not owe anyone that coincidence. It reaps its child on its own
    /// schedule, so the push can be written a moment *after* the client read
    /// its answer — and then it is sitting unread in the socket's receive
    /// buffer, where the queue cannot see it and where it is indistinguishable,
    /// on the next read, from that request's answer. Only a barrier that reaches
    /// the socket catches it.
    ///
    /// The ordering is arranged rather than raced, and in both directions,
    /// because a test that merely *hoped* the writes landed in separate reads
    /// would be the coalesced test again on a good day: the peer holds the push
    /// until `handOverPTY` has returned, and the test holds `forget` until the
    /// push has been written. Nothing reads that socket between those two
    /// points — `HolderClient` reads only from inside a verb — so the push is
    /// provably buffered and undecoded when the barrier runs.
    @Test func drainsAnExitPushStillBufferedInTheSocketBeforeTheNextRequest() async throws {
        let home = SpawnedHolderFixture.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let socketPath = home + "/stub.sock"

        let alive = SpawnedHolderFixture.description(childPID: 4242, home: home)
        var exited = alive
        exited.status = .exited(code: 7)

        // Stands in for the pty master, as in the coalesced case: what is under
        // test is frame attribution, not what the descriptor points at.
        let carried = open("/dev/null", O_RDWR)
        try #require(carried >= 0, "could not open a descriptor to hand over")
        defer { Darwin.close(carried) }

        let gate = ScriptedStubPeer.TrailerGate()
        let peer = try ScriptedStubPeer(
            socketPath: socketPath,
            answers: [
                ScriptedStubPeer.Answer(
                    descriptor: carried,
                    payload: try HolderFraming.frame(HolderResponse.handedOverPTY(alive)),
                    trailer: try HolderFraming.frame(HolderResponse.described(exited)),
                    trailerGate: gate),
                ScriptedStubPeer.Answer(payload: try HolderFraming.frame(HolderResponse.forgotten)),
            ])
        defer { peer.tearDown() }

        let client = HolderClient(socketPath: socketPath, receiveTimeout: .seconds(2))
        let (description, ptyFD) = try await client.handOverPTY()
        defer { Darwin.close(ptyFD) }
        #expect(description.status == .alive)
        #expect(ptyFD >= 0)

        // Nothing has been pushed yet, and that is what separates this test from
        // the coalesced one: the exit has not been written, so it cannot be in
        // the queue, and everything observed after this point came off the wire.
        let beforeTheGate = await client.lastPushedDescription
        #expect(beforeTheGate == nil, "the stub pushed the exit before the test released it")

        gate.release()
        try #require(gate.waitUntilWritten(), "the stub peer never wrote its trailing push")

        // The push is now in the kernel's receive buffer, unread. `forget`'s
        // barrier has to poll the socket to find it; a barrier that only drained
        // the decoded queue would take this frame as the answer to `forget`.
        try await client.forget()

        let pushed = await client.lastPushedDescription
        #expect(pushed?.status == .exited(code: 7))
        #expect(pushed?.childPID == 4242)
        await client.close()
    }

    /// A pushed exit must be observable **without** anybody calling `close()`.
    ///
    /// This is the shape a real holder produces: it pushes the terminal status
    /// at its connected client and then winds itself down, so the push and the
    /// EOF behind it are both waiting when the next verb runs. The barrier
    /// decodes the push, the read after it fails on the EOF, and the verb
    /// rightly throws — but the exit it just decoded is a fact about the child,
    /// not about the connection, and it has to survive the throw. A poller that
    /// calls `describe()` and reads `lastPushedDescription` is the whole reason:
    /// it never closes, so a status only retired at `close()` reaches it never.
    ///
    /// `close()` is deliberately not called before the assertion — calling it
    /// would retire the queue by the other path and turn the test green with
    /// the fix reverted.
    @Test func surfacesAPushedExitWithoutWaitingForClose() async throws {
        let home = SpawnedHolderFixture.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let socketPath = home + "/stub.sock"

        let alive = SpawnedHolderFixture.description(childPID: 4242, home: home)
        var exited = alive
        exited.status = .exited(code: 7)

        // Gated so the push lands in its own read rather than coalesced with
        // the answer, and the peer then hangs up — the holder's own sequence.
        let gate = ScriptedStubPeer.TrailerGate()
        let peer = try ScriptedStubPeer(
            socketPath: socketPath,
            answers: [
                ScriptedStubPeer.Answer(
                    payload: try HolderFraming.frame(HolderResponse.described(alive)),
                    trailer: try HolderFraming.frame(HolderResponse.described(exited)),
                    trailerGate: gate),
            ],
            closesAfterScript: true)
        defer { peer.tearDown() }

        let client = HolderClient(socketPath: socketPath, receiveTimeout: .seconds(2))
        let first = try await client.describe()
        #expect(first.status == .alive)
        let beforeTheGate = await client.lastPushedDescription
        #expect(beforeTheGate == nil, "the stub pushed the exit before the test released it")

        gate.release()
        try #require(gate.waitUntilWritten(), "the stub peer never wrote its trailing push")
        // Waiting for the hang-up, not just the write, is what makes the
        // interleaving deterministic: both the push and the EOF are queued
        // before the next verb runs, so the barrier is guaranteed to decode one
        // and then fail on the other.
        try #require(peer.waitUntilClosed(), "the stub peer never closed the connection")

        await #expect(throws: HolderClient.Error.peerClosed) {
            _ = try await client.describe()
        }

        let pushed = await client.lastPushedDescription
        #expect(pushed?.status == .exited(code: 7))
        #expect(pushed?.childPID == 4242)
        await client.close()
    }
}

// MARK: - Support

/// Collects an async task's outcome for a test that has to drive a clock while
/// the task runs. A class with a lock rather than an actor so the clock-driving
/// loop can check it without awaiting a possibly-blocked actor.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var thrown: Swift.Error?

    func finish(_ error: Swift.Error?) {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        thrown = error
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    var error: Swift.Error? {
        lock.lock()
        defer { lock.unlock() }
        return thrown
    }
}

/// Poll until `condition` holds or the deadline passes.
@discardableResult
private func waitUntilTrue(
    _ description: String,
    timeout: TimeInterval = 10.0,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () throws -> Bool
) rethrows -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try condition() { return true }
        usleep(20_000)
    }
    Issue.record("timed out after \(timeout)s waiting for \(description)", sourceLocation: sourceLocation)
    return false
}

private func processIsAlive(_ pid: Int32) -> Bool {
    pid > 0 && kill(pid, 0) == 0
}

/// Kills and reaps a spawned holder a test is finished with.
///
/// Safe to call on one the spawner already reaped: `waitpid` simply reports
/// there is no such child. A test that leaves a holder running leaks a `sleep`
/// with it, because holder death is not child death.
private func reapIfAlive(_ pid: Int32) {
    guard pid > 0 else { return }
    kill(pid, SIGKILL)
    var ignored: Int32 = 0
    _ = waitpid(pid, &ignored, 0)
}

/// Binds and listens on a Unix socket at `socketPath`, returning the listening
/// descriptor. Nothing accepts on it: a connect lands in the backlog and is
/// never answered, which is what a holder that reached `bind` and then wedged
/// looks like from the outside.
private func bindUnixListener(
    at socketPath: String,
    backlog: Int32,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> Int32 {
    let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(listenFD >= 0, "could not create a listening socket", sourceLocation: sourceLocation)

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let sunPathSize = MemoryLayout.size(ofValue: address.sun_path)
    socketPath.withCString { source in
        withUnsafeMutablePointer(to: &address.sun_path) { destination in
            destination.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { chars in
                _ = strlcpy(chars, source, sunPathSize)
            }
        }
    }
    unlink(socketPath)
    let bound = withUnsafePointer(to: &address) { addressPtr in
        addressPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
            Darwin.bind(listenFD, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0, listen(listenFD, backlog) == 0 else {
        let saved = errno
        Darwin.close(listenFD)
        Issue.record(
            "could not listen at \(socketPath) (errno \(saved))", sourceLocation: sourceLocation)
        throw HolderTestSetupFailure()
    }
    return listenFD
}

/// Thrown when a test's own scaffolding could not be built. Never an assertion
/// about the code under test — the `Issue` was already recorded where it was
/// discovered.
private struct HolderTestSetupFailure: Swift.Error {}

/// Takes whatever is queued on a handed-over pty master, without blocking.
///
/// **A test that holds the master must drain it, or the job cannot finish
/// exiting.** The job is the pty's session leader, and XNU's `proc_exit` calls
/// `ttywait` on the controlling terminal before revoking it, so the process
/// stays in `P_WEXIT` until the tty's output queue is empty. Only a reader on
/// the master empties it, and the holder can never be that reader.
private func drainPTYInto(_ ptyFD: Int32, _ sink: inout Data) {
    _ = fcntl(ptyFD, F_SETFL, fcntl(ptyFD, F_GETFL) | O_NONBLOCK)
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(ptyFD, &buffer, buffer.count)
        guard count > 0 else { return }
        sink.append(contentsOf: buffer[0..<count])
    }
}

/// A holder started the way the daemon starts one — through the real
/// `HolderSpawner`, with a real `posix_spawn` — plus everything needed to take
/// it back down.
private final class SpawnedHolderFixture {
    let home: String
    let sessionID: UUID
    let owner: HolderOwnerToken
    let handle: HolderHandle
    /// The connection the spawner's handshake ran on, handed straight over.
    /// Tests use this rather than dialling the socket again: a fresh connect
    /// would race the holder's notice that the handshake connection had gone,
    /// which is the race this fixture exists to stop reintroducing.
    let client: HolderClient
    private var torndown = false

    private final class BundleMarker {}

    /// A short scratch root. Short on purpose: the rendezvous socket lives
    /// under it and `sun_path` is 104 bytes, so a deep `TMPDIR` would fail the
    /// bind rather than the assertion.
    static func scratchHome() -> String {
        "/tmp/tbdh6-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// The environment the rendezvous paths are derived from *and* the holder
    /// process runs under. Explicit and rc-free: nothing here comes from the
    /// developer's shell, and `TBD_HOME` never leaves this dictionary.
    static func environment(home: String) -> [String: String] {
        ["TBD_HOME": home, "PATH": "/usr/bin:/bin"]
    }

    static func launch(command: String, home: String) -> HolderLaunchRequest {
        HolderLaunchRequest(
            executable: "/bin/sh",
            arguments: ["-c", command],
            workingDirectory: "/tmp",
            environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
            columns: 80,
            rows: 24)
    }

    /// A description shaped like one a holder would send, for tests that drive
    /// the client against a stub instead of a real holder.
    static func description(childPID: Int32, home: String) -> HolderChildDescription {
        HolderChildDescription(
            childPID: childPID,
            ttyName: "/dev/ttys004",
            status: .alive,
            launch: launch(command: "sleep 30", home: home),
            owner: HolderOwnerToken(rawValue: "acme-installation"))
    }

    /// An executable that stands in for a holder which never reaches `bind`.
    ///
    /// It ignores the arguments the spawner passes — a real holder's flags mean
    /// nothing to it — and stays alive until something kills it, so "the
    /// process is gone" can only be the spawner's doing. `exec` rather than a
    /// plain command so the pid the spawner holds is the pid that sleeps.
    static func writeNeverBindingHolder(into home: String) throws -> URL {
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: home + "/never-binding-holder")
        try "#!/bin/sh\nexec sleep 30\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static func locateExecutable() -> URL? {
        let bundleURL = Bundle(for: BundleMarker.self).bundleURL
        var candidates = [bundleURL.deletingLastPathComponent(), bundleURL]
        if let main = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(main)
        }
        for directory in candidates {
            let candidate = directory.appendingPathComponent("TBDHolder")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func makeSpawner(clock: any Clock<Duration> = ContinuousClock()) throws -> HolderSpawner {
        let executable = try #require(
            locateExecutable(), "TBDHolder must be built beside the test bundle")
        return HolderSpawner(executableURL: executable, clock: clock)
    }

    static func start(
        command: String,
        owner: String = "acme-installation",
        session: UUID = UUID()
    ) async throws -> SpawnedHolderFixture {
        let home = scratchHome()
        let token = HolderOwnerToken(rawValue: owner)
        let spawner = try makeSpawner()
        let spawned = try await spawner.spawn(
            sessionID: session,
            launch: launch(command: command, home: home),
            owner: token,
            environment: environment(home: home))
        return SpawnedHolderFixture(
            home: home,
            sessionID: session,
            owner: token,
            handle: spawned.handle,
            client: spawned.client)
    }

    private init(
        home: String,
        sessionID: UUID,
        owner: HolderOwnerToken,
        handle: HolderHandle,
        client: HolderClient
    ) {
        self.home = home
        self.sessionID = sessionID
        self.owner = owner
        self.handle = handle
        self.client = client
    }

    private var reaped = false

    /// Polls for the holder to exit on its own and reaps it.
    ///
    /// `kill(pid, 0)` cannot answer this question: the holder is this process's
    /// child, so between its exit and somebody waiting on it, it is a zombie —
    /// and a zombie is signallable. Reaping is therefore the only observation
    /// that distinguishes "exited" from "still running".
    @discardableResult
    func reapHolder(timeout: TimeInterval = 10.0) -> Bool {
        if reaped { return true }
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if waitpid(handle.holderPID, &status, WNOHANG) == handle.holderPID {
                reaped = true
                return true
            }
            usleep(20_000)
        }
        return false
    }

    /// Kills the holder AND the job, in that order, then removes the scratch
    /// root. Holder death is not child death, so both need naming. The holder
    /// is this process's own child — the spawner `posix_spawn`s it directly —
    /// so it must also be reaped, or the corpse outlives the suite.
    func tearDown() {
        guard !torndown else { return }
        torndown = true

        if !reaped {
            kill(handle.holderPID, SIGKILL)
            var ignored: Int32 = 0
            _ = waitpid(handle.holderPID, &ignored, 0)
            reaped = true
        }
        if processIsAlive(handle.childPID) { kill(handle.childPID, SIGKILL) }
        // The job is the holder's child, not ours, so nothing here can reap it;
        // the kernel reparents and reaps. Confirm it is gone so a leak fails the
        // test that caused it rather than the next run.
        waitUntilTrue("the holder's job to disappear", timeout: 5.0) {
            !processIsAlive(handle.childPID)
        }
        try? FileManager.default.removeItem(atPath: home)
    }
}

/// A stub peer that answers each request the client sends from a fixed script,
/// and then answers nothing ever again.
///
/// Deliberately not a holder: what is under test is which frame the *client*
/// attributes to which request when two of them land in one read, and racing a
/// real holder into coalescing them would make the test load-dependent — which
/// is precisely the failure mode being closed.
private final class ScriptedStubPeer: @unchecked Sendable {
    /// One scripted reply, sent when a request arrives.
    ///
    /// `trailer` is written immediately after `payload` and with no request in
    /// between, so the two arrive in the client's single read — the arranged
    /// version of the holder answering and then reporting an exit microseconds
    /// later.
    ///
    /// A `trailerGate` inverts that: the peer holds the trailer back until the
    /// test says the client has finished reading `payload`, so the two frames
    /// arrive in *different* reads. See `TrailerGate`.
    struct Answer {
        var descriptor: Int32 = -1
        var payload: Data
        var trailer: Data = Data()
        var trailerGate: TrailerGate?
    }

    /// A rendezvous between the test and the stub peer's thread, for the case
    /// where the trailing push must be written **after** the client has already
    /// read the answer it follows.
    ///
    /// Both directions are needed, and a sleep would give neither. `release()`
    /// tells the peer the client is done reading, so the push cannot be
    /// coalesced into that read; `waitUntilWritten` tells the test the push has
    /// reached the socket, so the next verb is guaranteed to find it buffered
    /// rather than still in flight. Every wait is bounded, and the peer's also
    /// gives up when the stub is torn down, so a test that fails before
    /// releasing cannot strand the thread.
    final class TrailerGate: Sendable {
        private let released = DispatchSemaphore(value: 0)
        private let written = DispatchSemaphore(value: 0)

        /// Lets the peer write the trailer.
        func release() { released.signal() }

        /// Blocks the peer until `release()`, until the stub is torn down, or
        /// until the budget runs out. Returns whether the trailer may be written.
        fileprivate func waitForRelease(timeout: TimeInterval, stopped: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if released.wait(timeout: .now() + 0.02) == .success { return true }
                if stopped() { return false }
            }
            return false
        }

        fileprivate func markWritten() { written.signal() }

        /// Blocks the test until the trailer has been written, or fails.
        func waitUntilWritten(
            timeout: TimeInterval = 10.0,
            sourceLocation: SourceLocation = #_sourceLocation
        ) -> Bool {
            if written.wait(timeout: .now() + timeout) == .success { return true }
            Issue.record(
                "timed out after \(timeout)s waiting for the stub peer to write its trailing push",
                sourceLocation: sourceLocation)
            return false
        }
    }

    private let listenFD: Int32
    private let socketPath: String
    private let lock = NSLock()
    private var connectionFD: Int32 = -1
    private var stopped = false
    /// Signalled once the peer has hung up, for `closesAfterScript`.
    private let closedConnection = DispatchSemaphore(value: 0)

    /// `closesAfterScript` makes the peer hang up when its script runs out
    /// instead of parking with the connection open. Parking is the default
    /// because an EOF the client did not expect can mask a missing queue as a
    /// pass; a test about what happens *at* the EOF needs the opposite, and
    /// waits for `waitUntilClosed()` so the hang-up is ordered rather than
    /// raced.
    init(socketPath: String, answers: [Answer], closesAfterScript: Bool = false) throws {
        self.socketPath = socketPath
        listenFD = try bindUnixListener(at: socketPath, backlog: 4)

        let listener = listenFD
        let thread = Thread { [weak self] in
            let incoming = accept(listener, nil, nil)
            guard incoming >= 0, let self else {
                if incoming >= 0 { Darwin.close(incoming) }
                return
            }
            self.adopt(incoming)
            var scratch = [UInt8](repeating: 0, count: 256)
            for answer in answers {
                // Wait for the request this answers, so every frame written is
                // a reply rather than an unsolicited greeting.
                guard read(incoming, &scratch, scratch.count) > 0 else { break }
                if answer.descriptor >= 0 {
                    try? FDChannel.sendFDMinimal(
                        answer.descriptor, over: incoming, payload: answer.payload)
                } else {
                    try? FDChannel.sendData(answer.payload, over: incoming)
                }
                if !answer.trailer.isEmpty {
                    if let gate = answer.trailerGate {
                        guard gate.waitForRelease(timeout: 10.0, stopped: { self.isStopped })
                        else { break }
                        try? FDChannel.sendData(answer.trailer, over: incoming)
                        gate.markWritten()
                    } else {
                        try? FDChannel.sendData(answer.trailer, over: incoming)
                    }
                }
            }
            // Park with the connection open. Closing here would let the client
            // reach EOF, which is the very thing the queue is meant to make
            // unnecessary — an EOF would mask a missing queue as a pass. A test
            // whose subject IS the EOF opts out with `closesAfterScript`.
            if closesAfterScript {
                self.hangUp()
                self.closedConnection.signal()
            }
            while !self.isStopped { usleep(20_000) }
        }
        thread.name = "holder-stub-peer"
        thread.start()
    }

    private func adopt(_ fd: Int32) {
        lock.lock()
        defer { lock.unlock() }
        connectionFD = fd
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Closes the accepted connection, once. Safe to race `tearDown`: whichever
    /// runs first takes the descriptor and leaves -1 behind.
    private func hangUp() {
        lock.lock()
        let connection = connectionFD
        connectionFD = -1
        lock.unlock()
        if connection >= 0 { Darwin.close(connection) }
    }

    /// Blocks the test until a `closesAfterScript` peer has hung up.
    @discardableResult
    func waitUntilClosed(
        timeout: TimeInterval = 10.0,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Bool {
        if closedConnection.wait(timeout: .now() + timeout) == .success { return true }
        Issue.record(
            "timed out after \(timeout)s waiting for the stub peer to close the connection",
            sourceLocation: sourceLocation)
        return false
    }

    func tearDown() {
        lock.lock()
        stopped = true
        lock.unlock()
        hangUp()
        Darwin.close(listenFD)
        unlink(socketPath)
    }
}
