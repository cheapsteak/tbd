import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Makes a scratch sessions directory; the caller removes it.
func makeSessionsDir() throws -> URL {
    let url = URL(fileURLWithPath: fencedScratchRoot(prefix: "sessmod"))
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct SessionModFilesTests {
    @Test func sessionsDirFollowsTBDHome() {
        let url = TBDConstants.sessionsDir(environment: ["TBD_HOME": "/tmp/tbd-home-x"])
        #expect(url.path == "/tmp/tbd-home-x/sessions")
    }

    @Test func unsafeSessionIDHasNoDirectory() {
        let root = URL(fileURLWithPath: "/tmp/x")
        for id in ["../x", "a/b", ""] {
            #expect(SessionModFiles.directory(sessionsDir: root, claudeSessionID: id) == nil)
        }
        #expect(SessionModFiles.directory(sessionsDir: root, claudeSessionID: "abc-123_X")?.path
            == "/tmp/x/abc-123_X")
    }

    @Test func spawnRecordRoundTripsThroughTheFile() throws {
        let root = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = SessionModFiles.SpawnRecord(
            sessionId: "s1", incarnationId: UUID().uuidString,
            spawnedAtMs: 1_700_000_000_000, features: ["composer-draft"])
        try SessionModFiles.writeSpawnRecord(record, sessionsDir: root)
        let url = root.appendingPathComponent("s1").appendingPathComponent(SessionModFiles.spawnFileName)
        guard case .record(let read) = SessionModFiles.read(SessionModFiles.SpawnRecord.self, at: url) else {
            Issue.record("expected a record")
            return
        }
        #expect(read == record)
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int) & 0o777
    }

    /// Drafts can hold pasted secrets: a spawn that creates the sessions root
    /// creates it for its owner alone.
    @Test func writingASpawnRecordCreatesAnOwnerOnlySessionsRoot() throws {
        let parent = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("sessions", isDirectory: true)
        try SessionModFiles.writeSpawnRecord(
            .init(sessionId: "s1", incarnationId: UUID().uuidString,
                  spawnedAtMs: 1, features: ["composer-draft"]),
            sessionsDir: root)
        #expect(try mode(of: root) == 0o700)
    }

    /// A root an earlier version created with the default mode is narrowed at
    /// the next spawn.
    @Test func writingASpawnRecordNarrowsAnExistingSessionsRoot() throws {
        let root = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        #expect(try mode(of: root) == 0o755, "the fixture never widened the root")
        try SessionModFiles.writeSpawnRecord(
            .init(sessionId: "s1", incarnationId: UUID().uuidString,
                  spawnedAtMs: 1, features: ["composer-draft"]),
            sessionsDir: root)
        #expect(try mode(of: root) == 0o700)
    }

    @Test func writeSpawnRecordThrowsOnUnsafeID() throws {
        let root = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = SessionModFiles.SpawnRecord(
            sessionId: "../x", incarnationId: UUID().uuidString, spawnedAtMs: 1, features: [])
        #expect(throws: (any Error).self) {
            try SessionModFiles.writeSpawnRecord(record, sessionsDir: root)
        }
    }

    @Test func aDraftsRestorableMarkReadsBackAndIsOptional() throws {
        let root = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("draft.json")
        try Data(#"{"schemaVersion":1,"sessionId":"s","hasDraft":true,"text":"hi","cursor":2,"restorable":false,"savedAtMs":5}"#.utf8)
            .write(to: url)
        guard case .record(let marked) = SessionModFiles.read(SessionModFiles.ComposerDraftRecord.self, at: url) else {
            Issue.record("expected a record")
            return
        }
        #expect(marked.restorable == false)
        try Data(#"{"schemaVersion":1,"sessionId":"s","hasDraft":false,"savedAtMs":5}"#.utf8).write(to: url)
        guard case .record(let empty) = SessionModFiles.read(SessionModFiles.ComposerDraftRecord.self, at: url) else {
            Issue.record("expected a record")
            return
        }
        #expect(empty.restorable == nil)
    }

    @Test func readIgnoresUnknownFields() throws {
        let root = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("draft.json")
        try Data(#"{"schemaVersion":1,"sessionId":"s","hasDraft":false,"savedAtMs":5,"extra":[1]}"#.utf8)
            .write(to: url)
        guard case .record(let r) = SessionModFiles.read(SessionModFiles.ComposerDraftRecord.self, at: url) else {
            Issue.record("expected a record")
            return
        }
        #expect(r.hasDraft == false)
        #expect(r.text == nil)
    }

    @Test func readReportsMissingAndUnreadable() throws {
        let root = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("a.json")
        guard case .missing = SessionModFiles.read(SessionModFiles.AliveRecord.self, at: url) else {
            Issue.record("expected missing")
            return
        }
        for body in ["{}", "not json"] {
            try Data(body.utf8).write(to: url)
            guard case .unreadable = SessionModFiles.read(SessionModFiles.AliveRecord.self, at: url) else {
                Issue.record("expected unreadable for \(body)")
                return
            }
        }
    }

    @Test func nonENOENTFailureReadsUnreadable() throws {
        let root = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("plain")
        try Data("x".utf8).write(to: file)
        // The parent is a regular file, so open fails with ENOTDIR, not ENOENT.
        let url = file.appendingPathComponent("spawn.json")
        guard case .unreadable = SessionModFiles.read(SessionModFiles.SpawnRecord.self, at: url) else {
            Issue.record("expected unreadable")
            return
        }
    }

    @Test func removeSessionDirectoryRemovesOnlyThatSession() throws {
        let root = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for id in ["keep", "drop"] {
            try SessionModFiles.writeSpawnRecord(
                .init(sessionId: id, incarnationId: UUID().uuidString, spawnedAtMs: 1, features: []),
                sessionsDir: root)
        }
        SessionModFiles.removeSessionDirectory(sessionsDir: root, claudeSessionID: "drop")
        SessionModFiles.removeSessionDirectory(sessionsDir: root, claudeSessionID: "../keep")
        SessionModFiles.removeSessionDirectory(sessionsDir: root, claudeSessionID: "absent")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("drop").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("keep").path))
    }

    @Test func featureEnabledFollowsConfig() {
        var config = Config()
        #expect(SessionModFeature.enabled(in: config).isEmpty)
        config.composerDraftEnabled = true
        #expect(SessionModFeature.enabled(in: config) == [.composerDraft])
    }
}
