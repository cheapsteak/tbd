import SwiftUI

/// A player the coordinator can stop. `MediaPlayerHostView` is the real one;
/// tests use a stub.
@MainActor
protocol MediaPlaybackParticipant: AnyObject {
    func pausePlayback()
}

/// Enforces "one at a time": when one participant starts playing, every other
/// registered participant is paused, anywhere in the app.
///
/// Participants are held weakly, keyed by `ObjectIdentifier`, so a view that
/// goes away without unregistering is dropped rather than kept alive.
@MainActor
final class MediaPlaybackCoordinator {
    /// The app-wide instance, the environment's default. Tests make their own.
    nonisolated static let shared = MediaPlaybackCoordinator()

    private struct WeakParticipant {
        weak var participant: (any MediaPlaybackParticipant)?
    }

    private var participants: [ObjectIdentifier: WeakParticipant] = [:]

    nonisolated init() {}

    /// How many registered participants are still alive. For tests.
    var registeredCount: Int {
        participants.values.filter { $0.participant != nil }.count
    }

    func register(_ participant: any MediaPlaybackParticipant) {
        dropReleased()
        participants[ObjectIdentifier(participant)] = WeakParticipant(participant: participant)
    }

    func unregister(_ participant: any MediaPlaybackParticipant) {
        participants[ObjectIdentifier(participant)] = nil
    }

    /// Pauses every registered participant other than `participant`.
    func participantDidStartPlaying(_ participant: any MediaPlaybackParticipant) {
        dropReleased()
        let starter = ObjectIdentifier(participant)
        // Collected first, so a participant that unregisters while pausing
        // cannot change the collection being walked.
        var others: [any MediaPlaybackParticipant] = []
        for (id, entry) in participants where id != starter {
            if let other = entry.participant {
                others.append(other)
            }
        }
        for other in others {
            other.pausePlayback()
        }
    }

    private func dropReleased() {
        participants = participants.filter { $0.value.participant != nil }
    }
}

private struct MediaPlaybackCoordinatorKey: EnvironmentKey {
    static let defaultValue: MediaPlaybackCoordinator = .shared
}

extension EnvironmentValues {
    /// The coordinator a `MediaPlayerView` registers with. Defaults to the
    /// app-wide instance; a test supplies its own.
    var mediaPlaybackCoordinator: MediaPlaybackCoordinator {
        get { self[MediaPlaybackCoordinatorKey.self] }
        set { self[MediaPlaybackCoordinatorKey.self] = newValue }
    }
}
