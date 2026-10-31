import Foundation

/// Classification of a transport migration's outcome into the outcome
/// vocabulary, spelled here for the same reason the park/wake classification is
/// spelled in `ActuationOutcome+Park.swift`: the surface writes one row per
/// session it moves, and a reader asking which sessions a destructive fleet
/// gesture stopped must not have to tell them apart by their detail strings.
///
/// `movedNotResumed` is the one outcome that is neither a dispatch nor a
/// decline: the rewrite landed — the daemon did touch the row and retire its
/// window — and the resume that follows it failed. That is a transport failure,
/// the same classification the wake's own `respawnFailed` gets, and emphatically
/// not a refusal: a refusal asserts the daemon stopped before acting.
extension ActuationOutcome {
    static func classify(_ outcome: TransportMigrationOutcome) -> ActuationOutcome {
        switch outcome {
        case .migrated:
            return .dispatched
        case .movedNotResumed:
            return .transportFailed
        // Already there is the migration's idempotent no-op, not a decline.
        case .alreadyHolder:
            return .refused(.noop)
        case .skipped(let reason):
            // The one skip that names an absent row, rather than a state of a
            // row that is present. Every other skip is a rail or a race, which
            // is `notEligible`: the row is there and is not in a state this act
            // may touch.
            return .refused(reason == TerminalTransportMigrator.notFoundSkip
                ? .notFound : .notEligible)
        case .refused:
            return .refused(.notEligible)
        }
    }

    static func detail(_ outcome: TransportMigrationOutcome) -> String? {
        switch outcome {
        case .migrated: return nil
        case .alreadyHolder: return "already on the pty holder"
        case .movedNotResumed(let reason), .skipped(let reason), .refused(let reason):
            return reason
        }
    }
}
