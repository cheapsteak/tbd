import Foundation
import TBDShared

/// One live Claude terminal row, reduced to what a balanced pick needs to
/// tell whether a reservation has landed: the profile it runs on and when the
/// row was created.
public struct RecentProfileSpawn: Sendable, Equatable {
    public let profileID: UUID
    public let createdAt: Date

    public init(profileID: UUID, createdAt: Date) {
        self.profileID = profileID
        self.createdAt = createdAt
    }
}

/// In-memory reservations that make a spawn-time balanced pick atomic.
///
/// A balanced pick reads live session counts and chooses a profile before the
/// new terminal row exists, and the only spawn lock is per worktree. Two
/// spawns into different worktrees can therefore both read the same counts and
/// both choose the same "best" profile. Each balanced pick records a
/// reservation here, and every later pick counts the reservations whose rows
/// have not landed yet as live sessions.
///
/// `pickAndReserve` is the whole critical section and never suspends, so no
/// two picks interleave inside it — the property an actor alone does not give
/// a method that awaits the database. Callers do every read first and hand the
/// results in.
///
/// A spawn that fails after picking never produces its row, so reservations
/// expire after `ttl`: a failed spawn inflates one profile's load for at most
/// that long. Only spawn-time placement reserves; the hard-limit switch
/// suggestion places nothing and does not come here.
///
/// There is one instance per daemon, built in `Daemon.swift` and shared by
/// every copy of the resolver.
public actor ProfilePickReservations {
    /// How long a reservation counts while its row has not landed. Long enough
    /// to cover a slow spawn (worktree creation, tmux window, row insert),
    /// short enough that a spawn which failed after picking stops skewing the
    /// balance quickly.
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

    /// The earliest creation time a terminal row can have and still settle a
    /// reservation that is unexpired now or later. Callers read the recent
    /// rows created at or after this instant before calling `pickAndReserve`;
    /// since reservations only get younger relative to the cutoff as time
    /// moves on, that read covers every reservation the pick will consider.
    public nonisolated func rowCutoff() -> Date {
        now().addingTimeInterval(-ttl)
    }

    /// The outcome of one atomic pick: the picker's decision over the
    /// adjusted candidates, those candidates (for logging), and the id of the
    /// reservation recorded for the chosen profile.
    public struct Outcome: Sendable {
        public let decision: ProfilePoolDecision
        public let candidates: [ProfilePoolCandidate]
        public let reservationID: UUID?
    }

    /// Prune expired reservations, fold the unlanded ones into each
    /// candidate's live count, run the picker, and reserve the winner — all
    /// without suspending.
    ///
    /// A profile's unlanded reservations are its unexpired reservations minus
    /// the rows for it created at or after its oldest unexpired reservation,
    /// floored at zero. `liveSessions` already counts every landed row, so a
    /// reservation stops counting the moment its row appears.
    ///
    /// - Parameters:
    ///   - candidates: The candidate list as read from the stores.
    ///   - recentRows: Live Claude rows created at or after `rowCutoff()`, read
    ///     BEFORE the live counts inside `candidates`. A row that lands between
    ///     the two reads is then counted as live and its reservation still
    ///     counts too — an overcount by one, never an undercount.
    ///   - pickTime: The time the picker judges snapshot staleness against.
    public func pickAndReserve(
        candidates: [ProfilePoolCandidate],
        recentRows: [RecentProfileSpawn],
        pickTime: Date
    ) -> Outcome {
        let current = now()
        let expiry = current.addingTimeInterval(-ttl)
        reservations.removeAll { $0.reservedAt < expiry }

        var unlanded: [UUID: Int] = [:]
        for (profileID, held) in Dictionary(grouping: reservations, by: \.profileID) {
            guard let oldest = held.map(\.reservedAt).min() else { continue }
            let landed = recentRows.filter {
                $0.profileID == profileID && $0.createdAt >= oldest
            }.count
            unlanded[profileID] = max(0, held.count - landed)
        }

        let adjusted = candidates.map { candidate -> ProfilePoolCandidate in
            var copy = candidate
            copy.liveSessions += unlanded[candidate.profileID] ?? 0
            return copy
        }
        let decision = ProfilePoolPicker.pick(candidates: adjusted, now: pickTime)
        var reservationID: UUID?
        if let chosen = decision.chosen {
            let id = UUID()
            // Floored to the millisecond: the database keeps `createdAt` at
            // millisecond precision, so a row inserted in the same millisecond
            // as its reservation must not read as older than it.
            let stamp = Date(timeIntervalSinceReferenceDate:
                (current.timeIntervalSinceReferenceDate * 1000).rounded(.down) / 1000)
            reservations.append(Reservation(id: id, profileID: chosen, reservedAt: stamp))
            reservationID = id
        }
        return Outcome(decision: decision, candidates: adjusted, reservationID: reservationID)
    }

    /// Drop a reservation whose spawn will not produce a row on the reserved
    /// profile (the chosen profile failed to load, for instance).
    public func release(_ id: UUID) {
        reservations.removeAll { $0.id == id }
    }

    /// Number of reservations currently held, expired or not. Test-facing.
    var heldCount: Int { reservations.count }
}
