import Foundation
import GRDB
import os
import TBDShared

private let artifactLogger = Logger(subsystem: "com.tbd.daemon", category: "shadowPeer")

// MARK: - One daemon lifetime

/// The identity of one daemon lifetime, minted once per process.
///
/// A shadow peer's three artifacts outlive the daemon that made them whenever
/// the daemon dies without unwinding — a `SIGKILL`, a panic, a machine that
/// lost power. Stamping every row with the generation that published it is what
/// makes those artifacts recognisable on the next boot: a row from another
/// generation describes a helper this daemon never spawned and no live link is
/// carrying, which is the one class `ShadowPeerReconciler` may reclaim without
/// consulting a bridge at all.
///
/// A UUID rather than the daemon's pid, because pids are recycled — the same
/// hazard this whole reclaimer exists to answer, and it would be perverse to
/// build the generation stamp out of it.
public enum ShadowPeerDaemonGeneration {
    public static let current: String = UUID().uuidString
}

// MARK: - The durable row

/// One shadow peer's three durable artifacts, as TBD's own bookkeeping recorded
/// them: the helper process, the socket it bound, and the record it published.
///
/// **This is the whitelist, and it is the only recognition TBD has.** A shadow's
/// record carries no field Claude Code does not itself define (an unknown key
/// was measured to make a record invisible to every listing while surviving on
/// disk), so nothing inside a record marks it as TBD's, and a path tells
/// nothing either — every session on the machine binds into the same directory.
/// `ShadowPeerReconciler` reclaims against these rows and nothing else, which is
/// the design's "MUST NOT reclaim by inference" expressed as a data structure.
public struct ShadowPeerArtifact: Codable, Sendable, Equatable {
    /// The helper's own real pid. Both file artifacts are named after it, and
    /// at most one process holds it at a time, so it is the row's key.
    public let pid: pid_t
    /// The provider whose peer link this shadow rides.
    public let provider: String
    /// The handle the provider minted for the remote session. Meaningless
    /// outside the connection that announced it, and kept only so a sweep can
    /// say which shadow it reclaimed.
    public let handle: String
    /// `<provider>:<worktree display name>` — what the record was published as.
    public let name: String
    /// The `sessionId` inside the published record. **The proof of ownership
    /// for the record artifact**: a file at `recordPath` whose session id is not
    /// this one belongs to somebody else (a recycled pid's real session, most
    /// plausibly) and must never be unlinked.
    public let sessionID: String
    /// The kernel's start time for `pid` at publication, in `procStart`'s own
    /// format. Nil when the kernel refused the read, which reads as "cannot
    /// prove this pid is still ours" — a reason never to signal it.
    public let procStart: String?
    public let socketPath: String
    public let recordPath: String
    /// The daemon lifetime that published this. See `ShadowPeerDaemonGeneration`.
    public let daemonGeneration: String
    /// When the row was written. Compared against a grace window so a shadow
    /// published moments ago is never mistaken for an orphan by a sweep that
    /// read the bridge's inventory a heartbeat earlier.
    public let publishedAt: Date

    public init(
        pid: pid_t, provider: String, handle: String, name: String, sessionID: String,
        procStart: String?, socketPath: String, recordPath: String,
        daemonGeneration: String, publishedAt: Date
    ) {
        self.pid = pid
        self.provider = provider
        self.handle = handle
        self.name = name
        self.sessionID = sessionID
        self.procStart = procStart
        self.socketPath = socketPath
        self.recordPath = recordPath
        self.daemonGeneration = daemonGeneration
        self.publishedAt = publishedAt
    }
}

/// GRDB Record type for the `shadow_peer_artifact` table
/// (`20260830022625_shadow_peer_artifacts`).
struct ShadowPeerArtifactRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "shadow_peer_artifact"

    var pid: Int64
    var provider: String
    var handle: String
    var name: String
    var session_id: String
    var proc_start: String?
    var socket_path: String
    var record_path: String
    var daemon_generation: String
    var published_at: Date

    init(from artifact: ShadowPeerArtifact) {
        self.pid = Int64(artifact.pid)
        self.provider = artifact.provider
        self.handle = artifact.handle
        self.name = artifact.name
        self.session_id = artifact.sessionID
        self.proc_start = artifact.procStart
        self.socket_path = artifact.socketPath
        self.record_path = artifact.recordPath
        self.daemon_generation = artifact.daemonGeneration
        self.published_at = artifact.publishedAt
    }

    func toModel() -> ShadowPeerArtifact {
        ShadowPeerArtifact(
            pid: pid_t(truncatingIfNeeded: pid),
            provider: provider,
            handle: handle,
            name: name,
            sessionID: session_id,
            procStart: proc_start,
            socketPath: socket_path,
            recordPath: record_path,
            daemonGeneration: daemon_generation,
            publishedAt: published_at)
    }
}

// MARK: - Recording seam

