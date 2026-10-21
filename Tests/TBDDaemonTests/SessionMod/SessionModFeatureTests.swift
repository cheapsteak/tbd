import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("SessionModFeature")
struct SessionModFeatureTests {
    @Test func rawValueIsTheModFeatureName() {
        #expect(SessionModFeature.promptAnswer.rawValue == "prompt-answer")
    }

    @Test func enabledListsPromptAnswerWhenFlagOn() {
        var config = Config()
        config.transcriptPromptAnswerEnabled = true
        #expect(SessionModFeature.enabled(in: config) == [.promptAnswer])
    }

    @Test func enabledOmitsPromptAnswerWhenFlagOff() {
        var config = Config()
        config.transcriptPromptAnswerEnabled = false
        config.composerDraftEnabled = true
        #expect(SessionModFeature.enabled(in: config) == [.composerDraft])
        config.composerDraftEnabled = false
        #expect(SessionModFeature.enabled(in: config).isEmpty)
    }

    @Test func bothOnFollowsAllCasesOrder() {
        var config = Config()
        config.composerDraftEnabled = true
        config.transcriptPromptAnswerEnabled = true
        #expect(SessionModFeature.enabled(in: config) == [.composerDraft, .promptAnswer])
    }

    @Test func everyFeatureOnFollowsAllCasesOrder() {
        var config = Config()
        config.composerDraftEnabled = true
        config.transcriptStreamingEnabled = true
        config.sessionModUsageEnabled = true
        config.transcriptPromptAnswerEnabled = true
        #expect(SessionModFeature.enabled(in: config)
            == [.composerDraft, .transcriptStream, .usage, .promptAnswer])
    }
}
