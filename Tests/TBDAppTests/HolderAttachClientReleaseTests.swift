import Clocks
import Darwin
import Foundation
import TBDShared
import Testing

@testable import TBDApp
import TestSupport

/// `HolderAttachClient.attach` against a daemon that mints an attach and then
/// never delivers its descriptor.
///
/// Once `attach.request` has answered `pending`, the daemon holds that attach
/// under the generation it minted, and its ready timeout later turns a pending
/// attach into a viewer claim that refuses every later attach to the session.
/// The generation exists only inside `attach` at that point — a throw takes it
/// with it — so the client itself must release the attach before rethrowing.
///
/// Tier 2: a real `DaemonClient` over a real AF_UNIX socket to an in-test
/// stand-in for the daemon's RPC listener. The FD sidecar is never connected,
/// so the descriptor promise runs out its (injected, short) timeout — the same
/// failure a vend lost on the way produces.
@Suite("A holder attach whose descriptor never arrives releases what the daemon minted",
       .fastPassBounded)
struct HolderAttachClientReleaseTests {

    private static let generation: UInt64 = 42

    /// Answers the daemon's RPC socket: one newline-framed request per
    /// connection, the way `DaemonClient.sendRaw` speaks it. `attach.request`
    /// gets a pending attach under `generation`; every other method gets `ok`.
    private final class FakeDaemonRPC: @unchecked Sendable {
        let socketPath: String
        private let root: String
        private let listenFD: Int32
        private let generation: UInt64
        private let lock = NSLock()
        private var received: [RPCRequest] = []
        private var stopped = false
        /// Hang up on the first `pane.detach` without answering it: a request
        /// that never got its reply, which the client reads as lost in transit.
        private let dropFirstDetach: Bool
        private var droppedDetach = false

        init(generation: UInt64, dropFirstDetach: Bool = false) throws {
            self.generation = generation
            self.dropFirstDetach = dropFirstDetach
            root = fencedScratchRoot(prefix: "hac")
            try FileManager.default.createDirectory(
                atPath: root, withIntermediateDirectories: true)
            socketPath = "\(root)/d.sock"

            listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
            #expect(listenFD >= 0)
            _ = fcntl(listenFD, F_SETFD, FD_CLOEXEC)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = socketPath.utf8CString
            #expect(pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path))
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                    for index in 0..<pathBytes.count { dest[index] = pathBytes[index] }
                }
            }
            let bound = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            #expect(bound == 0)
            #expect(listen(listenFD, 8) == 0)

