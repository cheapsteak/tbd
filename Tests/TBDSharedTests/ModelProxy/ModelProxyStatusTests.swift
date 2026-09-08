import Foundation
import Testing

@testable import TBDShared

/// The payload `GET /tbd/status` answers with, read by a daemon out of a
/// binary that upgrades on its own schedule.
@Suite struct ModelProxyStatusTests {

    /// The whole round trip, so the field the daemon compares homes on
    /// survives the coder pair both sides are pinned to.
    @Test func roundTripsEveryFieldIncludingTheHome() throws {
        let status = ModelProxyStatus(
            version: "abc123", pid: 991, processStartTime: Date(timeIntervalSince1970: 1_700_000_001),
            port: 49213, streamsInFlight: 1, routeCount: 2, home: "/opt/example/tbd")

        let decoded = try ModelProxyStatus.decodeStatusResponse(
            try status.encodedForStatusResponse())
        #expect(decoded == status)
        #expect(decoded.home == "/opt/example/tbd")
    }

    /// A proxy built before this field reported must still be readable.
    ///
    /// The daemon's only alternative to reading it is killing the process
    /// holding its port, and a decode that threw on a missing key would leave
    /// it unable to read even the pid. Empty is the answer that means "this
    /// proxy did not say", and a daemon reads that as "not mine".
    @Test func aPayloadWithoutAHomeDecodesToAnEmptyHome() throws {
        let legacy = """
            {"version":"old","pid":42,"processStartTime":1700000001,\
            "port":49213,"streamsInFlight":0,"routeCount":0}
            """
        let decoded = try ModelProxyStatus.decodeStatusResponse(Data(legacy.utf8))
        #expect(decoded.home == "")
        // The rest of the payload still arrives, which is the point of not
        // failing the decode.
        #expect(decoded.version == "old")
        #expect(decoded.pid == 42)
        #expect(decoded.port == 49213)
    }

    /// A key that is present but null is the same case as an absent one.
    @Test func anExplicitlyNullHomeDecodesToAnEmptyHome() throws {
        let payload = """
            {"version":"old","pid":42,"processStartTime":1700000001,\
            "port":49213,"streamsInFlight":0,"routeCount":0,"home":null}
            """
        let decoded = try ModelProxyStatus.decodeStatusResponse(Data(payload.utf8))
        #expect(decoded.home == "")
    }

    /// Both sides canonicalize through this one function, so a home reached
    /// through a symlink compares equal to the directory it resolves to.
    @Test func canonicalHomeResolvesSymlinksAndDotSegments() throws {
        let fenced = ProcessInfo.processInfo.environment["TBD_TEST_SCRATCH_ROOT"] ?? ""
        let base = fenced.isEmpty ? FileManager.default.temporaryDirectory.path : fenced
        let root = URL(fileURLWithPath: "\(base)/mpstatus-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let canonical = ModelProxyStatus.canonicalHome(real.path)
        // The symlink resolves to the same string the real path canonicalizes
        // to — and the raw link path is a different string, which is what
        // makes this discriminating.
        #expect(ModelProxyStatus.canonicalHome(link.path) == canonical)
        #expect(link.path != canonical)
        // `..` and `.` go first, and against real directories on either
        // side of them, so the answer is the same directory.
        #expect(ModelProxyStatus.canonicalHome(root.path + "/real/../real/.") == canonical)
        // Idempotent, so a daemon may canonicalize a value it already did.
        #expect(ModelProxyStatus.canonicalHome(canonical) == canonical)
    }
}
