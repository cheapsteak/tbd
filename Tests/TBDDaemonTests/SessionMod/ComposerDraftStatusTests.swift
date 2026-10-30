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

    @Test func confirmedWithARestorableDraft() throws {
        let root = try fixture(draft: #"{"schemaVersion":1,"sessionId":"s","hasDraft":true,"text":"hi","cursor":2,"restorable":true,"savedAtMs":1}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(read(root) == .confirmed)
    }

    /// A draft whose text lacks part of the box (a collapsed paste, an image)
    /// would wake as part of itself.
    @Test func aDraftMarkedNotRestorableIsUnknown() throws {
        let root = try fixture(draft: #"{"schemaVersion":1,"sessionId":"s","hasDraft":true,"text":"x[Pasted text #2 +50 lines]","cursor":27,"restorable":false,"savedAtMs":1}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(read(root) == .unknown(.draftNotRestorable))
    }

    /// A draft written without the mark cannot vouch for itself either.
    @Test func aDraftWithoutTheMarkIsUnknown() throws {
        let root = try fixture(draft: #"{"schemaVersion":1,"sessionId":"s","hasDraft":true,"text":"hi","cursor":2,"savedAtMs":1}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(read(root) == .unknown(.draftNotRestorable))
    }

    /// An empty box has nothing to restore, so it needs no mark, and a mark it
    /// carries anyway changes nothing.
    @Test func anEmptyBoxIsConfirmedWhateverItsMark() throws {
        for body in [
            #"{"schemaVersion":1,"sessionId":"s","hasDraft":false,"savedAtMs":1}"#,
            #"{"schemaVersion":1,"sessionId":"s","hasDraft":false,"restorable":false,"savedAtMs":1}"#,
        ] {
            let root = try fixture(draft: body)
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(read(root) == .confirmed, "\(body)")
        }
    }

    /// The mark is the draft's own: an unconfirmed liveness answer stands
    /// whatever the draft says.
    @Test func theMarkNeverOverridesLiveness() {
        let draft = SessionModFiles.ComposerDraftRecord(
            sessionId: "s", hasDraft: true, text: "hi", cursor: 2, restorable: true, savedAtMs: 1)
        #expect(ComposerDraftStatus.evaluate(liveness: .unknown(.staleHeartbeat), draft: .record(draft))
            == .unknown(.staleHeartbeat))
        #expect(ComposerDraftStatus.evaluate(liveness: .legacy, draft: .record(draft)) == .legacy)
    }

    @Test func confirmedEmpty() throws {
        let root = try fixture(draft: #"{"schemaVersion":1,"sessionId":"s","hasDraft":false,"savedAtMs":1}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(read(root) == .confirmed)
    }

    @Test func confirmedWithNoDraftFileYet() throws {
        let root = try fixture(draft: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(read(root) == .confirmed)
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
}
