import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "gc")

/// One holder's residue in the rendezvous directory, keyed by its socket.
///
/// The socket is the only member the reconciler decides on. The lock and the
/// log are unlinked as its siblings and never on their own — see
/// `HolderRendezvousCollector` for why that asymmetry is deliberate.
public struct HolderRendezvousCandidate: Sendable, Equatable {
    public var sessionID: UUID
    public var socketPath: String
    /// Socket creation date, or `nil` when it could not be read — which the
    /// grace gate treats as "too young to touch".
    public var createdAt: Date?

    public init(sessionID: UUID, socketPath: String, createdAt: Date?) {
        self.sessionID = sessionID
        self.socketPath = socketPath
        self.createdAt = createdAt
    }
}

/// Outcome of gating one candidate. `reason` is one of `"unknown-age"`,
/// `"grace"`, `"lock-held"`, `"listening"`.
public enum HolderRendezvousDecision: Sendable, Equatable {
    case keep(reason: String)
    case reap
}

/// The named reconciler for holder rendezvous files: the `<uuid>.sock` a pty
/// holder left in `~/tbd/holders` when it died without unlinking it, plus that
/// session's sibling `<uuid>.lock` and `<uuid>.log`
/// (`docs/specs/2026-08-30-pty-holder-session-transport-design.md`,
/// "Reconciliation").
///
/// **The socket sweep is mandatory, not hygienic.** A holder that exits
/// normally unlinks its own socket; one that takes a `SIGKILL` cannot, and
/// nothing else ever will — `bind` refuses an existing path, so unlike tmux
/// there is not even a lazy unlink-on-rebind. The measured tmux precedent on
/// this machine was ~7,100 dead socket files accumulated in nine days. Without
/// this sweep the holder transport leaks a file triple per session forever.
///
/// **The lock and the log are swept as siblings of a socket being reaped,
/// never on their own.** For the lock that asymmetry is a safety property, not
/// tidiness: `HolderLock` deliberately leaves its file behind on release
/// because unlinking a lock somebody holds lets a racing spawner create and
/// lock a *different* file at the same path — two holders for one session.
/// Anchoring every unlink to a socket the sweep has already proven dead keeps
/// this collector out of that race, and the `lock-held` gate closes it even
/// when a spawn is in flight over an old socket. For the log the reasoning is
/// the same shape: a log with no socket may belong to a holder still being
/// born, whose socket is about to appear.
///
/// **The log is swept, though the design spec predates it.** It is created by
/// `HolderSpawner` under the same `<session-uuid>.<ext>` rule in the same
/// directory, has no writer once the holder is dead, and accumulates one file
/// per session exactly like the socket — the identical unbounded leak, so
/// excluding it would fix two thirds of a three-file leak and call the resource
/// reconciled. Its only competing value is postmortem, and that value is
/// already spent by the time this sweep can fire: the spawner reads the log
/// synchronously on a spawn failure (`resolveUnreachableHolder`), while the
/// sweep only reaches a socket whose holder is provably not listening *and*
/// older than the GC grace window. That window is the log's retention.
///
/// Every failure direction is toward keeping: an unreadable creation date, a
/// held lock, an unreadable listing, an ambiguous connect and a failed unlink
/// all leave the files where they are for the next sweep to reconsider.
///
/// This type never reads the database, the same division of labor
/// `ProfileDirCollector` and `DeletionQueueCollector` keep with `OrphanGC`. It
/// deliberately does not need to: this sweep answers "is anything behind this
/// socket", which is a question about the process table and not about intent.
/// The holder-versus-database check the spec also describes is a separate
/// reconciler leg and is not this one.
public struct HolderRendezvousCollector: Sendable {
    let base: URL
    let now: @Sendable () -> Date
    /// Whether something is listening on a socket path. Injected so a test can
    /// pin the answer; production is `Self.probeForListener`, which is
    /// `HolderSpawner.someoneIsListening` with the same fail-toward-keeping
    /// reading of an ambiguous result.
    let isListening: @Sendable (String) async -> Bool

    public init(
        base: URL,
        now: @escaping @Sendable () -> Date = Date.init,
        isListening: @escaping @Sendable (String) async -> Bool = HolderRendezvousCollector
            .probeForListener
    ) {
        self.base = base
        self.now = now
        self.isListening = isListening
    }

