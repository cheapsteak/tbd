import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

/// Composer drafts, transcript streaming and prompt answers each ship on, so a
/// spawn made with the shipped config carries all three. A test that pins one
/// feature's effect on a spawn — its feature list, its environment, its spawn
/// record — first turns the others off, so what it sees is that feature alone.
extension ConfigStore {
    /// Turns transcript streaming, prompt answers and session usage off and
    /// sets composer drafts to `composerDraft`, so composer drafts are the only
    /// session-mod feature a spawn can carry. Automatic parking still holds
    /// composer drafts on whatever this writes.
    public func setComposerDraftAsTheOnlyModFeature(_ composerDraft: Bool) async throws {
        try await setTranscriptStreamingEnabled(false)
        try await setTranscriptPromptAnswerEnabled(false)
        try await setSessionModUsageEnabled(false)
        try await setComposerDraftEnabled(composerDraft)
    }

    /// Turns every session-mod feature off, so a spawn carries no mod unless
    /// a test turns one back on.
    public func setEverySessionModFeatureOff() async throws {
        try await setComposerDraftAsTheOnlyModFeature(false)
    }
}

extension Config {
    /// The shipped config with every session-mod feature off, for unit tests
    /// that build a feature list one feature at a time.
    public static var withoutSessionModFeatures: Config {
        var config = Config()
        config.composerDraftEnabled = false
        config.transcriptStreamingEnabled = false
        config.sessionModUsageEnabled = false
        config.transcriptPromptAnswerEnabled = false
        return config
    }
}
