import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// **A sidecar disconnect is not death.**
///
/// The sidecar has a designed reconnect path, so a socket drop can leave the
/// app alive, holding its `dup`s, still reading — and seizing then is exactly
/// the double-reader corruption this whole transport exists to prevent. So the
/// daemon does not act on the drop; it acts on a *verdict* about the process
/// that was at the other end, reached from the identity it recorded when that
/// connection was adopted.
///
/// The verdict has three values and only one of them seizes:
///
///   - **confirmed gone** — the recorded pid names nothing, or names a
///     stranger. Every session that app held reverts to daemon-read.
///   - **alive** — the recorded pid still names that same process. The daemon
///     stays off the fds and awaits the reconnect and the re-claim.
///   - **not yet determined** — the kernel would not say. Treated as alive,
///     because the failure direction on this path is always toward reading
///     nothing until liveness says otherwise.
///
/// The reused-pid case is why the check is identity-verified rather than a bare
/// `kill(pid, 0)`: a dead app whose pid has been handed to something else would
/// otherwise look alive forever and stall every session it was holding.
///
/// Tier 1. No holder, no pty, no process is signalled — the process table is
/// scripted through `FakeProcessSignaller`.
@Suite struct HolderAppLivenessTests {

    /// The executable the daemon recorded for the app when its sidecar
    /// connection was adopted.
    private static let appExecutable = "/opt/tbd/.build/debug/TBDApp"
    private static let appPID: Int32 = 4242

    private static func recordedIdentity(
        startedAt: Date, executable: String = appExecutable
    ) -> ProcessIdentity {
        ProcessIdentity(pid: appPID, startedAt: startedAt, commandLine: executable)
    }

    /// Counts the reclaims the arbitration asked for, so every test can assert
    /// on the *action* rather than only on the verdict that licenses it.
    private actor ReclaimSpy {
        private(set) var calls = 0
        func record() -> [UUID] {
            calls += 1
            return []
        }
    }

    private static func arbiter(
        signaller: FakeProcessSignaller, spy: ReclaimSpy
    ) -> SidecarDisconnectArbiter {
        SidecarDisconnectArbiter(
            liveness: AppLivenessArbiter(signaller: signaller),
            reclaim: { await spy.record() })
    }

    // MARK: - Alive

