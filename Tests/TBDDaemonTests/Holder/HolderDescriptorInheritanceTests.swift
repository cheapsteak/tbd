import Darwin
import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// **A session's pty must not survive an `exec` anywhere in the daemon.**
///
/// The daemon spawns children constantly and almost entirely through
/// `Foundation.Process` — git, tmux probes, usage and PR-status fetchers,
/// SSH-agent resolution, peer supervisors — and `Process` closes nothing that
/// lacks `FD_CLOEXEC`. `HolderSpawner` is the one path that asks for
/// `POSIX_SPAWN_CLOEXEC_DEFAULT`; every other spawn inherits whatever is open
/// and inheritable at the moment it runs.
///
/// So a copy of a session's pty master left inheritable is a copy some
/// unrelated child eventually takes, and that child then holds the session open
/// for as long as it lives: the reader sees no EOF when the job exits,
/// death-detection-by-EOF stops working, and the handback never completes. The
/// app side had the same defect and the same consequence — a sibling suite's
/// `/bin/sleep 120` held a third copy of a pty two processes had correctly let
/// go of.
///
/// Two descriptors carry that risk on this side, and each has a row here:
/// the one `HolderClient` receives over `SCM_RIGHTS` and hands to
/// `HolderReader`, which lives as long as the session; and the copy
/// `HolderReader.suspendDraining()` makes for a viewer, which sits in this
/// process from the duplication until the vend hands it to the app.
///
/// Both rows prove first that the thing they assert on arrives *inheritable*,
/// so neither can pass because the platform happened to do the work.
@Suite("HolderDescriptorInheritance")
struct HolderDescriptorInheritanceTests {

