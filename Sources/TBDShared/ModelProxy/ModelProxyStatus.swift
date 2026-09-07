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
