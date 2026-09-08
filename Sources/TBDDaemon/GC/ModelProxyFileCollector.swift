import Foundation
import os
import TBDShared

private let modelProxyLogger = Logger(subsystem: "com.tbd.daemon", category: "gc")

/// One model-proxy file the sweep may reclaim: a route file or a stream file.
///
/// The two are one candidate type because the gates are the same for both — age,
/// then whether the terminal named by the file is still a session. What differs
/// is only where the terminal id comes from, and that is settled in
/// `candidates()` before any gate runs.
public struct ModelProxyFileCandidate: Sendable, Equatable {
    public var path: String
    /// The terminal this file belongs to, or `nil` when the file cannot say —
    /// a route file whose JSON does not decode, or a name that is not a UUID.
    /// Nil is not "keep": a file that names no terminal can be no terminal's,
    /// so the age gate is the only thing standing between it and the sweep.
    public var terminalID: UUID?
    /// Last modification date, or `nil` when it could not be read — which the
    /// grace gate treats as "too young to touch".
    public var modifiedAt: Date?

    public init(path: String, terminalID: UUID?, modifiedAt: Date?) {
        self.path = path
        self.terminalID = terminalID
        self.modifiedAt = modifiedAt
    }

    /// `path` in the form the **system log** may carry.
    ///
    /// A route file's name *is* its route token, and a route token is a bearer
    /// credential for that session's upstream: anything holding one can drive
    /// this proxy at the route's endpoint. The log is not the same audience as
    /// the filesystem — `routes/` is 0700 under a directory this user owns,
    /// while `log show` is readable by anything running as this user and a
    /// sysdiagnose routinely leaves the machine — so the token's tail is
    /// elided here, leaving the directory, enough of a prefix to correlate two
    /// lines about one file, and the extension.
    ///
    /// A stream file's name is a terminal UUID, which names a row this daemon
    /// logs by the thousand, so it passes through whole.
    ///
    /// Decided by extension rather than by directory because a candidate is a
    /// public value type anyone can construct, and the safe reading of an
    /// unanchored `.json` is "this might be a token".
    public var loggablePath: String {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension == ModelProxyFileCollector.routeExtension else { return path }
        let token = url.deletingPathExtension().lastPathComponent
        let shown = String(token.prefix(Self.loggableTokenPrefix))
        guard shown.count < token.count else { return path }
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(shown)….\(url.pathExtension)").path
    }

    /// How much of a route token a log line may name. Eight of the token's 32
    /// hex characters is 32 bits — enough that two lines about one file read as
    /// one file, and 96 bits short of anything a reader could use.
    static let loggableTokenPrefix = 8
}

/// Outcome of gating one candidate. `reason` is one of `"unknown-age"`,
/// `"grace"`, `"live-terminal"`.
public enum ModelProxyFileDecision: Sendable, Equatable {
    case keep(reason: String)
    case reap
}