    /// The whole point of the task. The app dropped its socket and is still
    /// running, still holding its `dup`s and still reading them; the daemon
    /// must stay off those descriptors and wait for the reconnect.
    @Test func aDisconnectFromALiveAppSeizesNothing() async {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let signaller = FakeProcessSignaller()
        signaller.startTimes[Self.appPID] = started
        signaller.cmdlines[Self.appPID] = Self.appExecutable
        let spy = ReclaimSpy()

        let verdict = await Self.arbiter(signaller: signaller, spy: spy)
            .handleDisconnect(identity: Self.recordedIdentity(startedAt: started))

        #expect(verdict == .alive)
        #expect(await spy.calls == 0, """
            the daemon seized the ptys of an app that is still alive and still reading them — the \
            double-reader corruption this transport exists to prevent
            """)
    }

    // MARK: - Confirmed gone

    /// Nothing holds the recorded pid: the app is gone, its descriptors closed
    /// with it, and no cooperation from it is needed or possible.
    @Test func aDisconnectFromAnAppThatIsGoneRevertsItsSessions() async {
        let signaller = FakeProcessSignaller()
        signaller.behaviors[Self.appPID] = .init(aliveInitially: false)
        let spy = ReclaimSpy()

        let verdict = await Self.arbiter(signaller: signaller, spy: spy)
            .handleDisconnect(
                identity: Self.recordedIdentity(startedAt: Date(timeIntervalSince1970: 1)))

        #expect(verdict == .confirmedGone(reason: "process-gone"))
        #expect(await spy.calls == 1, """
            a confirmed-dead app left its sessions claimed: nothing drains them, no injection can \
            reach them, and every re-open is refused
            """)
    }

    /// **The point of the identity check.** The recorded pid is alive — but it
    /// belongs to something else now. A bare liveness probe would report this
    /// app as running for as long as the stranger lives, and every session it
    /// held would stay unread and unwritable behind that answer.
    ///
    /// The start time is held *equal* here on purpose, so the only thing that
    /// can produce the verdict is the executable half of the check.
    @Test func aReusedPIDRunningADifferentExecutableIsClassifiedAsDead() async {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let signaller = FakeProcessSignaller()
        signaller.startTimes[Self.appPID] = started
        signaller.cmdlines[Self.appPID] = "/usr/bin/python3 /Users/someone/unrelated.py"
        let spy = ReclaimSpy()

        let verdict = await Self.arbiter(signaller: signaller, spy: spy)
            .handleDisconnect(identity: Self.recordedIdentity(startedAt: started))

        #expect(verdict == .confirmedGone(reason: "pid-reused-executable"), """
            a stranger holding the app's old pid was read as the app still running, which stalls \
            every session that app was holding for as long as the stranger lives
            """)
        #expect(await spy.calls == 1)
    }

    /// The other half of the same check, and the half that survives `execve`:
    /// a process that presents the app's own executable but started at a
    /// different moment is a different process.
    @Test func aReusedPIDWithADifferentStartTimeIsClassifiedAsDead() async {
        let recordedStart = Date(timeIntervalSince1970: 1_700_000_000)
        let signaller = FakeProcessSignaller()
        signaller.startTimes[Self.appPID] = recordedStart.addingTimeInterval(90)
        signaller.cmdlines[Self.appPID] = Self.appExecutable
        let spy = ReclaimSpy()

        let verdict = await Self.arbiter(signaller: signaller, spy: spy)
            .handleDisconnect(identity: Self.recordedIdentity(startedAt: recordedStart))

        #expect(verdict == .confirmedGone(reason: "pid-reused-start-time"), """
            a relaunched app reusing its predecessor's pid was read as the predecessor still \
            running
            """)
        #expect(await spy.calls == 1)
    }

    // MARK: - Not yet determined

    /// The kernel would not say when the process holding this pid started. That
    /// is not evidence of death, and this path may act on nothing less.
    @Test func anUnreadableStartTimeIsNotDeath() async {
        let signaller = FakeProcessSignaller()
        signaller.cmdlines[Self.appPID] = Self.appExecutable
        // No `startTimes` entry: `ps` answered nothing parseable.
        let spy = ReclaimSpy()

        let verdict = await Self.arbiter(signaller: signaller, spy: spy)
            .handleDisconnect(
                identity: Self.recordedIdentity(startedAt: Date(timeIntervalSince1970: 1)))

        #expect(verdict == .undetermined(reason: "start-time-unreadable"))
        #expect(await spy.calls == 0, """
            an unreadable identity was treated as a confirmed death, so the daemon put itself on \
            descriptors an app may still be reading
            """)
    }

    /// An unreadable command line is the same class of non-answer, and takes
    /// the same direction — even though `commandLine` returning empty is what a
    /// pid that has just vanished looks like. "Probably gone" is not gone.
    @Test func anUnreadableCommandLineIsNotDeath() async {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let signaller = FakeProcessSignaller()
        signaller.startTimes[Self.appPID] = started
        // No `cmdlines` entry.
        let spy = ReclaimSpy()

        let verdict = await Self.arbiter(signaller: signaller, spy: spy)
            .handleDisconnect(identity: Self.recordedIdentity(startedAt: started))

        #expect(verdict == .undetermined(reason: "command-unreadable"))
        #expect(await spy.calls == 0)
    }

    /// A connection whose peer the daemon never managed to identify. There is
    /// no pid to ask about, so there is nothing to confirm — and an
    /// unidentified peer must never license a seize.
    @Test func aDisconnectWithNoRecordedIdentityIsNotDeath() async {
        let signaller = FakeProcessSignaller()
        let spy = ReclaimSpy()

        let verdict = await Self.arbiter(signaller: signaller, spy: spy)
            .handleDisconnect(identity: nil)

        #expect(verdict == .undetermined(reason: "identity-unrecorded"))
        #expect(await spy.calls == 0)
    }

    // MARK: - Which disconnect is a disconnect

    /// A reconnect tears the *old* socket down, so its receive thread exits
    /// exactly as a dead app's does. That exit is not a disconnect: a newer
    /// connection owns the sinks, and arbitrating on the superseded one would
    /// ask "is the app alive?" about an app that has just proved it is by
    /// connecting again.
    @Test func aSupersededConnectionsExitIsNotADisconnect() async throws {
        let (oldServerFD, oldClientFD) = try Self.socketPair()
        let (newServerFD, newClientFD) = try Self.socketPair()
        defer { Darwin.close(oldClientFD) }

        let identities: [Int32: ProcessIdentity] = [
            oldServerFD: ProcessIdentity(
                pid: 11, startedAt: Date(timeIntervalSince1970: 10), commandLine: "old"),
            newServerFD: ProcessIdentity(
                pid: 22, startedAt: Date(timeIntervalSince1970: 20), commandLine: "new"),
        ]
        let disconnects = DisconnectLog()
        let exits = DisconnectLog()
        let server = FDVendingServer(peerIdentity: { identities[$0] })
        await server.setOnClientDisconnect { disconnects.record($0) }
        await server.setOnReceiveLoopExit { exits.record(nil) }

        await server.adoptConnection(fd: oldServerFD)
        // The reconnect. `adoptConnection` shuts the old socket down, so its
        // receive thread leaves `read()` and signals its own exit.
        await server.adoptConnection(fd: newServerFD)
        #expect(await waitUntil { exits.count == 1 }, "the superseded receive thread never exited")
        #expect(disconnects.count == 0, """
            a reconnect was arbitrated as an app death, so the daemon would seize the ptys of an \
            app that is demonstrably alive — it is connected right now
            """)

        // And the connection that IS current still reports its own drop, with
        // the identity recorded for it rather than for its predecessor.
        Darwin.close(newClientFD)
        #expect(await waitUntil { disconnects.count == 1 }, "a live app's drop went unreported")
        #expect(disconnects.all == [identities[newServerFD]])

        await server.stop()
    }

    private static func socketPair() throws -> (Int32, Int32) {
        var pair: [Int32] = [-1, -1]
        try pair.withUnsafeMutableBufferPointer { buf in
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress) == 0 else {
                throw FDChannelError.sendFailed(errno)
            }
        }
        return (pair[0], pair[1])
    }
}

/// Thread-safe record of what the sidecar reported, written from the receive
/// thread and read from the test's task.
private final class DisconnectLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ProcessIdentity?] = []

    func record(_ identity: ProcessIdentity?) {
        lock.withLock { entries.append(identity) }
    }
    var count: Int { lock.withLock { entries.count } }
    var all: [ProcessIdentity?] { lock.withLock { entries } }
}
