import Testing
@testable import TBDApp
import TBDShared

@Suite("MacNotificationManager.bannerTitle")
struct MacNotificationBannerTitleTests {
    @Test func focusRequestGetsEmojiPrefix() {
        let title = MacNotificationManager.bannerTitle(worktreeName: "acme", type: .focusRequest)
        #expect(title == "🎯 acme")
    }

    @Test func otherTypesAreUnchanged() {
        for type: NotificationType in [.responseComplete, .error, .taskComplete, .attentionNeeded] {
            #expect(MacNotificationManager.bannerTitle(worktreeName: "acme", type: type) == "acme")
        }
    }

    @Test func focusRequestFallbackIsAttentionNeeded() {
        #expect(MacNotificationManager.bannerBody(message: nil, type: .focusRequest) == "Attention needed.")
    }

    @Test func responseCompleteFallbackIsFinishedResponding() {
        #expect(MacNotificationManager.bannerBody(message: nil, type: .responseComplete)
            == "Claude has finished responding.")
    }

    @Test func suppliedMessageIsUsedVerbatim() {
        #expect(MacNotificationManager.bannerBody(message: "hi", type: .focusRequest) == "hi")
    }

    @Test func longMessageIsTruncatedTo200CharsPlusEllipsis() {
        let input = String(repeating: "a", count: 250)
        let body = MacNotificationManager.bannerBody(message: input, type: .responseComplete)
        #expect(body.count == 201)
        #expect(body.hasSuffix("…"))
    }
}

@Suite("MacNotificationManager.shouldPost")
struct MacNotificationShouldPostTests {
    @Test func mockModeSuppressesEvenWhenEnabledAndAvailable() {
        #expect(MacNotificationManager.shouldPost(enabled: true, isAvailable: true, mockActive: true) == false)
    }

    @Test func normalModeEnabledAndAvailablePosts() {
        #expect(MacNotificationManager.shouldPost(enabled: true, isAvailable: true, mockActive: false) == true)
    }

    @Test func disabledDoesNotPost() {
        #expect(MacNotificationManager.shouldPost(enabled: false, isAvailable: true, mockActive: false) == false)
    }

    @Test func unavailableDoesNotPost() {
        #expect(MacNotificationManager.shouldPost(enabled: true, isAvailable: false, mockActive: false) == false)
    }
}
