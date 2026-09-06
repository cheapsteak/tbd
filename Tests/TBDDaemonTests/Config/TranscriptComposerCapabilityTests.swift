import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The composer flag reaches the app the way every other soak flag does: through
/// `daemon.capabilities`, resolved daemon-side, so the Settings toggle and the
/// daemon can never disagree about which of them last wrote the column.
@Suite("Transcript composer capability")
struct TranscriptComposerCapabilityTests {

    /// A throwaway actuation log per fixture. `ActuationLog` takes a PATH, not a
    /// database — the record is an append-only JSONL file.
    private static func scratchLogPath() -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-plan-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("actuations.jsonl").path
    }

    @Test func capabilitiesCarryTheFlag() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tmux = TmuxManager(dryRun: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            actuationLog: ActuationLog(path: Self.scratchLogPath()))

        let off = try await router.handleDaemonCapabilities()
        let offResult = try JSONDecoder().decode(
            DaemonCapabilitiesResult.self, from: Data((off.result ?? "{}").utf8))
        #expect(offResult.transcriptComposerEnabled == false)

        try await db.config.setTranscriptComposerEnabled(true)
        let on = try await router.handleDaemonCapabilities()
        let onResult = try JSONDecoder().decode(
            DaemonCapabilitiesResult.self, from: Data((on.result ?? "{}").utf8))
        #expect(onResult.transcriptComposerEnabled)
    }

    /// An older daemon sends no such key. It has no composer either, so the app
    /// must fall through to the shipped default rather than assume the feature
    /// is live.
    @Test func anOlderDaemonsPayloadFollowsTheShippedDefault() throws {
        let legacy = #"{"controlModeEnabled":false}"#
        let decoded = try JSONDecoder().decode(
            DaemonCapabilitiesResult.self, from: Data(legacy.utf8))
        #expect(decoded.transcriptComposerEnabled == Config.transcriptComposerEnabledDefault)
    }

    @Test func theSetterHandlerWritesTheColumn() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tmux = TmuxManager(dryRun: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            actuationLog: ActuationLog(path: Self.scratchLogPath()))
        let data = try JSONEncoder().encode(
            ConfigSetTranscriptComposerEnabledParams(enabled: true))

        let response = try await router.handleConfigSetTranscriptComposerEnabled(data)

        #expect(response.success)
        #expect(try await db.config.get().transcriptComposerEnabled)
    }
}
