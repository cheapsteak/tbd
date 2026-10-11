import Foundation
import TBDShared

/// Whether a session may be moved from the tmux transport to the pty holder.
///
/// Deliberately does NOT require a resumable Claude session, unlike the
/// profile swap and manual hibernate: a shell has no conversation to resume
/// and must still be migratable, or tmux rows would live forever.
///
/// It also makes no judgement a later rail will make. The park's own rails
/// refuse typed input; repeating them here would give one question two answers.
enum TransportMigrationEligibility: Equatable {
    case eligible
    case alreadyHolder
    case skip(reason: String)

    static func decide(_ terminal: Terminal) -> TransportMigrationEligibility {
        if terminal.transport == .holder { return .alreadyHolder }
        // Same wording as `HibernationCoordinator.manualBlockReason`, so a
        // person meets one vocabulary.
        switch terminal.activityState {
        case .working:
            return .skip(reason: "Session is actively running")
        case .waitingForUser:
            return .skip(reason: "Session is waiting on a permission prompt")
        default:
            return .eligible
        }
    }
}
