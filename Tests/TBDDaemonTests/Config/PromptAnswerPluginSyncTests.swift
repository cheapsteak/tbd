import Foundation
import Testing
import DaemonTestSupport
import TestSupport

@testable import TBDDaemonLib
@testable import TBDShared

private final class PluginSyncRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[SessionModFeature]] = []
    func append(_ features: [SessionModFeature]) { lock.withLock { calls.append(features) } }
    func snapshot() -> [[SessionModFeature]] { lock.withLock { calls } }
}

@Suite("PromptAnswerPluginSync")
struct PromptAnswerPluginSyncTests {
    private func makeRouter() throws -> RPCRouter {
        let db = try TBDDatabase(inMemory: true)
        return RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())
    }

    /// Turning the flag on adds `.promptAnswer`; off removes it. A composer
    /// draft flag left on keeps the mod in the list.
    @Test func setterSyncsThePluginWithTheFreshFeatures() async throws {
        let router = try makeRouter()
        let recorder = PluginSyncRecorder()
        router.sessionModPluginSync = { recorder.append($0) }

        for value in [true, false] {
            let request = try RPCRequest(
                method: RPCMethod.configSetTranscriptPromptAnswerEnabled,
                params: ConfigSetPromptAnswerParams(enabled: value))
            #expect(await router.handle(request).success)
        }
        #expect(recorder.snapshot() == [[.promptAnswer], []])

        let draftOn = try RPCRequest(
            method: RPCMethod.configSetComposerDraftEnabled,
            params: ConfigSetComposerDraftEnabledParams(enabled: true))
        #expect(await router.handle(draftOn).success)
        let answerOn = try RPCRequest(
            method: RPCMethod.configSetTranscriptPromptAnswerEnabled,
            params: ConfigSetPromptAnswerParams(enabled: true))
        #expect(await router.handle(answerOn).success)
        #expect(recorder.snapshot().last == [.composerDraft, .promptAnswer])
    }

    /// With no sync hook installed the setter still succeeds.
    @Test func setterWithoutAHookStillSucceeds() async throws {
        let router = try makeRouter()
        let request = try RPCRequest(
            method: RPCMethod.configSetTranscriptPromptAnswerEnabled,
            params: ConfigSetPromptAnswerParams(enabled: true))
        #expect(await router.handle(request).success)
    }
}