/// The named reconciler for the model proxy's **route and stream files**
/// (`docs/specs/2026-09-05-transcript-streaming-model-proxy-design.md`,
/// "Durable resources and their reconcilers").
///
/// Both files are retired with their terminal on the creation path — a park, a
/// teardown, a delete and startup reconciliation all call
/// `ModelProxyRouteAttachment.retire`. This is the standing guarantee behind
/// that: the daemon can be `SIGKILL`ed between minting a route and recording
/// the row that names it, and a proxy that was killed while a stream was in
/// flight leaves a `.jsonl` nobody will ever truncate. Neither is reclaimable
/// by the retirement path, because there is no longer anything that knows the
/// file exists.
///
/// **Keep-biased in three directions, in gate order.** A file whose age cannot
/// be read is kept, because the grace window is the only defence against
/// reaping a session being born — `OrphanGC` runs on demand from RPC handlers,
/// so a sweep can land between a route being written and its spawn committing.
/// A file younger than the grace window is kept for the same reason. A file
/// whose terminal is still a live session is kept whatever its age says: a
/// long-lived agent writes its route file once and never touches it again, so
/// mtime alone would reap the route out from under a session that has been
/// running for a day.
///
/// **The two files do not cost the same when that goes wrong, and the route
/// costs more.** A stream file reaped early loses the transcript's provisional
/// view of one turn — a display surface, and the session keeps talking. A route
/// file is load-bearing: the running proxy holds its table in memory and would
/// not notice, but every respawn and every version replacement rebuilds that
/// table by reading this directory (`Sources/TBDModelProxy/RouteTable.swift`),
/// so a route reaped from under a live session 404s that session's requests
/// from the next proxy restart onward — long after the sweep, with nothing
/// connecting the two. The gates above are keep-biased enough that this stays
/// theoretical, and it is why they are written to fail towards keeping.
///
/// **This leg never touches `proxy.lock`, `proxy.pid` or `proxy.log`, and the
/// omission is deliberate rather than pending.** Those three live in the proxy
/// directory itself, one level above `routes/`, and this collector is pointed
/// at `routes/` and `streams/` so it cannot enumerate them at all. The
/// tempting anchor — "nobody holds the lock, so the proxy is gone" — is
/// **wrong** for this rendezvous: a retiring proxy releases its lock the moment
/// it closes its listener and then drains in-flight streams for up to ten
/// minutes (spec, "Retention"), so an unheld lock routinely names a process
/// that is very much alive, and unlinking its pid file or its log would take
/// the record away from the thing still writing it. Rendezvous residue belongs
/// to a future leg anchored on **pid liveness** — read `proxy.pid`, confirm the
/// process through `ProcessIdentityCheck`, and only then sweep the triple —
/// which is a different question from the one this collector asks, and needs
/// its own soak.
///
/// This type never reads the database. `OrphanGC` passes the live terminal ids
/// in, the same division of labour `HolderRendezvousCollector` and
/// `ProfileDirCollector` keep with it.
public struct ModelProxyFileCollector: Sendable {
    /// `~/tbd/proxy/routes`. Only this directory is enumerated, never its
    /// parent — see the type's note on the rendezvous triple.
    let routesDir: URL
    /// `~/tbd/streams`, a sibling of the proxy directory rather than a child:
    /// the proxy writes these files and the app reads them, and they outlive
    /// any one proxy image.
    let streamsDir: URL
    let now: @Sendable () -> Date

    static let routeExtension = "json"
    static let streamExtension = "jsonl"

    public init(
        routesDir: URL,
        streamsDir: URL,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.routesDir = routesDir
        self.streamsDir = streamsDir
        self.now = now
    }

    /// Every `routes/*.json` and every `streams/*.jsonl`, in path order.
    ///
    /// A route file names its terminal in its **contents**, because its name is
    /// the route token and a token says nothing about which session holds it. A
    /// stream file names its terminal in its **name**, which is the whole
    /// addressing scheme the app tails by. A route file that will not decode
    /// still becomes a candidate with a nil terminal id: it is a file the proxy
    /// itself would refuse, so leaving it out would make malformed route files
    /// the one shape of residue nothing reclaims.
    ///
    /// An unreadable or missing directory yields none. Directories, other
    /// extensions and the route store's own `.<name>.<uuid>.tmp` half-writes
    /// (which end in `.tmp`) are not candidates.
    public func candidates() -> [ModelProxyFileCandidate] {
        routeCandidates() + streamCandidates()
    }

    private func routeCandidates() -> [ModelProxyFileCandidate] {
        files(in: routesDir, extension: Self.routeExtension).map { url in
            ModelProxyFileCandidate(
                path: url.path,
                terminalID: Self.terminalID(ofRouteFileAt: url),
                modifiedAt: Self.modifiedAt(url))
        }
    }

    private func streamCandidates() -> [ModelProxyFileCandidate] {
        files(in: streamsDir, extension: Self.streamExtension).map { url in
            ModelProxyFileCandidate(
                path: url.path,
                terminalID: UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                modifiedAt: Self.modifiedAt(url))
        }
    }

