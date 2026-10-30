import Foundation
import Testing
import DaemonTestSupport
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// Records each feature list the router hands `sessionModPluginSync`.
private final class PluginSyncRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[SessionModFeature]] = []

    func append(_ features: [SessionModFeature]) {
        lock.withLock { calls.append(features) }
    }

    func snapshot() -> [[SessionModFeature]] {
        lock.withLock { calls }
    }
}

/// The session mod's `transcript-stream` feature is spawned exactly when
/// `transcript_streaming_enabled` is on, beside composer-draft
/// (docs/specs/2026-10-20-transcript-stream-mod-design.md, "Flag").
@Suite struct TranscriptStreamFeatureTests {

    @Test func theRawValueIsTheModsFeatureName() {
        #expect(SessionModFeature.transcriptStream.rawValue == "transcript-stream")
    }

    @Test func theFeatureListNamesTranscriptStreamExactlyWhenTheFlagIsOn() {
        var config = Config()
        config.composerDraftEnabled = false
        config.transcriptStreamingEnabled = false
        #expect(SessionModFeature.enabled(in: config) == [])

        config.transcriptStreamingEnabled = true
        #expect(SessionModFeature.enabled(in: config) == [.transcriptStream])

        config.composerDraftEnabled = true
        #expect(SessionModFeature.enabled(in: config) == [.composerDraft, .transcriptStream])

        config.transcriptStreamingEnabled = false
        #expect(SessionModFeature.enabled(in: config) == [.composerDraft])
    }

    @Test func theShippedConfigSpawnsNoTranscriptStream() {
        #expect(!SessionModFeature.enabled(in: Config()).contains(.transcriptStream))
    }

    @Test func theSpawnEnvironmentListsTheFeature() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-transcript-stream-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let context = try #require(SessionModSpawn.prepare(
            features: [.transcriptStream, .composerDraft],
            claudeSessionID: "sess-1",
            incarnationID: UUID(),
            sessionsDir: root,
            now: Date(timeIntervalSince1970: 1_700_000_000)))

        #expect(context.environment[SessionModSpawn.featuresVariable] == "composer-draft,transcript-stream")
    }

    /// The setter re-syncs the plugin with the features the fresh config turns
    /// on, so the mod is on disk for the next spawn.
    @Test func theStreamingSetterSyncsThePluginWithTheFreshFeatures() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())
        let recorder = PluginSyncRecorder()
        router.sessionModPluginSync = { recorder.append($0) }

        for value in [true, false] {
            let response = await router.handle(try RPCRequest(
                method: RPCMethod.configSetTranscriptStreamingEnabled,
                params: ConfigSetTranscriptStreamingParams(enabled: value)))
            #expect(response.success)
        }

        #expect(recorder.snapshot() == [[.transcriptStream], []])
    }
}