/// Where a published shadow's artifacts get written down.
///
/// A protocol rather than the store itself so `ShadowPeerManager` — which is
/// about handles, frames and helpers — takes no database dependency, and so the
/// facts it reports are exactly the facts it holds. Everything else on the row
/// (the generation stamp, the kernel start time, the clock) is the recorder's,
/// because those belong to the bookkeeping rather than to the bridge.
///
/// Deliberately non-throwing: a database hiccup must not fail a publish. It
/// costs a row, which costs the reclaimer its recognition of one shadow, and
/// that is a leak — strictly better than refusing to bridge a session.
public protocol ShadowPeerArtifactRecording: Sendable {
    func recordPublished(
        provider: String, handle: String, name: String, pid: pid_t,
        sessionID: String, socketPath: String, recordPath: String) async
    /// Forget one helper's row, once its artifacts are gone.
    func forgetPublished(pid: pid_t) async
}

/// Records nothing.
///
/// For tests and for a `ShadowPeerManager` built without a database. **Never
/// production wiring**: a shadow published through this recorder is one nothing
/// can recognise afterwards, so its helper, socket and record are unreclaimable
/// by design rather than by accident.
public struct UnrecordedShadowPeerArtifacts: ShadowPeerArtifactRecording {
    public init() {}
    public func recordPublished(
        provider: String, handle: String, name: String, pid: pid_t,
        sessionID: String, socketPath: String, recordPath: String
    ) async {}
    public func forgetPublished(pid: pid_t) async {}
}

// MARK: - Store

/// Reads and writes the shadow-peer whitelist.
public struct ShadowPeerArtifactStore: Sendable, ShadowPeerArtifactRecording {
    let writer: any DatabaseWriter
    /// The generation stamped on every row this store records.
    let generation: String
    /// The kernel start time for a pid. Injected so a test can pin it; the
    /// production default reads the kernel, never "now" — a fabricated
    /// `procStart` is precisely the value the recycled-pid check exists to
    /// catch.
    let procStart: @Sendable (pid_t) -> String?
    let now: @Sendable () -> Date

    init(
        writer: any DatabaseWriter,
        generation: String = ShadowPeerDaemonGeneration.current,
        procStart: @escaping @Sendable (pid_t) -> String? = { ProcessStartTime.procStart(pid: $0) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.writer = writer
        self.generation = generation
        self.procStart = procStart
        self.now = now
    }

    /// Write one row, replacing any row already filed under that pid.
    ///
    /// Replacing is the correct resolution rather than a lossy one: a pid TBD
    /// has just spawned a helper under is a pid whose previous occupant is
    /// provably gone, and both file artifacts are named after the pid, so the
    /// new helper's record and socket sit at exactly the paths the old row
    /// named.
    public func upsert(_ artifact: ShadowPeerArtifact) async throws {
        let row = ShadowPeerArtifactRecord(from: artifact)
        try await writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO shadow_peer_artifact
                        (pid, provider, handle, name, session_id, proc_start,
                         socket_path, record_path, daemon_generation, published_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(pid) DO UPDATE SET
                        provider = excluded.provider,
                        handle = excluded.handle,
                        name = excluded.name,
                        session_id = excluded.session_id,
                        proc_start = excluded.proc_start,
                        socket_path = excluded.socket_path,
                        record_path = excluded.record_path,
                        daemon_generation = excluded.daemon_generation,
                        published_at = excluded.published_at
                    """,
                arguments: [
                    row.pid, row.provider, row.handle, row.name, row.session_id,
                    row.proc_start, row.socket_path, row.record_path,
                    row.daemon_generation, row.published_at,
                ])
        }
    }

    /// The whole whitelist, in pid order so a sweep's log reads the same way
    /// twice.
    public func all() async throws -> [ShadowPeerArtifact] {
        try await writer.read { db in
            try ShadowPeerArtifactRecord
                .order(Column("pid"))
                .fetchAll(db)
                .map { $0.toModel() }
        }
    }

    public func get(pid: pid_t) async throws -> ShadowPeerArtifact? {
        try await writer.read { db in
            try ShadowPeerArtifactRecord
                .filter(Column("pid") == Int64(pid))
                .fetchOne(db)?
                .toModel()
        }
    }

    public func forget(pid: pid_t) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM shadow_peer_artifact WHERE pid = ?",
                arguments: [Int64(pid)])
        }
    }

    // MARK: - ShadowPeerArtifactRecording

    public func recordPublished(
        provider: String, handle: String, name: String, pid: pid_t,
        sessionID: String, socketPath: String, recordPath: String
    ) async {
        let artifact = ShadowPeerArtifact(
            pid: pid, provider: provider, handle: handle, name: name, sessionID: sessionID,
            procStart: procStart(pid), socketPath: socketPath, recordPath: recordPath,
            daemonGeneration: generation, publishedAt: now())
        do {
            try await upsert(artifact)
        } catch {
            artifactLogger.error("""
                could not record shadow \(handle, privacy: .public) (pid \(pid, privacy: .public)) \
                in the reclaimer's whitelist: \(error.localizedDescription, privacy: .public). \
                Its helper, socket and record are now unrecognisable to \
                ShadowPeerReconciler and will have to be reclaimed by hand
                """)
        }
    }

    public func forgetPublished(pid: pid_t) async {
        do {
            try await forget(pid: pid)
        } catch {
            artifactLogger.error("""
                could not forget shadow peer pid \(pid, privacy: .public): \
                \(error.localizedDescription, privacy: .public). The next sweep will find the row \
                again and reclaim whatever is left of it
                """)
        }
    }
}
