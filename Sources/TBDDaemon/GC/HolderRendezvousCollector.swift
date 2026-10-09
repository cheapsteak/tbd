import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "gc")

/// One holder's residue in the rendezvous directory, keyed by its socket.
///
/// The socket is the member this candidate is decided on; the lock and the log
/// are unlinked as its siblings. A lock and a log with no socket at all are
/// `HolderRendezvousOrphanPair` instead, decided on by their own gates — see
/// `HolderRendezvousCollector` for the two arms and what bounds each.
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

/// Outcome of gating one candidate, shared by both arms. `reason` is one of
/// `"unknown-age"`, `"grace"`, `"lock-held"`, `"listening"` (socket arm) or
/// `"has-row"` (socket-less arm).
public enum HolderRendezvousDecision: Sendable, Equatable {
    case keep(reason: String)
    case reap
}

/// One session's **socket-less** residue: a `<uuid>.lock`, a `<uuid>.log`, or
/// both, with no `<uuid>.sock` sibling in the directory.
///
/// Named by its lock path whether or not the lock file itself exists, so one
/// string identifies the pair in plans, in logs and in the anchoring check —
/// the role `socketPath` plays for `HolderRendezvousCandidate`.
public struct HolderRendezvousOrphanPair: Sendable, Equatable {
    public var sessionID: UUID
    public var lockPath: String
    /// The **newest** creation date among the files that exist, or `nil` when
    /// any of them could not be read — which the grace gate treats as "too
    /// young to touch". Newest rather than oldest because the gate asks whether
    /// anything recent has happened under this UUID, and the keep-biased answer
    /// to a week-old lock beside a log written a second ago is to wait.
    public var createdAt: Date?

