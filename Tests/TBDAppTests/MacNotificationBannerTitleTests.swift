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
}
