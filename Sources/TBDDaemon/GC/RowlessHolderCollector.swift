import Darwin
import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "gc")

/// One holder socket the row-less sweep may have an opinion about.
public struct RowlessHolderCandidate: Sendable, Equatable {
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

/// What one handshake against a holder socket established.
///
/// The four cases are deliberately not collapsed. `rejected` and `unreachable`
/// both mean "leave it alone", but they mean it for opposite reasons — a
/// refusal is a *healthy* holder busy serving somebody, an unreachable one is a
/// holder we cannot judge — and a log that could not tell them apart would make
/// the soak unreadable.
public enum RowlessHolderHandshake: Sendable, Equatable {
    /// The holder answered. Its `holderPID` comes from `LOCAL_PEERPID` on the
    /// connected socket and is `nil` when the kernel would not say.
    case described(HolderChildDescription, holderPID: Int32?)
    /// The holder answered with the busy sentinel: it is alive and already has
    /// a client. **Terminal in both directions** — not exited, not killed.
    case rejected
    /// `ECONNREFUSED` or `ENOENT`: a bound path with nothing behind it. That is
    /// the *rendezvous file* sweep's business, not this one's.
    case noListener
    /// Anything else — a timeout, a protocol error, a socket that connects and
    /// says nothing. An unreadable answer, and an unreadable answer keeps.
    case unreachable(String)
}

/// Outcome of gating one candidate.
///
/// `reason` is one of `"unknown-age"`, `"grace"`, `"has-row"`,
/// `"no-owner-token"`, `"rejected"`, `"no-listener"`, `"unreachable"`,
/// `"foreign-owner"`, `"no-child"`.
public enum RowlessHolderDecision: Sendable, Equatable {
    case keep(reason: String)
    case kill(childPID: Int32, holderPID: Int32?)
}

/// The actuation half of the sweep, injected so a unit test can prove that a
/// candidate the gates kept was never signalled — an assertion no return value
/// can carry, because "left alone" is the absence of an effect.
public protocol RowlessHolderReclaiming: Sendable {
    /// Kill the job the holder forked, then the holder itself.
    func reclaim(socketPath: String, childPID: Int32, holderPID: Int32?) async
}

/// The named reconciler for **row-less pty holders**: a holder process that is
/// alive, speaks the protocol, proves it belongs to this installation, and yet
/// has no session row claiming it
/// (`docs/specs/2026-08-30-pty-holder-session-transport-design.md`,
/// "Reconciliation").
///
/// It is the process-shaped twin of `HolderRendezvousCollector`, which reclaims
/// the *files* a dead holder left behind. This one reclaims a holder that is
/// very much alive, so every gate is stricter and the flag is its own.
///
/// Five rules govern it, and dropping any one of them turns it into a way to
/// kill somebody's healthy session:
///
///   1. **A completed handshake is proof of liveness, not of ownership**, and
///      only ownership licenses a kill. The default `TBD_HOME` is shared by
///      every checkout on a machine, so "reachable and absent from *my*
///      database" is exactly the shape a foreign but perfectly healthy session
///      presents.
///   2. **The owner token decides.** Minted once per installation and persisted
///      in the `config` row, it is returned by every handshake. A holder whose
///      token differs is left alone and logged. So is every holder, always,
///      when this installation has no token at all: a daemon that never minted
///      one has never spawned a holder, so nothing out there can be ours.
///   3. **A rejected connection is terminal in both directions** — not exited,
///      and not killed either. A stale daemon from a different checkout is a
///      known hazard on a development machine, and a holder that will not talk
///      to us is exactly what one looks like.
///   4. **Keep-biased for young holders.** `OrphanGC` runs on demand from RPC
///      handlers, so a sweep can land between a holder becoming connectable and
///      its session row committing; killing there destroys a session being
///      born. A socket newer than the grace window is left alone whatever the
///      other gates would say — the same guard `HolderRendezvousCollector`
///      applies to the same race shape.
///   5. **Kill, not adopt.** iTerm2 adopts unclaimed survivors because its live
///      processes are the only copy of anything; TBD's transcripts persist
///      independently, so adoption would buy a mystery-session UI and cut
///      against the database-is-intent model the other reconcilers follow.
///
/// The gate order — age, then row, then handshake — is not arbitrary. Age is a
/// `stat` and exists for a race rather than for a fact. The row check comes
/// before any connect because **connecting is not free**: the holder serves one
/// client at a time, so a probe against a holder that is mid-adoption would
/// occupy the slot the daemon needs. Only a candidate that is old and unclaimed
/// is worth a socket round trip.
public struct RowlessHolderCollector: Sendable {
    let base: URL
    let now: @Sendable () -> Date
    /// Connect, handshake, and report what came back. Injected so a test can
    /// pin the answer; production is `Self.productionHandshake`.
    let handshake: @Sendable (String) async -> RowlessHolderHandshake
    let reclaimer: any RowlessHolderReclaiming

