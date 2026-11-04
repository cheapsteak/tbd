import Testing
import DaemonTestSupport
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("SessionModFeature")
struct SessionModFeatureTests {
    @Test func rawValueIsTheModFeatureName() {
        #expect(SessionModFeature.promptAnswer.rawValue == "prompt-answer")
    }

    @Test func enabledListsPromptAnswerWhenFlagOn() {
        var config = Config.withoutSessionModFeatures
        config.transcriptPromptAnswerEnabled = true
        #expect(SessionModFeature.enabled(in: config) == [.promptAnswer])
    }

    @Test func enabledOmitsPromptAnswerWhenFlagOff() {
        var config = Config.withoutSessionModFeatures
        config.transcriptPromptAnswerEnabled = false
        config.composerDraftEnabled = true
        #expect(SessionModFeature.enabled(in: config) == [.composerDraft])
        config.composerDraftEnabled = false
        #expect(SessionModFeature.enabled(in: config).isEmpty)
    }

    @Test func bothOnFollowsAllCasesOrder() {
        var config = Config.withoutSessionModFeatures
        config.composerDraftEnabled = true
        config.transcriptPromptAnswerEnabled = true
        #expect(SessionModFeature.enabled(in: config) == [.composerDraft, .promptAnswer])
    }

    /// The shipped config turns on every feature but session usage.
    @Test func theShippedConfigListsEveryFeatureButUsage() {
        #expect(SessionModFeature.enabled(in: Config())
            == [.composerDraft, .transcriptStream, .promptAnswer])
    }

    @Test func everyFeatureOnFollowsAllCasesOrder() {
        var config = Config.withoutSessionModFeatures
        config.composerDraftEnabled = true
        config.transcriptStreamingEnabled = true
        config.sessionModUsageEnabled = true
        config.transcriptPromptAnswerEnabled = true
        #expect(SessionModFeature.enabled(in: config)
            == [.composerDraft, .transcriptStream, .usage, .promptAnswer])
    }
}
