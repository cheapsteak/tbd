import Foundation
import TBDShared
import os

/// The proxy's in-memory view of `routes/`.
///
/// Every forwarding decision the proxy makes — which upstream, which terminal,
/// whether to tee — comes from here and from nowhere else. A request carries a
/// token and nothing more; the table turns that token into a route or refuses
/// it. That is what keeps the proxy from being an open forwarder for any other
/// local process, so the table is deliberately the only thing that reads a
/// route file, and it validates a token before the token ever composes a path.
///
/// An actor rather than a lock-guarded class: `add` and `remove` do file I/O,
/// and the mutual exclusion has to span the read *and* the store so a route
/// dropped mid-load cannot come back.
actor RouteTable {
    /// Why a route could not be taken.
    ///
    /// Cases carry the token rather than the path: a token is 32 hex
    /// characters and safe to log, while the path adds nothing a reader of the
    /// proxy's home does not already know.
    enum RouteError: LocalizedError, Equatable {
        case invalidToken(String)
        case unreadable(String)
        case malformed(String, String)
        case unsupportedVersion(String, Int)
        case tokenMismatch(String, String)
        case invalidUpstream(String)

        var errorDescription: String? {
            switch self {
            case .invalidToken(let token):
                return "route token is not 32 lowercase hex characters: \(token)"
            case .unreadable(let token):
                return "route file for \(token) could not be read"
            case .malformed(let token, let detail):
                return "route file for \(token) is malformed: \(detail)"
            case .unsupportedVersion(let token, let version):
                return "route file for \(token) has unsupported schema version \(version)"
            case .tokenMismatch(let token, let inner):
                return "route file \(token).json names token \(inner)"
            case .invalidUpstream(let token):
                return "route file for \(token) has no usable http(s) upstream"
            }
        }
    }

    private static let log = Logger(subsystem: "com.tbd.modelproxy", category: "routes")

    private let routesDir: URL
    private let streamsDir: URL
    private let fileManager: FileManager
    private var routes: [String: ModelProxyRoute] = [:]
    /// Tokens whose file has already been reported bad, so a directory that
    /// holds one unreadable file does not log once per `loadAll`.
    private var reportedBad: Set<String> = []

    init(routesDir: URL, streamsDir: URL, fileManager: FileManager = .default) {
        self.routesDir = routesDir
        self.streamsDir = streamsDir
        self.fileManager = fileManager
    }

    var count: Int { routes.count }

    /// Reads every `*.json` under `routesDir`.
    ///
    /// A malformed file is skipped and logged once, never fatal: one bad route
    /// must not cost every other session its proxy. A missing directory is not
    /// an error either — it is what a TBD home looks like before the first
    /// session with a route is spawned. Only a directory that exists and
    /// cannot be listed throws, because that is a permissions problem the
    /// supervisor should see.
    func loadAll() throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: routesDir.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return
        }

        let entries = try fileManager.contentsOfDirectory(
            at: routesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

        for entry in entries where entry.pathExtension == "json" {
            let token = entry.deletingPathExtension().lastPathComponent
            do {
                _ = try add(token: token)
            } catch {
                report(token: token, error: error)
            }
        }
        Self.log.debug("loaded \(self.routes.count, privacy: .public) route(s)")
    }

    /// Reads `routesDir/<token>.json` and takes the route it names.
    ///
    /// Re-reading a token already in the table replaces it, which is how a
    /// daemon that rewrote a route file makes the proxy notice.
    @discardableResult
    func add(token: String) throws -> ModelProxyRoute {
        // First, and before the token composes a path: the whitelist in
        // `isValidToken` is what stops `..` or a slash from reaching
        // `appendingPathComponent`.
        guard ModelProxyRoute.isValidToken(token) else {
            throw RouteError.invalidToken(token)
        }

        let url = routesDir.appendingPathComponent(
            TBDConstants.modelProxyRouteFileName(token: token))
        guard let data = fileManager.contents(atPath: url.path) else {
            throw RouteError.unreadable(token)
        }

        let route: ModelProxyRoute
        do {
            route = try ModelProxyRoute.decodeRouteFile(data)
        } catch {
            throw RouteError.malformed(token, "\(error)")
        }

        guard route.version == ModelProxyRoute.schemaVersion else {
            throw RouteError.unsupportedVersion(token, route.version)
        }
        // The file name is what a request names; the field inside is what the
        // tee and the upstream leg use. A mismatch means the two disagree
        // about which session this is, so the route is refused rather than
        // guessed at.
        guard route.token == token else {
            throw RouteError.tokenMismatch(token, route.token)
        }
        guard let upstream = URL(string: route.upstream),
            let scheme = upstream.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            upstream.host != nil
        else {
            throw RouteError.invalidUpstream(token)
        }

        routes[token] = route
        reportedBad.remove(token)
        return route
    }

    /// Drops a route and reclaims the two files it owns.
    ///
    /// Unlinking here is the creation-path half of the guarantee; the standing
    /// one is the `OrphanGC` leg the design names, because a proxy that is
    /// killed between the daemon's decision and this call leaves both files
    /// behind and no call site can be made to cover that.
    func remove(token: String) {
        guard ModelProxyRoute.isValidToken(token) else { return }
        let route = routes.removeValue(forKey: token)
        reportedBad.remove(token)

        try? fileManager.removeItem(
            at: routesDir.appendingPathComponent(
                TBDConstants.modelProxyRouteFileName(token: token)))
        if let terminalID = route?.terminalID {
            try? fileManager.removeItem(
                at: streamsDir.appendingPathComponent(
                    TBDConstants.streamFileName(terminalID: terminalID)))
        }
    }

    func route(for token: String) -> ModelProxyRoute? {
        routes[token]
    }

    private func report(token: String, error: Error) {
        guard reportedBad.insert(token).inserted else { return }
        Self.log.error(
            "skipping route: \(error.localizedDescription, privacy: .public)")
    }
}