    public init(sessionID: UUID, lockPath: String, createdAt: Date?) {
        self.sessionID = sessionID
        self.lockPath = lockPath
        self.createdAt = createdAt
    }
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
/// **Two arms read one directory.** The socket arm decides on a `<uuid>.sock`
/// and unlinks its `<uuid>.lock` and `<uuid>.log` siblings along with it. The
/// socket-less arm decides on a lock-and-log pair that has **no** socket —
/// the residue of a holder that got far enough to unlink its own socket, or
/// whose socket an earlier sweep already took. The socket arm structurally
/// cannot see that pair, so without the second arm a clean holder exit leaks
/// two files per session forever: measured on this machine, 557 such pairs
/// against 53 live sockets.
///
/// **What licenses unlinking a lock is never the lock's own freeness alone.**
/// `HolderLock` deliberately leaves its file behind on release, because
/// unlinking a lock somebody holds lets a racing spawner create and lock a
/// *different* file at the same path — two holders for one session. The socket
/// arm stays out of that race by anchoring every unlink to a socket it has
/// already proven dead. The socket-less arm has no such anchor, and **the lock
/// itself is what bounds it**: the flock is taken by the spawner before the
/// lock file's siblings exist, travels to the holder as an inherited
/// descriptor on the same open file description, and is released only by the
/// holder's death — so a spawn in flight, at every instant of it, presents a
/// held lock. The row gate and the grace window are the reinforcement, not the
/// argument: a fresh spawn's row is written *after* the holder
/// (`WorktreeLifecycle+SpawnTerminal`), so the row covers the wake and respawn
/// paths, where the row precedes the holder, and says of everything else that
/// TBD no longer knows the session. The grace window is defense in depth
/// against both, and a socket that appeared since the listing is a late gate in
/// front of the unlink itself.
///
/// The residual is a one-syscall-pair window: `lockIsHeld` reads a free lock,
/// a spawner takes it, and the unlink lands on the file that spawner holds. It
/// is accepted rather than closed, because closing it is not possible with
/// `flock` — holding the lock across the unlink leaves a waiting spawner
/// locking an unlinked inode, which is the same hazard — and because the
/// grace window makes the coincidence it needs (a spawn beginning for a UUID
/// whose residue is already an hour old) one nothing in the spawn path
/// produces.
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
        let removed = unlinkRendezvousFiles(
            sessionID: candidate.sessionID, extensions: HolderRendezvous.fileExtensions)
        if !removed.isEmpty {
            logger.info("""
            gc: unlinked holder rendezvous for session \
            \(candidate.sessionID.uuidString, privacy: .public): \
            \(removed.joined(separator: " "), privacy: .public)
            """)
        }
        return removed
    }

    // MARK: - The socket-less arm

    /// Immediate children named `<uuid>.lock` or `<uuid>.log` whose `<uuid>.sock`
    /// sibling is absent, grouped one pair per session. A name whose stem does
    /// not parse as a UUID, a directory, and every other extension are not
    /// candidates; an unreadable or missing base yields none — the same reading
    /// of the directory `candidates()` takes, because the two arms must agree
    /// about what lives there.
    ///
    /// The socket set is built from the same listing, so "has no socket" is
    /// answered against one snapshot rather than by a second `stat` that could
    /// disagree with the first. A socket that appears after the listing is
    /// caught by the late gate in `reapOrphanPair`.
    public func orphanPairCandidates() -> [HolderRendezvousOrphanPair] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: base.path) else { return [] }

        var socketIDs: Set<UUID> = []
        var residueIDs: Set<UUID> = []
        var newest: [UUID: Date] = [:]
        var unreadableAge: Set<UUID> = []
        for name in names {
            let matched = HolderRendezvous.fileExtensions.first { name.hasSuffix(".\($0)") }
            guard let ext = matched,
                  let id = UUID(uuidString: String(name.dropLast(ext.count + 1)))
            else { continue }
            let url = base.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }
            guard ext != "sock" else {
                socketIDs.insert(id)
                continue
            }
            residueIDs.insert(id)
            if let created = (try? fm.attributesOfItem(atPath: url.path))?[.creationDate] as? Date {
                newest[id] = newest[id].map { Swift.max($0, created) } ?? created
            } else {
                unreadableAge.insert(id)
            }
        }

        return residueIDs.subtracting(socketIDs).map { id in
            HolderRendezvousOrphanPair(
                sessionID: id, lockPath: lockPath(sessionID: id),
                createdAt: unreadableAge.contains(id) ? nil : newest[id])
        }.sorted { $0.lockPath < $1.lockPath }
    }

    /// Gate order: age → row → lock. Every gate fails toward keeping, and the
    /// pair's socket-lessness — established by `orphanPairCandidates()` — is
    /// the gate in front of all three.
    ///
    /// Age comes first for the reason it does in the socket arm: it is a `stat`
    /// already paid for by the listing, and it exists for a race rather than a
    /// fact. `OrphanGC` runs on demand from RPC handlers, so a sweep can land
    /// between a spawner creating the lock and the holder binding its socket,
    /// and reaping there would unlink a session's lock while it is being born.
    ///
    /// The row comes next because it is a set membership against rows read once
    /// for the whole phase. It is the gate that says TBD no longer knows this
    /// session, and it covers the wake and respawn paths, where the row exists
    /// before the holder does. It is **not** what protects a fresh spawn: that
    /// row is written after the holder (`WorktreeLifecycle+SpawnTerminal`), so
    /// mid-spawn a UUID legitimately has a lock, a log and no row.
    ///
    /// The lock probe comes last — the one syscall of the three — and is the
    /// same non-blocking acquisition the socket arm uses. It is the gate a
    /// fresh spawn is held by: a holder holds its lock for its whole life, and
    /// so does the spawner that took it before the holder existed, with no gap
    /// between them because the descriptor is inherited rather than reopened.
    /// It keeps whatever the grace window is configured to, which is why that
    /// window is reinforcement here and not the bound.
    ///
    /// - Parameter claimedSessionIDs: the ids of every session row that exists.
    ///   A pair in this set belongs to a session TBD still knows about.
    public func decideOrphanPair(
        _ pair: HolderRendezvousOrphanPair,
        graceSeconds: Int,
        claimedSessionIDs: Set<UUID>
    ) -> HolderRendezvousDecision {
        guard let created = pair.createdAt else {
            return .keep(reason: "unknown-age")
        }
        if now().timeIntervalSince(created) < Double(graceSeconds) {
            return .keep(reason: "grace")
        }
        if claimedSessionIDs.contains(pair.sessionID) {
            return .keep(reason: "has-row")
        }
        if lockIsHeld(sessionID: pair.sessionID) {
            return .keep(reason: "lock-held")
        }
        return .reap
    }

    /// Unlinks the lock and the log, and returns the paths that are gone as a
    /// result. **Never the socket**, which this arm has no verdict on: a socket
    /// at this path means the socket arm's gates are the ones that apply.
    ///
    /// Two guards in front, both refusing rather than proceeding:
    ///
    ///   - **Anchored**, the same check `reap` keeps: `orphanPairCandidates()`
    ///     only produces anchored pairs, but `HolderRendezvousOrphanPair` is a
    ///     public value type anyone can construct, so the invariant is checked
    ///     rather than assumed.
    ///   - **Still socket-less.** The gates ran against the listing; a spawner
    ///     that bound a socket since then owns this UUID, and its lock is not
    ///     ours to unlink.
    @discardableResult
    public func reapOrphanPair(_ pair: HolderRendezvousOrphanPair) -> [String] {
        guard isAnchored(pair) else {
            logger.warning("""
            gc: refusing to unlink \(pair.lockPath, privacy: .public) — not a \
            \(pair.sessionID.uuidString.lowercased(), privacy: .public).lock immediate child \
            of \(self.base.path, privacy: .public)
            """)
            return []
        }
        let socketPath = base.appendingPathComponent(
            "\(pair.sessionID.uuidString.lowercased()).sock").path
        guard !FileManager.default.fileExists(atPath: socketPath) else {
            logger.info("""
            gc: \(pair.lockPath, privacy: .public) acquired a socket since the listing — \
            left to the socket arm
            """)
            return []
        }
        let removed = unlinkRendezvousFiles(
            sessionID: pair.sessionID, extensions: ["lock", "log"])
        if !removed.isEmpty {
            logger.info("""
            gc: unlinked socket-less holder rendezvous residue for session \
            \(pair.sessionID.uuidString, privacy: .public): \
            \(removed.joined(separator: " "), privacy: .public)
            """)
        }
        return removed
    }

    // MARK: - Unlinking

    /// Unlinks `base/<sessionID>.<ext>` for every extension that exists, and
    /// returns the paths that are gone as a result. A missing file is not a
    /// failure — a holder that bound but never wrote a log leaves one — and a
    /// failed unlink leaves the file for the next sweep to reconsider.
    private func unlinkRendezvousFiles(sessionID: UUID, extensions: [String]) -> [String] {
        var removed: [String] = []
        for ext in extensions {
            let path = base.appendingPathComponent(
                "\(sessionID.uuidString.lowercased()).\(ext)").path
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
        let fd = open(lockPath(sessionID: sessionID), O_RDONLY | O_CLOEXEC)
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

    /// The same check for a socket-less pair, which names itself by its lock.
    private func isAnchored(_ pair: HolderRendezvousOrphanPair) -> Bool {
        let url = URL(fileURLWithPath: pair.lockPath)
        guard url.deletingLastPathComponent().path == base.path else { return false }
        return url.lastPathComponent == "\(pair.sessionID.uuidString.lowercased()).lock"
    }

    /// Where this session's creation lock lives. One derivation, so the probe,
    /// the unlink and the pair's own name cannot drift apart.
    private func lockPath(sessionID: UUID) -> String {
        base.appendingPathComponent("\(sessionID.uuidString.lowercased()).lock").path
    }
}
