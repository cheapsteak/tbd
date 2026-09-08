import Foundation

/// What `GET /tbd/status` answers.
///
/// The daemon adopts a proxy that already holds the port only after matching
/// `pid` and `processStartTime` against the process table — the same identity
/// check `AgentReaper` makes before signalling anything, and the reason a pid
/// alone is not enough — and only after `home` matches its own, which is what
/// keeps it from adopting a live proxy that belongs to a different TBD home.
public struct ModelProxyStatus: Codable, Sendable, Equatable {
    /// `TBDModelProxy`'s build identity, so the daemon can tell a proxy built
    /// from its own tree from one left behind by an older install.
    public let version: String
    public let pid: Int32
    public let processStartTime: Date
    public let port: Int
    public let streamsInFlight: Int
    public let routeCount: Int
    /// The TBD home this proxy serves, canonicalized by `canonicalHome`.
    ///
    /// Two TBD homes on one machine — a second checkout, a test fence, a
    /// second account's install — each run their own proxy, and both draw
    /// their port from the same ephemeral range. Nothing stops the kernel from
    /// handing one of them the port the other's config row still names, and
    /// every other field in this payload would happily match: the pid and
    /// start time describe a real, live TBD proxy, and a same-version install
    /// reports the same `version`. The home is what makes the two
    /// distinguishable, so a daemon adopts the process holding its port only
    /// when this equals its own home in canonical form.
    ///
    /// Empty means the proxy did not report one, which is an older image than
    /// this field. A daemon reads that as "not mine" and mints a fresh port
    /// rather than adopting a process it cannot place.
    public let home: String

    public init(
        version: String,
        pid: Int32,
        processStartTime: Date,
        port: Int,
        streamsInFlight: Int,
        routeCount: Int,
        home: String
    ) {
        self.version = version
        self.pid = pid
        self.processStartTime = processStartTime
        self.port = port
        self.streamsInFlight = streamsInFlight
        self.routeCount = routeCount
        self.home = home
    }

    /// The one form of a TBD home path both sides compare.
    ///
    /// A home reaches the proxy as whatever the daemon put on its command
    /// line, and reaches the daemon as whatever `TBD_HOME` or the default
    /// composed — `~/tbd`, `/tmp/x/../x/tbd`, a path through `/var` when the
    /// real directory is under `/private/var`. Those are the same directory
    /// and must compare equal, so both sides run the path through this before
    /// comparing: `..` and `.` go first, lexically, and then every symlink in
    /// what remains is resolved against the filesystem.
    public static func canonicalHome(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

// MARK: - Decoding

extension ModelProxyStatus {
    private enum CodingKeys: String, CodingKey {
        case version, pid, processStartTime, port, streamsInFlight, routeCount, home
    }

    /// Hand-written for one field: `home` is absent from what a proxy built
    /// before it reported, and that payload must still decode. It arrives as
    /// `""`, which every reader treats as "this proxy did not say", rather
    /// than failing the whole decode and leaving the daemon unable to read
    /// even the pid of the process holding its port.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        pid = try container.decode(Int32.self, forKey: .pid)
        processStartTime = try container.decode(Date.self, forKey: .processStartTime)
        port = try container.decode(Int.self, forKey: .port)
        streamsInFlight = try container.decode(Int.self, forKey: .streamsInFlight)
        routeCount = try container.decode(Int.self, forKey: .routeCount)
        home = try container.decodeIfPresent(String.self, forKey: .home) ?? ""
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
