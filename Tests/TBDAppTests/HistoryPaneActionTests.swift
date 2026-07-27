import Testing
@testable import TBDApp

@Suite("History transcript header actions")
struct HistoryPaneActionTests {
    @Test("active transcript presents one prominent resume action")
    func activeTranscriptPresentsResume() {
        #expect(TranscriptHeaderActions.descriptors(
            for: .resume, defaultBranch: "main"
        ) == [
            .init(kind: .resume, title: "Resume", prominent: true)
        ])
    }

    @Test("archived transcript presents original and fresh branch actions")
    func archivedTranscriptPresentsBothReviveActions() {
        #expect(TranscriptHeaderActions.descriptors(
            for: .reviveWithSession, defaultBranch: "master"
        ) == [
            .init(kind: .reviveOriginal, title: "in original branch", prominent: true),
            .init(kind: .reviveFresh, title: "on fresh master", prominent: false)
        ])
    }

    @Test("archived transcript labels its revive choices")
    func archivedTranscriptRevivePrefix() {
        #expect(TranscriptHeaderActions.revivePrefix == "Revive this session:")
    }
}