    /// Immediate children of `directory` with exactly this extension, sorted by
    /// path. Nothing recursive: both directories are flat by construction, and
    /// a descent is how a sweep reaches files it was never pointed at.
    private func files(in directory: URL, extension ext: String) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: directory.path) else { return [] }
        return names.compactMap { name -> URL? in
            let url = directory.appendingPathComponent(name)
            guard url.pathExtension == ext else { return nil }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  !isDir.boolValue else { return nil }
            return url
        }.sorted { $0.path < $1.path }
    }

    private static func terminalID(ofRouteFileAt url: URL) -> UUID? {
        guard let data = try? Data(contentsOf: url),
              let route = try? ModelProxyRoute.decodeRouteFile(data) else { return nil }
        return route.terminalID
    }

    private static func modifiedAt(_ url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }

    /// Gate order: age → grace → live terminal. Every gate fails toward keeping.
    ///
    /// - Parameters:
    ///   - graceSeconds: `Config.gcGraceSeconds`, the same window every other
    ///     file leg uses.
    ///   - liveTerminalIDs: sessions that still exist and have not exited. A
    ///     file naming one of them is kept regardless of age; a file naming a
    ///     terminal that is not in the set, or naming none at all, is past the
    ///     only thing that could have saved it.
    public func decide(
        _ candidate: ModelProxyFileCandidate,
        graceSeconds: Int,
        liveTerminalIDs: Set<UUID>
    ) -> ModelProxyFileDecision {
        guard let modified = candidate.modifiedAt else {
            return .keep(reason: "unknown-age")
        }
        if now().timeIntervalSince(modified) < Double(graceSeconds) {
            return .keep(reason: "grace")
        }
        if let terminalID = candidate.terminalID, liveTerminalIDs.contains(terminalID) {
            return .keep(reason: "live-terminal")
        }
        return .reap
    }

    /// Unlinks one file, and answers whether it is gone as a result.
    ///
    /// Anchored first, the same guard `HolderRendezvousCollector.reap` keeps:
    /// `candidates()` only ever produces anchored candidates, but the candidate
    /// is a public value type anyone can construct, so the invariant is checked
    /// rather than assumed. A candidate that is not an immediate child of one of
    /// this collector's two directories, with the extension that directory
    /// takes, is refused — which is also the last line of defence keeping this
    /// leg away from `proxy.lock`, `proxy.pid` and `proxy.log`.
    @discardableResult
    public func reap(_ candidate: ModelProxyFileCandidate) -> Bool {
        guard isAnchored(candidate) else {
            modelProxyLogger.warning("""
            gc: refusing to unlink \(candidate.loggablePath, privacy: .public) — not a route or stream file \
            under \(self.routesDir.path, privacy: .public) or \(self.streamsDir.path, privacy: .public)
            """)
            return false
        }
        guard FileManager.default.fileExists(atPath: candidate.path) else { return false }
        guard unlink(candidate.path) == 0 else {
            let code = errno
            modelProxyLogger.warning("""
            gc: could not unlink \(candidate.loggablePath, privacy: .public): \
            \(String(cString: strerror(code)), privacy: .public) (errno \(code, privacy: .public))
            """)
            return false
        }
        modelProxyLogger.info(
            "gc: unlinked model proxy file \(candidate.loggablePath, privacy: .public)")
        return true
    }

    /// The candidate is an immediate child of `routesDir` with a `.json`
    /// extension, or of `streamsDir` with a `.jsonl` one. Requiring the parent
    /// to *equal* one of them rejects anything nested, along with any `..`,
    /// which no longer resolves to either once the last component is dropped.
    private func isAnchored(_ candidate: ModelProxyFileCandidate) -> Bool {
        let url = URL(fileURLWithPath: candidate.path)
        let parent = url.deletingLastPathComponent().path
        if parent == routesDir.path { return url.pathExtension == Self.routeExtension }
        if parent == streamsDir.path { return url.pathExtension == Self.streamExtension }
        return false
    }
}