    public init(
        base: URL,
        now: @escaping @Sendable () -> Date = Date.init,
        handshake: (@Sendable (String) async -> RowlessHolderHandshake)? = nil,
        reclaimer: (any RowlessHolderReclaiming)? = nil
    ) {
        self.base = base
        self.now = now
        self.handshake = handshake ?? Self.productionHandshake
        self.reclaimer = reclaimer ?? ProductionRowlessHolderReclaimer()
    }

    /// Immediate children named `<uuid>.sock`, exactly as
    /// `HolderRendezvousCollector` enumerates them: the two sweeps read the same
    /// directory for opposite reasons and must agree on what a candidate is.
    public func candidates() -> [RowlessHolderCandidate] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else {
            return []
        }
        return names.compactMap { name -> RowlessHolderCandidate? in
            guard name.hasSuffix(".sock"),
                  let id = UUID(uuidString: String(name.dropLast(".sock".count)))
            else { return nil }
            let url = base.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  !isDir.boolValue else { return nil }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return RowlessHolderCandidate(
                sessionID: id, socketPath: url.path,
                createdAt: attributes?[.creationDate] as? Date)
        }.sorted { $0.socketPath < $1.socketPath }
    }

    /// Gate order: age → row → handshake → owner. Every gate fails toward
    /// keeping, and only the last one can license a kill.
    ///
    /// - Parameter owner: this installation's token, or `nil` when none has been
    ///   minted — in which case nothing out there can be ours and every
    ///   candidate is kept.
    /// - Parameter claimedSessionIDs: the ids of every session row that exists.
    ///   A candidate in this set is claimed and is not this sweep's business.
    public func decide(
        _ candidate: RowlessHolderCandidate,
        graceSeconds: Int,
        owner: HolderOwnerToken?,
        claimedSessionIDs: Set<UUID>
    ) async -> RowlessHolderDecision {
        guard let owner else { return .keep(reason: "no-owner-token") }
        guard let created = candidate.createdAt else {
            return .keep(reason: "unknown-age")
        }
        if now().timeIntervalSince(created) < Double(graceSeconds) {
            return .keep(reason: "grace")
        }
        if claimedSessionIDs.contains(candidate.sessionID) {
            return .keep(reason: "has-row")
        }
        switch await handshake(candidate.socketPath) {
        case .rejected:
            return .keep(reason: "rejected")
        case .noListener:
            return .keep(reason: "no-listener")
        case .unreachable:
            return .keep(reason: "unreachable")
        case .described(let description, let holderPID):
            guard description.owner == owner else {
                return .keep(reason: "foreign-owner")
            }
            // `killJob` refuses anything at or below pid 1, and a description
            // that cannot name a child names nothing this sweep may signal.
            guard description.childPID > 1 else { return .keep(reason: "no-child") }
            return .kill(childPID: description.childPID, holderPID: holderPID)
        }
    }

    /// Kills the job and then the holder. Anchored first, the same guard
    /// `HolderRendezvousCollector.reap` keeps in front of its unlink: this is a
    /// public value type anyone can construct, so the invariant that a candidate
    /// names an immediate `<uuid>.sock` child of `base` is checked rather than
    /// assumed — a path that wandered would send the round trip, and the kill,
    /// somewhere nobody sanctioned.
    public func reclaim(
        _ candidate: RowlessHolderCandidate, childPID: Int32, holderPID: Int32?
    ) async -> Bool {
        guard isAnchored(candidate) else {
            logger.warning("""
            gc: refusing to reclaim \(candidate.socketPath, privacy: .public) — not a \
            \(candidate.sessionID.uuidString.lowercased(), privacy: .public).sock immediate child \
            of \(self.base.path, privacy: .public)
            """)
            return false
        }
        logger.info("""
        gc: reclaiming row-less holder for session \
        \(candidate.sessionID.uuidString, privacy: .public) — child pid \
        \(childPID, privacy: .public), holder pid \
        \(holderPID.map(String.init) ?? "unknown", privacy: .public)
        """)
        await reclaimer.reclaim(
            socketPath: candidate.socketPath, childPID: childPID, holderPID: holderPID)
        return true
    }

    // MARK: - The production handshake

