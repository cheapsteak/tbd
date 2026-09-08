import Darwin
import Foundation
import TBDShared
import os

/// The route and stream files for one TBD home, and the only code in the
/// daemon that composes their paths.
///
/// A route is a *file* before it is a registration (spec, "Routes"): the proxy
/// resolves the upstream, the terminal and the streaming decision from the
/// file alone, loads every file in the directory on start, and never learns
/// any of it from a request. So the write is the durable half of making a
/// route and the `POST /tbd/routes` that follows is only a notification — a
/// proxy that missed it picks the route up next time it starts.
///
/// Every path derives from `TBDConstants.*(environment:)` against one
/// `["TBD_HOME": home.path]` dictionary. Nothing here is composed from `$HOME`
/// or from a literal join, which is what keeps the test fence effective.
struct ModelProxyRouteStore: Sendable {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "model-proxy")

    enum Failure: LocalizedError, Equatable {
        case invalidToken(String)
        case renameFailed(errno: Int32)

        var errorDescription: String? {
            switch self {
            case .invalidToken(let token):
                return "refusing to write a route file for \(token): not a route token"
            case .renameFailed(let code):
                return "could not publish the route file: "
                    + "\(String(cString: strerror(code))) (errno \(code))"
            }
        }
    }

    let environment: [String: String]

    init(home: URL) {
        self.environment = ["TBD_HOME": home.path]
    }

    var routesDir: URL { TBDConstants.modelProxyRoutesDir(environment: environment) }

    func routePath(token: String) -> String {
        TBDConstants.modelProxyRoutePath(token: token, environment: environment)
    }

    func streamPath(terminalID: UUID) -> String {
        TBDConstants.streamFilePath(terminalID: terminalID, environment: environment)
    }

    // MARK: - Writing

    /// Writes `routes/<token>.json` atomically: a fresh temp **in the same
    /// directory**, then `rename(2)`.
    ///
    /// The reader is another process on its own schedule — the proxy reads the
    /// file when the registration arrives, and reads every file in the
    /// directory when it starts — so it must never be able to see a
    /// half-written one. A temp elsewhere could land on another volume, where
    /// the rename degrades into a tearable copy.
    ///
    /// Mode 0600, and the directory 0700: the token in the file is a
    /// capability. Anyone who can read it can drive this proxy at the route's
    /// upstream, and can learn which terminal a stream belongs to.
    func write(_ route: ModelProxyRoute) throws {
        guard ModelProxyRoute.isValidToken(route.token) else {
            throw Failure.invalidToken(route.token)
        }
        let destination = URL(fileURLWithPath: routePath(token: route.token))
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let data = try route.encodedForRouteFile()
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        guard rename(temporary.path, destination.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.renameFailed(errno: code)
        }
    }

    // MARK: - Unlinking

    /// Unlinks a route's two files, best effort.
    ///
    /// Only ever called when the proxy could **not** be asked to drop the
    /// route: a reachable proxy unlinks both itself, and doing it behind its
    /// back would pull the stream file out from under a tee that may still be
    /// appending to it.
    func unlink(token: String, terminalID: UUID) {
        if ModelProxyRoute.isValidToken(token) {
            try? FileManager.default.removeItem(atPath: routePath(token: token))
        } else {
            Self.logger.error(
                "not unlinking a route file for a token that is not one: \(token, privacy: .private)"
            )
        }
        try? FileManager.default.removeItem(atPath: streamPath(terminalID: terminalID))
    }

    // MARK: - Reading

    /// The token of the route naming `terminalID`, from one directory listing.
    ///
    /// The **file name** is the authority on what a token is, and a file whose
    /// contents name a different one is skipped: the name is what the proxy
    /// resolves a request path against, so a document claiming another token
    /// describes a route nobody can reach.
    ///
    /// A terminal should own at most one route, but a crash between writing a
    /// replacement and retiring its predecessor can leave two. The newest
    /// wins, because that is the one a live session was spawned against.
    func token(forTerminal terminalID: UUID) -> String? {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: routesDir.path) else {
            return nil
        }
        var newest: ModelProxyRoute?
        for name in names {
            guard name.hasSuffix(".json") else { continue }
            let token = String(name.dropLast(".json".count))
            guard ModelProxyRoute.isValidToken(token) else { continue }
            guard let data = manager.contents(atPath: routesDir.appendingPathComponent(name).path),
                let route = try? ModelProxyRoute.decodeRouteFile(data),
                route.token == token,
                route.terminalID == terminalID
            else { continue }
            if let current = newest {
                if route.createdAt > current.createdAt { newest = route }
            } else {
                newest = route
            }
        }
        return newest?.token
    }
}
