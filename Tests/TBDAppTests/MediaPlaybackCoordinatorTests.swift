import Testing
@testable import TBDApp

/// A participant that counts the pauses it was asked for.
@MainActor
private final class StubParticipant: MediaPlaybackParticipant {
    var pauses = 0

    func pausePlayback() {
        pauses += 1
    }
}

/// "One at a time": starting one participant pauses every other registered
/// one, and the coordinator holds participants weakly.
@MainActor
@Suite("MediaPlaybackCoordinator")
struct MediaPlaybackCoordinatorTests {
    @Test func startingOnePausesTheOthers() {
        let coordinator = MediaPlaybackCoordinator()
        let a = StubParticipant()
        let b = StubParticipant()
        let c = StubParticipant()
        coordinator.register(a)
        coordinator.register(b)
        coordinator.register(c)

        coordinator.participantDidStartPlaying(b)

        #expect(a.pauses == 1)
        #expect(b.pauses == 0)
        #expect(c.pauses == 1)
    }

    @Test func unregisteredParticipantIsNotPaused() {
        let coordinator = MediaPlaybackCoordinator()
        let a = StubParticipant()
        let b = StubParticipant()
        coordinator.register(a)
        coordinator.register(b)
        coordinator.unregister(a)

        coordinator.participantDidStartPlaying(b)

        #expect(a.pauses == 0)
        #expect(b.pauses == 0)
    }

    @Test func releasedParticipantsDrop() {
        let coordinator = MediaPlaybackCoordinator()
        do {
            let scoped = StubParticipant()
            coordinator.register(scoped)
        }
        let b = StubParticipant()
        coordinator.register(b)

        #expect(coordinator.registeredCount == 1)
        withExtendedLifetime(b) {}
    }
}