            let thread = Thread { [self] in self.serve() }
            thread.name = "fake-daemon-rpc"
            thread.start()
        }

        /// The methods received, in arrival order.
        var methods: [String] { lock.withLock { received.map(\.method) } }

        /// Every request received with `method`, decoded as `P`.
        func params<P: Decodable>(_ method: String, as type: P.Type) -> [P] {
            let matching = lock.withLock { received.filter { $0.method == method } }
            return matching.compactMap {
                try? JSONDecoder().decode(type, from: Data($0.params.utf8))
            }
        }

        /// Asks the serving thread to exit; it closes the listener and removes
        /// the scratch root on its way out, within one poll interval.
        func stop() {
            lock.withLock { stopped = true }
        }

        private var isStopped: Bool { lock.withLock { stopped } }

        private func serve() {
            while !isStopped {
                var descriptor = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 100) > 0 else { continue }
                let connection = accept(listenFD, nil, nil)
                guard connection >= 0 else { continue }
                answer(connection)
                close(connection)
            }
            close(listenFD)
            try? FileManager.default.removeItem(atPath: root)
        }

        private func answer(_ connection: Int32) {
            var frame = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !frame.contains(0x0A) {
                let count = buffer.withUnsafeMutableBytes {
                    recv(connection, $0.baseAddress, $0.count, 0)
                }
                if count <= 0 { return }
                frame.append(contentsOf: buffer[0..<count])
            }
            guard let newline = frame.firstIndex(of: 0x0A),
                  let request = try? JSONDecoder().decode(
                    RPCRequest.self, from: frame[frame.startIndex..<newline])
            else { return }
            let drop = lock.withLock { () -> Bool in
                received.append(request)
                guard dropFirstDetach, request.method == RPCMethod.paneDetach, !droppedDetach
                else { return false }
                droppedDetach = true
                return true
            }
            if drop { return }

            let response: RPCResponse
            if request.method == RPCMethod.attachRequest {
                response = (try? RPCResponse(
                    result: AttachRequestResult(status: "pending", generation: generation)))
                    ?? RPCResponse(error: "fake daemon could not encode its answer")
            } else {
                response = .ok()
            }
            var reply = (try? JSONEncoder().encode(response)) ?? Data()
            reply.append(0x0A)
            _ = reply.withUnsafeBytes { send(connection, $0.baseAddress, $0.count, 0) }
        }
    }

    @Test("an attach whose descriptor never arrives acks and then detaches its generation before throwing")
    func anUndeliveredAttachIsReleasedBeforeTheThrow() async throws {
        let daemon = try FakeDaemonRPC(generation: Self.generation)
        defer { daemon.stop() }
        // The sidecar is never connected, so no descriptor can arrive; the
        // short timeout is the vend that never lands. Its socket path is one
        // nothing listens on, so the attach's own sidecar reconnect fails too
        // rather than reaching whatever the ambient vend path holds.
        let client = HolderAttachClient(
            daemonClient: DaemonClient(
                socketPath: daemon.socketPath, vendSocketPath: daemon.socketPath + ".vend"),
            fdTimeout: .milliseconds(100))
        let worktreeID = UUID()
        let terminalID = UUID()

        var thrown: (any Error)?
        do {
            _ = try await client.attach(
                worktreeID: worktreeID, paneID: "", terminalID: terminalID, attachSeq: 7)
        } catch {
            thrown = error
        }
        #expect(thrown != nil, "the attach was expected to fail: no descriptor can arrive")
        let requests = daemon.params(RPCMethod.attachRequest, as: AttachRequestParams.self)
        #expect(requests.map(\.attachSeq) == [7 as UInt64?],
                "the request must carry the seq the panel's hold minted")

        // Awaited inside `attach` before it rethrows, so it is all here now.
        #expect(daemon.methods == [
            RPCMethod.attachRequest, RPCMethod.attachReady, RPCMethod.paneDetach,
        ], """
            an attach the daemon minted and never delivered was left standing — the generation \
            dies with the throw, so nothing else can release it: \(daemon.methods)
            """)

        let readies = daemon.params(RPCMethod.attachReady, as: AttachReadyParams.self)
        #expect(readies.map(\.generation) == [Self.generation as UInt64?])
        #expect(readies.map(\.terminalID) == [terminalID as UUID?])
        let detaches = daemon.params(RPCMethod.paneDetach, as: PaneDetachParams.self)
        #expect(detaches.map(\.generation) == [Self.generation as UInt64?])
        #expect(detaches.map(\.terminalID) == [terminalID as UUID?])
        #expect(detaches.allSatisfy { ($0.snapshotPreamble ?? Data()).isEmpty },
                "nothing was painted, so there is no screen to hand back")
    }

    /// When the release's detach never gets its reply, the client resends it
    /// in the background — and that resend has to reach the panel, which
    /// records it with its ledger and waits for it before it gives up. It
    /// rides the throw.
    @Test("an undelivered attach whose release was lost in transit throws with the release's resend")
    func anUndeliveredAttachCarriesItsReleaseResend() async throws {
        // At or above the floor, so the release may be resent at all.
        let generation = AttachRequestResult.uniqueGenerationFloor + Self.generation
        let daemon = try FakeDaemonRPC(generation: generation, dropFirstDetach: true)
        defer { daemon.stop() }
        let client = HolderAttachClient(
            daemonClient: DaemonClient(
                socketPath: daemon.socketPath, vendSocketPath: daemon.socketPath + ".vend"),
            fdTimeout: .milliseconds(100), clock: ImmediateClock<Duration>())

        var thrown: (any Error)?
        do {
            _ = try await client.attach(worktreeID: UUID(), paneID: "", terminalID: UUID())
        } catch {
            thrown = error
        }
        // No seq given: the default sends none, so no sweep can take it back.
        let requests = daemon.params(RPCMethod.attachRequest, as: AttachRequestParams.self)
        #expect(requests.map(\.attachSeq) == [nil as UInt64?], "\(requests.map(\.attachSeq))")
        let undelivered = try #require(
            thrown as? HolderAttachUndelivered,
            "the release's resend must ride the throw, got \(String(describing: thrown))")
        #expect(undelivered.cause is FDSidecarError, "the cause is the descriptor that never came")

        await undelivered.releaseResend.value
        #expect(daemon.methods == [
            RPCMethod.attachRequest, RPCMethod.attachReady, RPCMethod.paneDetach, RPCMethod.paneDetach,
        ], "the lost detach must be resent once, and land: \(daemon.methods)")
    }
}
