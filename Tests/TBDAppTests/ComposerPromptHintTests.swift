import Foundation
import Testing
@testable import TBDApp
import TBDShared

// The composer's "prompt above" hint: shown while an open card can be answered
// from the transcript, and the remote blocked note that matches it.
// Design: docs/specs/2026-10-09-transcript-prompt-answer-design.md,
// "The awaiting-input gate".

@MainActor
@Suite("Composer prompt hint")
struct ComposerPromptHintTests {
    typealias Fix = PromptFixtures

    private func merged(_ prompts: [PendingPromptPresentation]) -> PendingPromptMerge.Merged {
        PendingPromptMerge.apply(items: [], prompts: prompts)
    }

    private func remote(capabilities: [String], flagOn: Bool) -> PendingPromptPresentation {
        .remote(
            RemotePendingPrompt(id: "r1", kind: .permission, toolName: "Bash"),
            selection: Fix.selection, capabilities: capabilities, flagOn: flagOn, now: Fix.when)
    }

    @Test func noPromptMeansNoHint() {
        #expect(merged([]).answerableCardItemID == nil)
    }

    @Test func localOpenPromptWithFlagOnOffersTheHint() {
        let result = merged([Fix.local(Fix.permissionPayload(), flagOn: true)])
        #expect(result.answerableCardItemID == "toolu_X")
    }

    @Test func flagOffHidesTheHint() {
        let result = merged([Fix.local(Fix.permissionPayload(), flagOn: false)])
        #expect(result.answerableCardItemID == nil)
    }

    @Test func remoteNeedsTheAnswerCapability() {
        #expect(merged([remote(capabilities: [RemoteCapability.answer], flagOn: true)])
            .answerableCardItemID != nil)
        #expect(merged([remote(capabilities: ["events"], flagOn: true)])
            .answerableCardItemID == nil)
        #expect(merged([remote(capabilities: [RemoteCapability.answer], flagOn: false)])
            .answerableCardItemID == nil)
    }

    @Test func aClosedCardOffersNoHint() {
        var card = Fix.local(Fix.permissionPayload(), flagOn: true)
        card.phase = .closed
        #expect(merged([card]).answerableCardItemID == nil)
    }

    @Test func bannerTextIsTheHintOnlyWhileTheHintIsOffered() {
        #expect(MessageComposerView.blockedBannerText(message: "terminal text", hasPromptHint: true)
            == "Claude is waiting on a prompt above")
        #expect(MessageComposerView.blockedBannerText(message: "terminal text", hasPromptHint: false)
            == "terminal text")
    }

    @Test func remoteBlockedNoteFollowsAnswerability() {
        #expect(RemoteComposerState.blocked.disabledMessage(promptAnswerable: true)
            == "Claude is waiting on a prompt above")
        #expect(RemoteComposerState.blocked.disabledMessage(promptAnswerable: false)
            == "Waiting on a prompt — answer it in the terminal")
        #expect(RemoteComposerState.blocked.composerState(promptAnswerable: true)
            == .blocked(message: "Claude is waiting on a prompt above"))
        #expect(RemoteComposerState.running.disabledMessage(promptAnswerable: true) == nil)
    }

    @Test func eachHintTapIssuesANewScrollRequest() {
        let first = TranscriptScrollRequest.next(after: nil, itemID: "toolu_X")
        let second = TranscriptScrollRequest.next(after: first, itemID: "toolu_X")
        #expect(first.itemID == "toolu_X")
        #expect(first != second)
        #expect(second.token == first.token + 1)
    }
}