    /// Immediate children named `<uuid>.sock`. A name whose stem does not parse
    /// as a UUID, a directory, and every other extension are not candidates;
    /// an unreadable or missing base yields none.
    public func candidates() -> [HolderRendezvousCandidate] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else {
            return []
        }
        return names.compactMap { name -> HolderRendezvousCandidate? in
            guard name.hasSuffix(".sock"),
                  let id = UUID(uuidString: String(name.dropLast(".sock".count)))
            else { return nil }
            let url = base.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  !isDir.boolValue else { return nil }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return HolderRendezvousCandidate(
                sessionID: id, socketPath: url.path,
                createdAt: attributes?[.creationDate] as? Date)
        }.sorted { $0.socketPath < $1.socketPath }
    }

    /// Gate order: age → lock → listener. Every gate fails toward keeping.
    ///
    /// Age comes first because it is a `stat` and because it is the gate that
    /// exists for a race rather than for a fact: `OrphanGC` runs on demand from
    /// RPC handlers, so a sweep can land in the window between a holder binding
    /// its socket and the rest of creation committing, and reaping there would
    /// destroy a session being born. A young socket is therefore left alone
    /// whatever the other two gates would have said.
    ///
    /// The lock gate comes before the listener probe because it is a
    /// non-blocking `flock` rather than a connect with a timeout, and because
    /// it answers a strictly wider question: a holder holds its lock for its
    /// whole life, and so does a spawner that has taken the lock but not yet
    /// launched — a state in which no socket of ours is listening yet.
    public func decide(
        _ candidate: HolderRendezvousCandidate,
        graceSeconds: Int
    ) async -> HolderRendezvousDecision {
        guard let created = candidate.createdAt else {
            return .keep(reason: "unknown-age")
        }
        if now().timeIntervalSince(created) < Double(graceSeconds) {
            return .keep(reason: "grace")
        }
        if lockIsHeld(sessionID: candidate.sessionID) {
            return .keep(reason: "lock-held")
        }
        if await isListening(candidate.socketPath) {
            return .keep(reason: "listening")
        }
        return .reap
    }

    /// Unlinks the socket and its siblings, and returns the paths that are gone
    /// as a result. A missing sibling is not a failure — the common case is a
    /// holder that got far enough to bind but never wrote a log.
    ///
    /// Anchored first, the same guard `ProfileDirCollector.reap` keeps in front
    /// of its rename: `candidates()` only ever produces anchored candidates,
    /// but `HolderRendezvousCandidate` is a public value type anyone can
    /// construct, so the invariant is checked rather than assumed.
    @discardableResult
    public func reap(_ candidate: HolderRendezvousCandidate) -> [String] {
        guard isAnchored(candidate) else {
            logger.warning("""
            gc: refusing to unlink \(candidate.socketPath, privacy: .public) — not a \
            \(candidate.sessionID.uuidString.lowercased(), privacy: .public).sock immediate child \
            of \(self.base.path, privacy: .public)
            """)
            return []
        }
        var removed: [String] = []
        for ext in HolderRendezvous.fileExtensions {
            let path = base.appendingPathComponent(
                "\(candidate.sessionID.uuidString.lowercased()).\(ext)").path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if unlink(path) == 0 {
                removed.append(path)
            } else {
                let code = errno
                logger.warning("""
                gc: could not unlink \(path, privacy: .public): \
                \(String(cString: strerror(code)), privacy: .public) (errno \(code, privacy: .public))
                """)
            }
        }
        if !removed.isEmpty {
            logger.info("""
            gc: unlinked holder rendezvous for session \
            \(candidate.sessionID.uuidString, privacy: .public): \
            \(removed.joined(separator: " "), privacy: .public)
            """)
        }
        return removed
    }

    // MARK: - Liveness

    /// Whether some process holds this session's creation lock.
    ///
    /// Never creates the file: `O_CREAT` here would materialise a lock file for
    /// a session that has none and then immediately sweep it, and worse, it
    /// would make "no lock file" indistinguishable from "lock free". A missing
    /// file means nobody holds it. The probe takes the lock only to learn
    /// whether it could, and drops it on the same line — closing the descriptor
    /// releases it, so no window is left in which this process is the holder of
    /// record.
    func lockIsHeld(sessionID: UUID) -> Bool {
        let path = base.appendingPathComponent(
            "\(sessionID.uuidString.lowercased()).lock").path
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            // ENOENT is "no lock file, so nobody holds it". Anything else is an
            // unreadable answer, and an unreadable answer keeps.
            return errno != ENOENT
        }
        defer { close(fd) }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let saved = errno
            if saved == EINTR { continue }
            // EWOULDBLOCK is a live holder or a spawner mid-flight. Any other
            // failure is an unreadable answer, and both keep.
            return true
        }
        flock(fd, LOCK_UN)
        return false
    }

    /// The production listener probe: connect and ask. Deliberately the same
    /// reading `HolderSpawner.someoneIsListening` takes, because the two ask the
    /// same question for opposite reasons and must not disagree — a rejected
    /// handshake means a live holder owned by somebody else, and a connect that
    /// succeeds but answers nothing means *something* has that path open.
    /// Only `ECONNREFUSED` (bound, nobody accepting) and `ENOENT` (gone since
    /// the listing) are evidence of absence.
    public static let probeForListener: @Sendable (String) async -> Bool = { socketPath in
        let client = HolderClient(socketPath: socketPath, receiveTimeout: probeTimeout)
        let answer: Bool
        do {
            _ = try await client.describe()
            answer = true
        } catch HolderClient.Error.rejected {
            answer = true
        } catch HolderClient.Error.cannotConnect(_, let code) {
            answer = !(code == ECONNREFUSED || code == ENOENT)
        } catch {
            answer = true
        }
        await client.close()
        return answer
    }

    /// Bounded well under the hourly sweep interval: a stranger that connects
    /// but never answers must not stall a sweep that may have hundreds of
    /// candidates on its first run after this ships.
    static let probeTimeout: Duration = .seconds(2)

    /// The candidate names an immediate child of `base` called
    /// `<sessionID>.sock` — exactly what `candidates()` produces. Requiring the
    /// parent to *equal* `base` rejects anything nested, along with any `..`,
    /// which no longer resolves to `base` once the last component is dropped.
    private func isAnchored(_ candidate: HolderRendezvousCandidate) -> Bool {
        let url = URL(fileURLWithPath: candidate.socketPath)
        guard url.deletingLastPathComponent().path == base.path else { return false }
        return url.lastPathComponent == "\(candidate.sessionID.uuidString.lowercased()).sock"
    }
}
