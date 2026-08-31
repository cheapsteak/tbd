import Foundation
import Testing
@testable import TBDShared

@Suite("Holder rendezvous paths")
struct HolderRendezvousTests {
    let session = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!

    @Test func socketAndLockAreSiblingsNamedBySession() throws {
        let env = ["TBD_HOME": "/tmp/tbd-test-home"]
        let sock = try HolderRendezvous.socketPath(sessionID: session, environment: env)
        let lock = try HolderRendezvous.lockPath(sessionID: session, environment: env)
        #expect(sock.hasPrefix("/tmp/tbd-test-home/holders/"))
        #expect(sock.hasSuffix(".sock"))
        #expect(lock == sock.replacingOccurrences(of: ".sock", with: ".lock"))
        #expect(sock.contains(session.uuidString.lowercased()))
    }

    /// Derived from TBDConstants, never hand-composed from $HOME — a path built
    /// from $HOME silently ignores TBD_HOME and defeats the test fence.
    @Test func honorsTBDHome() throws {
        let a = try HolderRendezvous.socketPath(sessionID: session, environment: ["TBD_HOME": "/tmp/a"])
        let b = try HolderRendezvous.socketPath(sessionID: session, environment: ["TBD_HOME": "/tmp/b"])
        #expect(a != b)
        #expect(a.hasPrefix("/tmp/a/"))
        #expect(b.hasPrefix("/tmp/b/"))
    }

    /// sun_path is ~104 bytes on Darwin. Overflow must be a named error at
    /// derivation time, not a confusing EINVAL from bind() much later.
    @Test func rejectsPathsThatOverflowSunPath() throws {
        let deep = "/tmp/" + String(repeating: "d", count: 200)
        #expect(throws: HolderRendezvous.Error.self) {
            _ = try HolderRendezvous.socketPath(sessionID: session, environment: ["TBD_HOME": deep])
        }
        // The lock shares the budget, so a session that cannot be bound also
        // cannot be locked — the two must never disagree.
        #expect(throws: HolderRendezvous.Error.self) {
            _ = try HolderRendezvous.lockPath(sessionID: session, environment: ["TBD_HOME": deep])
        }
    }

    @Test func acceptsAPathAtTheLimit() throws {
        // A realistic default home must comfortably fit.
        let sock = try HolderRendezvous.socketPath(sessionID: session, environment: ["TBD_HOME": "/Users/me/tbd"])
        #expect(sock.utf8.count < HolderRendezvous.sunPathLimit)
    }

    /// The budget is the NUL-inclusive one, so the longest representable path
    /// is `sunPathLimit - 1` bytes. Pinned exactly, because an off-by-one here
    /// is invisible until a `bind()` on a real machine rejects a path the
    /// derivation just declared fine.
    @Test func theBoundaryIsExactlyOneByteBelowTheLimit() throws {
        // "<home>/holders/<36-char uuid>.sock" — 50 bytes past the home.
        let suffixBytes = "/holders/".utf8.count + session.uuidString.count + ".sock".utf8.count
        func home(totalBytes: Int) -> String {
            "/tmp/" + String(repeating: "d", count: totalBytes - suffixBytes - "/tmp/".utf8.count)
        }

        let longest = try HolderRendezvous.socketPath(
            sessionID: session, environment: ["TBD_HOME": home(totalBytes: HolderRendezvous.sunPathLimit - 1)])
        #expect(longest.utf8.count == HolderRendezvous.sunPathLimit - 1)

        #expect(throws: HolderRendezvous.Error.self) {
            _ = try HolderRendezvous.socketPath(
                sessionID: session, environment: ["TBD_HOME": home(totalBytes: HolderRendezvous.sunPathLimit)])
        }
    }
}
