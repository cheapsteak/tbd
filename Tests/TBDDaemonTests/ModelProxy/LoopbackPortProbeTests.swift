import Foundation
import Testing

@testable import TBDDaemonLib

/// `LoopbackPortProbe` against real sockets, because the whole reason it exists
/// beside `ModelProxyClient` is an errno the client folds away.
///
/// Two answers and nothing in between: the supervisor's port wait waits out a
/// refused connect and gives up on an accepted one, so a probe that could not
/// tell them apart would either strand live sessions or leave a home unproxied
/// behind a listener that is never going to move.
@Suite("Loopback port probe")
struct LoopbackPortProbeTests {

    /// Port 1 is privileged: binding it needs root, so nothing in a test runner
    /// — this suite, a sibling running in parallel, or anything else on the
    /// machine — can be listening there, and the connect is a prompt
    /// `ECONNREFUSED`. That is what a freed ephemeral number held by nothing
    /// looks like.
    @Test("a port with no listener is refused")
    func aPortWithNoListenerIsRefused() {
        #expect(LoopbackPortProbe().occupancy(port: 1) == .refused)
    }

    /// The discriminating half: a real listener on a real loopback port, which
    /// accepts the connection in the kernel without the accept loop having to
    /// answer anything.
    @Test("a port with a listener is accepted")
    func aPortWithAListenerIsAccepted() throws {
        let server = try LoopbackHTTPTestServer { _ in .ok("{}") }
        defer { server.stop() }

        #expect(LoopbackPortProbe().occupancy(port: server.port) == .accepted)
    }
}