    private static func isCloseOnExec(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFD)
        return flags >= 0 && (flags & FD_CLOEXEC) != 0
    }

    // MARK: - What arrives over SCM_RIGHTS

    /// The non-vacuity premise for the row below, asserted rather than assumed.
    ///
    /// `FD_CLOEXEC` is a property of a descriptor, not of the open file, and it
    /// does **not** ride an `SCM_RIGHTS` transfer: darwin has no
    /// `MSG_CMSG_CLOEXEC` to ask `recvmsg` for a close-on-exec copy, so what a
    /// receiver gets is inheritable however carefully the sender flagged its
    /// own. This pins that platform fact — the sender's copy is explicitly made
    /// close-on-exec, and the receiver's still is not — because it is the
    /// premise the whole fix rests on and exactly the kind that rots silently.
    @Test("a descriptor received over SCM_RIGHTS arrives inheritable")
    func receivedDescriptorsAreInheritableByDefault() throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        // Everything this suite creates that is not itself the subject of an
        // assertion is close-on-exec, for the reason the suite is about: test
        // targets share one process, and two suites in it keep `/bin/sleep 120`
        // children alive for the rest of the run.
        _ = fcntl(pair[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(pair[1], F_SETFD, FD_CLOEXEC)

        var pipeFDs: [Int32] = [-1, -1]
        #expect(pipe(&pipeFDs) == 0)
        defer { close(pipeFDs[0]); close(pipeFDs[1]) }
        _ = fcntl(pipeFDs[1], F_SETFD, FD_CLOEXEC)

        // The sender's copy says close-on-exec as loudly as it can.
        #expect(fcntl(pipeFDs[0], F_SETFD, FD_CLOEXEC) == 0)
        #expect(Self.isCloseOnExec(pipeFDs[0]))

        try FDChannel.sendFDMinimal(pipeFDs[0], over: pair[0], payload: Data("x".utf8))
        let received = try FDChannel.receiveMessage(from: pair[1], capacity: 4096)
        defer { received.fds.forEach { close($0) } }

        let arrived = try #require(received.fds.first)
        #expect(
            !Self.isCloseOnExec(arrived),
            """
            the transport now delivers close-on-exec descriptors on its own, so every assertion \
            that HolderClient sets the flag is vacuous and must be rewritten
            """)
    }

    /// The descriptor `HolderClient` hands to `HolderReader` is the session's
    /// pty master and it stays open for the session's whole life. It arrives
    /// inheritable — the row above proves the transport cannot do otherwise —
    /// so the client sets the flag itself, and this asserts it did.
    @Test("the handed-over pty is close-on-exec by the time a caller sees it")
    func theHandedOverDescriptorIsCloseOnExec() async throws {
        let holder = try FakeHolder()
        defer { holder.tearDown() }

        // The passenger the fake hands over, flagged close-on-exec on the
        // sender's side so a reading of this test as "the flag rode across"
        // is not available: the row above shows it cannot.
        #expect(fcntl(holder.passenger, F_SETFD, FD_CLOEXEC) == 0)

        let client = HolderClient(socketPath: holder.socketPath, receiveTimeout: .seconds(5))
        let (description, ptyFD) = try await client.handOverPTY()
        defer { close(ptyFD) }
        await client.close()

        #expect(description.childPID == FakeHolder.childPID)
        #expect(
            Self.isCloseOnExec(ptyFD),
            """
            the daemon left a session's pty inheritable, so any child it spawns — git, a tmux \
            probe, a usage fetcher — holds that session open for as long as it lives
            """)
    }

    // MARK: - The copy made for a viewer

    /// `suspendDraining()` duplicates the pty for the app to read. `dup(2)`
    /// would clear `FD_CLOEXEC` on the copy whatever the original carries, so
    /// the duplication itself has to ask for the flag.
    ///
    /// Non-vacuous by construction: the source descriptor is asserted
    /// inheritable first, which is the state in which a plain `dup` produces an
    /// inheritable copy.
    @Test("the copy vended to a viewer is close-on-exec")
    func theVendedDuplicateIsCloseOnExec() async throws {
        // A socketpair end stands in for the pty master. Nothing on this path
        // reads the terminal's ioctls; what is under test is the flag on a
        // duplicate, and a real pty would only add a spawned job to a test
        // that needs none.
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[1]) }
        // The end this test keeps is not the subject, so it does not stay
        // inheritable; `pair[0]` deliberately does, because its flag is what
        // makes the assertion below mean something.
        _ = fcntl(pair[1], F_SETFD, FD_CLOEXEC)

        #expect(
            !Self.isCloseOnExec(pair[0]),
            "the source must be inheritable, or a plain dup would pass this test too")

        let reader = HolderReader(
            sessionID: UUID(), ptyFD: pair[0], columns: 80, rows: 24,
            observedChildFromStart: true)
        let duplicate = try await reader.suspendDraining()
        #expect(duplicate >= 0)

        #expect(
            Self.isCloseOnExec(duplicate),
            """
            the vended duplicate is inheritable, so a daemon child spawned between the \
            duplication and the vend keeps the session open after the viewer lets it go
            """)

        close(duplicate)
        // The reader owns `pair[0]` and closes it here; the test must not.
        await reader.stop()
    }

    // MARK: - Harness

    /// A holder's rendezvous socket, answering exactly one `handOverPTY`.
    ///
    /// A real `TBDHolder` would make this a tier-3 test for no gain: what is
    /// under test is what `HolderClient` does with a descriptor after
    /// `recvmsg` returns it, and that is the same descriptor whoever sent it.
    private final class FakeHolder {
        static let childPID: Int32 = 4242

        let socketPath: String
        /// The descriptor the fake hands over. Owned here so a test can flag it
        /// before the send; the copy the client receives is a different
        /// descriptor and is the caller's to close.
        let passenger: Int32

        private let directory: String
        private let listener: Int32
        private let writeEnd: Int32
        private let thread: Thread

        init() throws {
            // Short on purpose: the socket lives under it and `sun_path` is 104
            // bytes, so a deep `TMPDIR` would fail the bind, not the assertion.
            directory = "/tmp/tbdfdi-\(UUID().uuidString.prefix(8).lowercased())"
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
            socketPath = directory + "/holder.sock"

            var pipeFDs: [Int32] = [-1, -1]
            guard pipe(&pipeFDs) == 0 else { throw Failure.cannotCreatePipe(errno: errno) }
            passenger = pipeFDs[0]
            writeEnd = pipeFDs[1]
            // `passenger` is left alone: the test that uses it sets its flag
            // itself, and that flag is half of what the test says.
            _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)

            // Kept in a local until the very end: every `withUnsafePointer`
            // below would otherwise read `self.listener` and capture a
            // half-initialized `self`.
            let listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listenerFD >= 0 else { throw Failure.cannotListen(errno: errno) }
            _ = fcntl(listenerFD, F_SETFD, FD_CLOEXEC)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            let path = socketPath
            path.withCString { source in
                withUnsafeMutablePointer(to: &address.sun_path) { destination in
                    destination.withMemoryRebound(to: CChar.self, capacity: capacity) { chars in
                        _ = strlcpy(chars, source, capacity)
                    }
                }
            }
            let bound = withUnsafePointer(to: &address) { addressPtr in
                addressPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    bind(listenerFD, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, listen(listenerFD, 4) == 0 else {
                let saved = errno
                close(listenerFD)
                throw Failure.cannotListen(errno: saved)
            }
            listener = listenerFD

            let handOver = pipeFDs[0]
            thread = Thread {
                FakeHolder.serveOneRequest(on: listenerFD, handingOver: handOver)
            }
            thread.name = "fake-holder"
            thread.start()
        }

        /// Accepts one client, reads its request, and answers it with a
        /// description plus the descriptor — the same `sendFDMinimal` shape the
        /// real holder uses, so the client's receive path is the production one.
        private static func serveOneRequest(on listener: Int32, handingOver passenger: Int32) {
            var peer = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(listener, &peer, &length)
            guard client >= 0 else { return }
            defer { close(client) }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)

            // Bounded: a client that never speaks must not park this thread for
            // the life of the process.
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            _ = setsockopt(
                client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                socklen_t(MemoryLayout<timeval>.size))

            var inbox = Data()
            var asked = false
            while !asked {
                guard let message = try? FDChannel.receiveMessage(from: client, capacity: 4096)
                else { return }
                for descriptor in message.fds { Darwin.close(descriptor) }
                inbox.append(message.data)
                guard let requests = try? HolderFraming.drainRequests(from: &inbox) else { return }
                asked = !requests.isEmpty
            }

            let description = HolderChildDescription(
                childPID: childPID,
                ttyName: "/dev/ttys999",
                status: .alive,
                launch: HolderLaunchRequest(
                    executable: "/bin/sh", arguments: ["-c", "true"], workingDirectory: "/tmp",
                    environment: [:], columns: 80, rows: 24),
                owner: HolderOwnerToken(rawValue: "fake-holder"))
            guard let frame = try? HolderFraming.frame(
                HolderResponse.handedOverPTY(description))
            else { return }
            try? FDChannel.sendFDMinimal(passenger, over: client, payload: frame)
            // Held open until the client hangs up, rather than closed straight
            // away: an immediate close races the client's read and it would
            // report a peer that hung up instead of the answer that did arrive.
            // Bounded by the `SO_RCVTIMEO` above, so a client that never closes
            // cannot park this thread for the life of the process.
            var scratch: UInt8 = 0
            while Darwin.read(client, &scratch, 1) > 0 {}
        }

        func tearDown() {
            close(listener)
            close(passenger)
            close(writeEnd)
            try? FileManager.default.removeItem(atPath: directory)
        }

        enum Failure: Swift.Error {
            case cannotCreatePipe(errno: Int32)
            case cannotListen(errno: Int32)
        }
    }
}
