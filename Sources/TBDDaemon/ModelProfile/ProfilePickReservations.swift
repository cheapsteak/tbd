import Foundation
import TBDShared

/// In-memory reservations that make a spawn-time balanced pick atomic.
///
/// A balanced pick reads live session counts and chooses a profile before the
/// new terminal row exists, and the only spawn lock is per worktree. Two
/// spawns into different worktrees can therefore both read the same counts and
/// both choose the same "best" profile. Each balanced pick records a
/// reservation here, and every later pick counts each held reservation as one
/// more live session on its profile.
///
/// `pickAndReserve` is the whole critical section and never suspends, so no
/// two picks interleave inside it — the property an actor alone does not give
/// a method that awaits the database. Callers do every read first and hand the
/// results in.
///
/// A reservation settles by identity: the spawn that received it calls
/// `release` (through `ModelProfileResolver.settleReservation`) right after
/// its terminal row is inserted. Rows are never matched against reservations,
/// so unrelated spawns landing on a reserved profile — explicit picks, repo
/// overrides — cannot erase reservations they do not own. Between the row
/// insert and the settle the session counts twice, once as a row and once as
/// a reservation: an overcount by one, which spreads the next pick rather
/// than piling onto the profile.
///
/// A spawn that fails after picking never settles, so reservations expire
/// after `ttl`: a failed spawn inflates one profile's load for at most that
/// long. Only spawn-time placement reserves; the hard-limit switch suggestion
/// places nothing and does not come here.
///
/// There is one instance per daemon, built in `Daemon.swift` and shared by
/// every copy of the resolver.
public actor ProfilePickReservations {
    /// How long a reservation counts if its spawn never settles it. Long
    /// enough to cover a slow spawn (worktree creation, tmux window, row
    /// insert), short enough that a spawn which failed after picking stops
    /// skewing the balance quickly.
    public static let defaultTTL: TimeInterval = 120

    private struct Reservation {
        let id: UUID
        let profileID: UUID
        let reservedAt: Date
    }

    private var reservations: [Reservation] = []
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        ttl: TimeInterval = ProfilePickReservations.defaultTTL,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.ttl = ttl
        self.now = now
    }

    /// The outcome of one atomic pick: the picker's decision over the
    /// adjusted candidates, those candidates (for logging), and the id of the
    /// reservation recorded for the chosen profile.
    public struct Outcome: Sendable {
        public let decision: ProfilePoolDecision
        public let candidates: [ProfilePoolCandidate]
        public let reservationID: UUID?
    }

    /// Prune expired reservations, fold every held one into its profile's
    /// live count, run the picker, and reserve the winner — all without
    /// suspending.
    ///
    /// - Parameters:
    ///   - candidates: The candidate list as read from the stores.
    ///   - pickTime: The time the picker judges snapshot staleness against.
    public func pickAndReserve(
        candidates: [ProfilePoolCandidate],
        pickTime: Date
    ) -> Outcome {
        let current = now()
        let expiry = current.addingTimeInterval(-ttl)
        reservations.removeAll { $0.reservedAt < expiry }

        var held: [UUID: Int] = [:]
        for reservation in reservations {
            held[reservation.profileID, default: 0] += 1
        }

        let adjusted = candidates.map { candidate -> ProfilePoolCandidate in
            var copy = candidate
            copy.liveSessions += held[candidate.profileID] ?? 0
            return copy
        }
        let decision = ProfilePoolPicker.pick(candidates: adjusted, now: pickTime)
        var reservationID: UUID?
        if let chosen = decision.chosen {
            let id = UUID()
            reservations.append(Reservation(id: id, profileID: chosen, reservedAt: current))
            reservationID = id
        }
        return Outcome(decision: decision, candidates: adjusted, reservationID: reservationID)
    }

    /// Drop a reservation: its spawn's terminal row has landed and now
    /// carries the load, or the spawn will not produce a row on the reserved
    /// profile (the chosen profile failed to load, for instance). Unknown or
    /// already-released ids are a no-op.
    public func release(_ id: UUID) {
        reservations.removeAll { $0.id == id }
    }

    /// Number of reservations currently held, expired or not. Test-facing.
    var heldCount: Int { reservations.count }
}
