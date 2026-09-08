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
    /// The one coder pair for `GET /tbd/status`.
    ///
    /// Pinned to ISO-8601 for the same reason a route file is
    /// (`ModelProxyRoute.encodedForRouteFile`): the proxy writes this and the
    /// daemon reads it, out of two binaries that are upgraded independently,
    /// and a writer on `.deferredToDate` against a reader on `.iso8601` would
    /// turn `processStartTime` into a value the adoption check can only refuse.
    /// Adoption is exactly the decision that hangs on this field, so the
    /// disagreement would not fail loudly — it would quietly mint a new port
    /// and orphan the running proxy.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
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
