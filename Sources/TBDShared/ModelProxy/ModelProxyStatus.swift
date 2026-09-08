import Foundation

/// What `GET /tbd/status` answers.
///
/// The daemon adopts a proxy that already holds the port only after matching
/// `pid` and `processStartTime` against the process table — the same identity
/// check `AgentReaper` makes before signalling anything, and the reason a pid
/// alone is not enough.
public struct ModelProxyStatus: Codable, Sendable, Equatable {
    /// `TBDModelProxy`'s build identity, so the daemon can tell a proxy built
    /// from its own tree from one left behind by an older install.
    public let version: String
    public let pid: Int32
    public let processStartTime: Date
    public let port: Int
    public let streamsInFlight: Int
    public let routeCount: Int

    public init(
        version: String,
        pid: Int32,
        processStartTime: Date,
        port: Int,
        streamsInFlight: Int,
        routeCount: Int
    ) {
        self.version = version
        self.pid = pid
        self.processStartTime = processStartTime
        self.port = port
        self.streamsInFlight = streamsInFlight
        self.routeCount = routeCount
    }
}

// MARK: - Wire coding

extension ModelProxyStatus {
    /// The one coder pair for `GET /tbd/status`, pinned on both sides.
    ///
    /// The proxy writes this and the daemon reads it, out of two binaries that
    /// are upgraded independently, so the date strategy cannot be left to
    /// whichever `JSONEncoder` each side happens to construct: adoption is
    /// decided by comparing `processStartTime` against the process table, and a
    /// disagreement would not fail loudly — it would quietly mint a fresh port
    /// and orphan a live proxy.
    ///
    /// **Seconds since the epoch, not ISO-8601**, and that is the whole reason
    /// this differs from a route file. `ProcessStartTime.startTime` reads a
    /// `struct timeval` and returns microseconds; `.iso8601` renders whole
    /// seconds and would throw the fraction away, so a proxy started at
    /// `…:07.123456` would report `…:07` and never compare equal to what the
    /// daemon reads from the kernel. A `Double` of seconds round-trips the
    /// value the kernel gave, bit for bit. A route file's `createdAt` is
    /// nobody's equality test and stays human-readable.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    /// The body of a `GET /tbd/status` answer.
    public func encodedForStatusResponse() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    /// Decodes what `GET /tbd/status` answered.
    public static func decodeStatusResponse(_ data: Data) throws -> ModelProxyStatus {
        try makeDecoder().decode(ModelProxyStatus.self, from: data)
    }
}
