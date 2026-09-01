import Foundation

/// Where a holder listens, and where its creation lock lives.
///
/// The layout — socket name, lock name, and the fact that they are siblings —
/// is frozen at protocol v1 and sits outside version negotiation, because a
/// spawner must interpret it *before* any connection exists, which is exactly
/// when no version has been exchanged.
///
/// Every path here is derived from `TBDConstants`, never composed from `$HOME`:
/// a hand-built `"\(home)/tbd/…"` silently ignores `TBD_HOME` and writes into
/// the developer's real store under `scripts/test.sh`.
public enum HolderRendezvous {
    /// Darwin's `sockaddr_un.sun_path` is 104 bytes including the NUL.
    public static let sunPathLimit = 104

    public enum Error: LocalizedError, Equatable {
        /// The derived path does not fit `sun_path`. Raised at derivation time
        /// on purpose: the alternative is a confusing `EINVAL` out of `bind()`
        /// or `connect()` much later, in a caller that has no idea the path was
        /// the problem.
        case socketPathTooLong(path: String, limit: Int)

        public var errorDescription: String? {
            switch self {
            case .socketPathTooLong(let path, let limit):
                return "holder socket path is \(path.utf8.count) bytes, over the "
                    + "\(limit)-byte sun_path limit: \(path)"
            }
        }
    }

    public static func socketPath(
        sessionID: UUID,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        try validated(path(sessionID: sessionID, ext: "sock", environment: environment))
    }

    public static func lockPath(
        sessionID: UUID,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        // The lock path is validated against the same budget even though it is
        // never bound, so a lock and its socket can never disagree about
        // whether this session is representable.
        try validated(path(sessionID: sessionID, ext: "lock", environment: environment))
    }

    /// Where the holder's stderr is redirected. Not validated against
    /// `sun_path`: it is never bound, and a session whose socket already fits
    /// has a log path of the same length. Unlike the socket and the lock this
    /// file has no protocol role at all — it exists so a holder that dies
    /// before it can answer still leaves a reason behind — but it is named and
    /// placed by the same rule, so it belongs in the same one place rather than
    /// being re-composed by each caller.
    public static func logPath(
        sessionID: UUID,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        path(sessionID: sessionID, ext: "log", environment: environment)
    }

    /// Extensions of every file one session may leave in the holders
    /// directory. The socket comes first because it is the one the reconciler
    /// decides on; the rest are swept as its siblings.
    public static let fileExtensions = ["sock", "lock", "log"]

    private static func path(sessionID: UUID, ext: String, environment: [String: String]) -> String {
        TBDConstants.holdersDir(environment: environment)
            .appendingPathComponent("\(sessionID.uuidString.lowercased()).\(ext)")
            .path
    }

    private static func validated(_ path: String) throws -> String {
        guard path.utf8.count < sunPathLimit else {
            throw Error.socketPathTooLong(path: path, limit: sunPathLimit)
        }
        return path
    }
}