    /// Connect, `describe`, and read the holder pid off the connection.
    ///
    /// The errno reading is deliberately the same one
    /// `HolderRendezvousCollector.probeForListener` takes, because the two ask
    /// the same question for opposite reasons and must not disagree: only
    /// `ECONNREFUSED` (bound, nobody accepting) and `ENOENT` (gone since the
    /// listing) are evidence of absence. Everything else is an unreadable
    /// answer, and an unreadable answer keeps.
    public static let productionHandshake: @Sendable (String) async
        -> RowlessHolderHandshake = { socketPath in
        let client = HolderClient(socketPath: socketPath, receiveTimeout: handshakeTimeout)
        let outcome: RowlessHolderHandshake
        do {
            let description = try await client.describe()
            // Read AFTER the handshake, so the pid belongs to a connection that
            // has provably answered — and while it is still open, because
            // `LOCAL_PEERPID` is a property of the socket, not of the path.
            outcome = .described(description, holderPID: await client.peerPID())
        } catch HolderClient.Error.rejected {
            outcome = .rejected
        } catch HolderClient.Error.cannotConnect(_, let code) {
            outcome = (code == ECONNREFUSED || code == ENOENT)
                ? .noListener
                : .unreachable("connect failed (errno \(code))")
        } catch {
            outcome = .unreachable(error.localizedDescription)
        }
        await client.close()
        return outcome
    }

    /// Bounded well under the hourly sweep interval, for the same reason the
    /// rendezvous probe is: a stranger that connects but never answers must not
    /// stall a sweep with hundreds of candidates.
    static let handshakeTimeout: Duration = .seconds(2)

    /// The candidate names an immediate child of `base` called
    /// `<sessionID>.sock` — exactly what `candidates()` produces. Requiring the
    /// parent to *equal* `base` rejects anything nested, along with any `..`,
    /// which no longer resolves to `base` once the last component is dropped.
    private func isAnchored(_ candidate: RowlessHolderCandidate) -> Bool {
        let url = URL(fileURLWithPath: candidate.socketPath)
        guard url.deletingLastPathComponent().path == base.path else { return false }
        return url.lastPathComponent == "\(candidate.sessionID.uuidString.lowercased()).sock"
    }
}

/// The real killer: the job's process group, then the job, then the holder.
///
/// The ordering is the one `HolderRegistry.dispose` established and is
/// load-bearing at every step:
///
///   - **The group is resolved first**, before anything hangs the job up.
///     `forget` closes the pty master, which usually kills the job outright,
///     after which `getpgid` answers `ESRCH` and the group can no longer be
///     named — while a member that ignored `SIGHUP` is still sitting in it.
///   - **The job dies before the holder**, because the holder owns the only
///     reference to the pty master and killing it first would hang the job up
///     on a terminal nobody is draining.
///   - **The holder is killed rather than merely forgotten.** A forgotten
///     holder does break its own loop, but a holder that never answered the
///     `forget` would otherwise be left running with a socket nothing reclaims.
///
/// `waitpid` is `WNOHANG` and bounded: a holder spawned by *this* daemon
/// incarnation is our child and leaves a corpse nobody else can collect, while
/// one inherited from a previous incarnation answers `ECHILD` immediately. Both
/// must be cheap, and neither may park the sweep.
public struct ProductionRowlessHolderReclaimer: RowlessHolderReclaiming {
    private let clock: any Clock<Duration>

    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    static let reapBudget: Duration = .seconds(2)
    static let reapPollInterval: Duration = .milliseconds(50)

    public func reclaim(socketPath: String, childPID: Int32, holderPID: Int32?) async {
        let group = HolderRegistry.jobProcessGroup(childPID: childPID)
        let client = HolderClient(socketPath: socketPath)
        try? await client.forget()
        await client.close()
        HolderRegistry.killJob(childPID: childPID, group: group)
        guard let holderPID, holderPID > 1 else { return }
        _ = kill(holderPID, SIGKILL)
        var waited: Duration = .zero
        while waited < Self.reapBudget {
            var status: Int32 = 0
            let collected = waitpid(holderPID, &status, WNOHANG)
            if collected == holderPID { return }
            // ECHILD: not our child — a holder inherited from a previous daemon,
            // which the kernel's reparenting will collect. Nothing to wait for.
            if collected < 0 && errno != EINTR { return }
            // Accumulated from the interval rather than measured against a
            // deadline, for the same reason as everywhere else in this code:
            // `any Clock<Duration>` pins `Duration` but not `Instant`.
            try? await clock.sleep(for: Self.reapPollInterval)
            waited += Self.reapPollInterval
        }
    }
}
