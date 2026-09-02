import Darwin
import Foundation
import Testing
@testable import TBDShared

@Suite("Holder protocol")
struct HolderProtocolTests {
    private func description(status: HolderChildStatus) -> HolderChildDescription {
        HolderChildDescription(
            childPID: 4242,
            ttyName: "/dev/ttys004",
            status: status,
            launch: HolderLaunchRequest(
                executable: "/bin/zsh",
                arguments: ["-l"],
                workingDirectory: "/tmp",
                environment: ["FOO": "bar"],
                columns: 80,
                rows: 24
            ),
            owner: HolderOwnerToken(rawValue: "installation-abc")
        )
    }

    @Test func requestsRoundTripThroughJSON() throws {
        let cases: [HolderRequest] = [.describe, .handOverPTY, .forget]
        for request in cases {
            let data = try JSONEncoder().encode(request)
            #expect(try JSONDecoder().decode(HolderRequest.self, from: data) == request)
        }
    }

    /// Every status round-trips, including the two that are not `.alive`: a
    /// holder that could not observe an exit must be able to say so on the wire
    /// rather than have a code fabricated for it.
    @Test func responsesRoundTripThroughJSON() throws {
        let statuses: [HolderChildStatus] = [.alive, .exited(code: 7), .exitedStatusUnknown]
        for status in statuses {
            let responses: [HolderResponse] = [
                .described(description(status: status)),
                .handedOverPTY(description(status: status)),
                .forgotten,
            ]
            for response in responses {
                let data = try JSONEncoder().encode(response)
                #expect(try JSONDecoder().decode(HolderResponse.self, from: data) == response)
            }
        }
    }

    /// The owner token is what reclamation compares before killing a holder, so
    /// it has to survive the wire — a handshake proves a holder is alive, not
    /// that it is ours.
    @Test func ownerTokenSurvivesTheWire() throws {
        let mine = HolderResponse.described(description(status: .alive))
        let data = try JSONEncoder().encode(mine)
        let decoded = try JSONDecoder().decode(HolderResponse.self, from: data)
        guard case .described(let child) = decoded else {
            Issue.record("expected .described, got \(decoded)")
            return
        }
        #expect(child.owner == HolderOwnerToken(rawValue: "installation-abc"))
        #expect(child.owner != HolderOwnerToken(rawValue: "someone-else"))
    }

    /// A second client must be rejected with a sentinel version rather than
    /// silently served — two readers on one master is silent byte theft.
    @Test func rejectionCarriesTheSentinelVersion() throws {
        let response = HolderResponse.rejected(version: HolderProtocolVersion.busySentinel)
        let data = try JSONEncoder().encode(response)
        #expect(try JSONDecoder().decode(HolderResponse.self, from: data) == response)
        #expect(HolderProtocolVersion.busySentinel != HolderProtocolVersion.current)
    }

    /// The fd rides one byte and the rest follows by plain `write()`, and the
    /// fd is NOT re-sent with the remainder — a second `SCM_RIGHTS` block would
    /// materialize a duplicate descriptor in the recipient, a second reference
    /// to the same open file that keeps the pty master alive after the first is
    /// closed.
    ///
    /// The *split itself* is not observable from this end: the receiver's first
    /// `recvmsg` stops at the next ancillary boundary and there isn't one, so
    /// the trailing plain writes coalesce into the same read and a one-byte
    /// `sendmsg` looks identical to a whole-frame one. What is observable —
    /// and what actually matters — is that exactly one descriptor arrives and
    /// the whole payload does. A re-sent fd is caught precisely because its
    /// second `SCM_RIGHTS` block *creates* a boundary and forces a second read.
    @Test func minimalFDSendDeliversFDExactlyOnceAndTheFullPayload() throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        // Bound the drain loop: a send that drops the remainder must redden as
        // a receive error rather than hanging the suite forever.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        #expect(setsockopt(
            pair[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)

        // Any fd will do as the passenger; use a pipe read end.
        var pipeFDs: [Int32] = [0, 0]
        #expect(pipe(&pipeFDs) == 0)
        defer { close(pipeFDs[0]); close(pipeFDs[1]) }

        let payload = Data(("hello-holder-" + String(repeating: "p", count: 512)).utf8)
        try FDChannel.sendFDMinimal(pipeFDs[0], over: pair[0], payload: payload)

        let received = try FDChannel.receiveMessage(from: pair[1], capacity: 4096)
        var receivedFDs = received.fds
        defer { receivedFDs.forEach { close($0) } }
        #expect(received.fds.count == 1)

        var got = received.data
        while got.count < payload.count {
            let more = try FDChannel.receiveMessage(from: pair[1], capacity: 4096)
            receivedFDs.append(contentsOf: more.fds)
            #expect(more.fds.isEmpty)
            got += more.data
        }
        #expect(got == payload)
        #expect(receivedFDs.count == 1)
    }

    /// An empty payload has no byte for the descriptor to ride on, and an
    /// empty-payload sendmsg with SCM_RIGHTS is one of the shapes observed to
    /// fail outright — so it is refused by name instead.
    @Test func minimalFDSendRefusesAnEmptyPayload() throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }

        var pipeFDs: [Int32] = [0, 0]
        #expect(pipe(&pipeFDs) == 0)
        defer { close(pipeFDs[0]); close(pipeFDs[1]) }

        #expect(throws: FDChannelError.emptyPayload) {
            try FDChannel.sendFDMinimal(pipeFDs[0], over: pair[0], payload: Data())
        }
    }
}
