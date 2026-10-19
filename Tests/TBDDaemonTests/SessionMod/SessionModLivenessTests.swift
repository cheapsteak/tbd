import Foundation
import Testing
@testable import TBDDaemonLib

@Suite struct SessionModLivenessTests {
    typealias Spawn = SessionModFiles.SpawnRecord
    typealias Alive = SessionModFiles.AliveRecord

    let live = UUID()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1000) }

    func spawn(_ incarnation: String? = nil, features: [String] = ["composer-draft"]) -> Spawn {
        Spawn(sessionId: "s", incarnationId: incarnation ?? live.uuidString,
              spawnedAtMs: nowMs - 100_000, features: features)
    }

    func alive(_ incarnation: String? = nil, features: [String] = ["composer-draft"], ageMs: Int64 = 1000) -> Alive {
        Alive(sessionId: "s", incarnationId: incarnation ?? live.uuidString,
              features: features, heartbeatAtMs: nowMs - ageMs)
    }

    func eval(_ spawn: SessionModFiles.ReadResult<Spawn>, _ alive: SessionModFiles.ReadResult<Alive>,
              live: UUID?? = .some(nil)) -> SessionModLiveness {
        let incarnation: UUID? = live == .some(nil) ? self.live : (live ?? nil)
        return SessionModLiveness.evaluate(
            feature: .composerDraft, spawn: spawn, alive: alive,
            liveIncarnationID: incarnation, now: now)
    }

    @Test func noSpawnRecordIsLegacy() {
        #expect(eval(.missing, .record(alive())) == .legacy)
    }

    @Test func spawnWithoutTheFeatureIsLegacy() {
        #expect(eval(.record(spawn(features: [])), .record(alive())) == .legacy)
    }

    @Test func spawnFromAnotherIncarnationIsLegacy() {
        #expect(eval(.record(spawn(UUID().uuidString)), .record(alive())) == .legacy)
        #expect(eval(.record(spawn()), .record(alive()), live: .some(.none)) == .legacy)
    }

    @Test func freshHeartbeatIsConfirmed() {
        #expect(eval(.record(spawn()), .record(alive())) == .confirmed)
    }

    @Test func heartbeatAtExactlyNinetySecondsIsConfirmed() {
        #expect(eval(.record(spawn()), .record(alive(ageMs: 90_000))) == .confirmed)
    }

    @Test func noAliveFileIsUnknown() {
        #expect(eval(.record(spawn()), .missing) == .unknown(.noAliveFile))
    }

    @Test func aliveFromAnotherIncarnationIsUnknown() {
        #expect(eval(.record(spawn()), .record(alive(UUID().uuidString))) == .unknown(.otherIncarnation))
    }

    @Test func staleHeartbeatIsUnknown() {
        #expect(eval(.record(spawn()), .record(alive(ageMs: 91_000))) == .unknown(.staleHeartbeat))
    }

    @Test func aliveWithoutTheFeatureIsUnknown() {
        #expect(eval(.record(spawn()), .record(alive(features: []))) == .unknown(.featureNotRunning))
    }

    @Test func unreadableSpawnOrAliveIsUnknown() {
        #expect(eval(.unreadable, .record(alive())) == .unknown(.unreadableFile))
        #expect(eval(.record(spawn()), .unreadable) == .unknown(.unreadableFile))
    }

    @Test func incarnationsCompareCaseInsensitively() {
        let lower = live.uuidString.lowercased()
        #expect(eval(.record(spawn(lower)), .record(alive(lower))) == .confirmed)
    }
}
