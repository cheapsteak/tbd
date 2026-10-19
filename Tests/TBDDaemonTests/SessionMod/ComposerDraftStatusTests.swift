import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib

@Suite struct ComposerDraftStatusTests {
    let live = UUID()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1000) }

    /// A session directory holding a fresh spawn and alive file, plus an
    /// optional draft file body.
    func fixture(draft: String?) throws -> URL {
        let root = try makeSessionsDir()
        try SessionModFiles.writeSpawnRecord(
            .init(sessionId: "s", incarnationId: live.uuidString,
                  spawnedAtMs: nowMs, features: ["composer-draft"]),
            sessionsDir: root)
        let dir = root.appendingPathComponent("s")
        let alive = SessionModFiles.AliveRecord(
            sessionId: "s", incarnationId: live.uuidString,
            features: ["composer-draft"], heartbeatAtMs: nowMs)
        try JSONEncoder().encode(alive).write(to: dir.appendingPathComponent(SessionModFiles.aliveFileName))
        if let draft {
            try Data(draft.utf8).write(to: dir.appendingPathComponent(SessionModFiles.composerDraftFileName))
        }
        return root
    }

    func read(_ root: URL, id: String? = "s") -> ComposerDraftStatus {
        ComposerDraftStatus.read(
            sessionsDir: root, claudeSessionID: id, liveIncarnationID: live, now: now)
    }

    @Test func confirmedWithADraft() throws {
        let root = try fixture(draft: #"{"schemaVersion":1,"sessionId":"s","hasDraft":true,"text":"hi","cursor":2,"savedAtMs":1}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(read(root) == .confirmed(hasDraft: true))
    }

    @Test func confirmedEmpty() throws {
        let root = try fixture(draft: #"{"schemaVersion":1,"sessionId":"s","hasDraft":false,"savedAtMs":1}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(read(root) == .confirmed(hasDraft: false))
    }

    @Test func confirmedWithNoDraftFileYetIsEmpty() throws {
        let root = try fixture(draft: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(read(root) == .confirmed(hasDraft: false))
    }

    @Test func unreadableDraftFileIsUnknown() throws {
        let root = try fixture(draft: "not json")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(read(root) == .unknown(.unreadableFile))
    }

    @Test func legacyAndUnknownPassThrough() throws {
        let root = try fixture(draft: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(read(root, id: nil) == .legacy)
        #expect(read(root, id: "../s") == .legacy)
        #expect(read(root, id: "other") == .legacy)
        #expect(ComposerDraftStatus.evaluate(liveness: .unknown(.staleHeartbeat), draft: .missing)
            == .unknown(.staleHeartbeat))
        #expect(ComposerDraftStatus.evaluate(liveness: .legacy, draft: .unreadable) == .legacy)
    }

    @Test func spawnedWithFeatureIsFalseOnlyForLegacy() {
        #expect(!ComposerDraftStatus.legacy.spawnedWithFeature)
        #expect(ComposerDraftStatus.confirmed(hasDraft: false).spawnedWithFeature)
        #expect(ComposerDraftStatus.unknown(.noAliveFile).spawnedWithFeature)
    }
}
