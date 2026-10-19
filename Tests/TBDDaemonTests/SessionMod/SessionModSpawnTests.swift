import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The `-e KEY=VALUE` pairs of one tmux argv — the spawned process's own
/// environment, as opposed to the inline `export` prefix in its command.
func tmuxEnvironmentFlags(_ argv: [String]) -> [String: String] {
    var environment: [String: String] = [:]
    for (flag, pair) in zip(argv, argv.dropFirst()) where flag == "-e" {
        guard let equals = pair.firstIndex(of: "=") else { continue }
        environment[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
    }
    return environment
}

/// The session's `spawn.json`, or nil when it is missing or unreadable.
func readSpawnRecord(sessionsDir: URL, sessionID: String) -> SessionModFiles.SpawnRecord? {
    let url = sessionsDir
        .appendingPathComponent(sessionID, isDirectory: true)
        .appendingPathComponent(SessionModFiles.spawnFileName)
    guard case .record(let record) = SessionModFiles.read(SessionModFiles.SpawnRecord.self, at: url) else {
        return nil
    }
    return record
}

@Suite struct SessionModSpawnTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000.25)

    @Test func prepareWritesTheSpawnRecordAndReturnsThreeVariables() throws {
        let root = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let incarnation = UUID()

        let context = try #require(SessionModSpawn.prepare(
            features: [.composerDraft, .composerDraft],
            claudeSessionID: "sess-1",
            incarnationID: incarnation,
            sessionsDir: root,
            now: Self.now))

        #expect(context.features == [.composerDraft])
        #expect(context.incarnationID == incarnation)
        #expect(context.environment == [
            "TBD_SESSIONS_DIR": root.path,
            "TBD_MOD_FEATURES": "composer-draft",
            "TBD_TERMINAL_INCARNATION_ID": incarnation.uuidString,
        ])
        #expect(SessionModSpawn.sessionsDirVariable == "TBD_SESSIONS_DIR")
        #expect(SessionModSpawn.featuresVariable == "TBD_MOD_FEATURES")
        #expect(SessionModSpawn.incarnationVariable == "TBD_TERMINAL_INCARNATION_ID")
        #expect(readSpawnRecord(sessionsDir: root, sessionID: "sess-1") == SessionModFiles.SpawnRecord(
            sessionId: "sess-1",
            incarnationId: incarnation.uuidString,
            spawnedAtMs: 1_700_000_000_250,
            features: ["composer-draft"]))
    }

    @Test func prepareWithNoFeaturesWritesNothing() throws {
        let root = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(SessionModSpawn.prepare(
            features: [], claudeSessionID: "sess-1", incarnationID: UUID(),
            sessionsDir: root, now: Self.now) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func prepareWithoutASessionIDWritesNothing() throws {
        let root = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(SessionModSpawn.prepare(
            features: [.composerDraft], claudeSessionID: nil, incarnationID: UUID(),
            sessionsDir: root, now: Self.now) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    /// A session ID that is not a plain token never becomes a path, so a spawn
    /// carrying one gets no mod rather than a record written somewhere else.
    @Test func prepareRefusesAnUnsafeSessionID() throws {
        let scratch = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        // Nested, so a `..` that escaped would land inside `scratch` where the
        // test can see it.
        let root = scratch.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for id in ["../escape", "a/b", "", String(repeating: "x", count: 129)] {
            #expect(SessionModSpawn.prepare(
                features: [.composerDraft], claudeSessionID: id, incarnationID: UUID(),
                sessionsDir: root, now: Self.now) == nil,
                "an unsafe session ID \(id) got a spawn record")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path) == ["sessions"])
    }

    @Test func aFailedWriteSpawnsWithoutTheMod() throws {
        let scratch = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        // The sessions dir is a regular file, so no session directory can be
        // created beneath it.
        let root = scratch.appendingPathComponent("sessions")
        try Data("not a directory".utf8).write(to: root)

        #expect(SessionModSpawn.prepare(
            features: [.composerDraft], claudeSessionID: "sess-1", incarnationID: UUID(),
            sessionsDir: root, now: Self.now) == nil)
    }

    @Test func carryForwardCopiesTheLiveIncarnationOnly() throws {
        let root = try makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = UUID()
        try SessionModFiles.writeSpawnRecord(
            .init(sessionId: "before", incarnationId: live.uuidString.lowercased(),
                  spawnedAtMs: 1, features: ["composer-draft"]),
            sessionsDir: root)
        try SessionModFiles.writeSpawnRecord(
            .init(sessionId: "earlier-process", incarnationId: UUID().uuidString,
                  spawnedAtMs: 1, features: ["composer-draft"]),
            sessionsDir: root)

        // The record names the live process (compared as a UUID, whatever its
        // case): the new ID gets the same incarnation and features.
        SessionModSpawn.carryForward(
            fromSessionID: "before", toSessionID: "after", liveIncarnationID: live,
            sessionsDir: root, now: Self.now)
        #expect(readSpawnRecord(sessionsDir: root, sessionID: "after") == SessionModFiles.SpawnRecord(
            sessionId: "after",
            incarnationId: live.uuidString,
            spawnedAtMs: 1_700_000_000_250,
            features: ["composer-draft"]))

        // A record from an earlier process says nothing about this one.
        SessionModSpawn.carryForward(
            fromSessionID: "earlier-process", toSessionID: "after-other", liveIncarnationID: live,
            sessionsDir: root, now: Self.now)
        #expect(readSpawnRecord(sessionsDir: root, sessionID: "after-other") == nil)

        // No live incarnation, a missing source record, or an unsafe target:
        // nothing is written.
        SessionModSpawn.carryForward(
            fromSessionID: "before", toSessionID: "after-nil", liveIncarnationID: nil,
            sessionsDir: root, now: Self.now)
        SessionModSpawn.carryForward(
            fromSessionID: "never-spawned", toSessionID: "after-missing", liveIncarnationID: live,
            sessionsDir: root, now: Self.now)
        SessionModSpawn.carryForward(
            fromSessionID: "before", toSessionID: "../escape", liveIncarnationID: live,
            sessionsDir: root, now: Self.now)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: root.path))
            == ["before", "earlier-process", "after"])
        // The source directory is untouched.
        #expect(readSpawnRecord(sessionsDir: root, sessionID: "before")?.spawnedAtMs == 1)
    }
}
