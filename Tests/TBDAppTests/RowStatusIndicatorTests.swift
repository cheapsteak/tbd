import Testing

@testable import TBDApp
import TBDShared

@Suite("RowStatusIndicator.leading")
struct LeadingRowIndicatorTests {
    @Test func prStatusWinsOverPending() {
        #expect(RowStatusIndicator.leading(isPending: true, hasPRStatus: true) == .prStatus)
    }

    @Test func prStatusAlone() {
        #expect(RowStatusIndicator.leading(isPending: false, hasPRStatus: true) == .prStatus)
    }

    @Test func pendingWhenNoPR() {
        #expect(RowStatusIndicator.leading(isPending: true, hasPRStatus: false) == .pending)
    }

    @Test func nothingLeading() {
        #expect(RowStatusIndicator.leading(isPending: false, hasPRStatus: false) == nil)
    }
}

@Suite("RowStatusIndicator.suffix")
struct SuffixRowIndicatorTests {
    @Test func errorOutranksEverything() {
        #expect(RowStatusIndicator.suffix(notification: .error, isWorking: true, isSuspended: true) == .error)
    }

    @Test(arguments: [NotificationType.attentionNeeded, .focusRequest])
    func attentionFromAttentionAndFocus(notification: NotificationType) {
        #expect(RowStatusIndicator.suffix(notification: notification, isWorking: true, isSuspended: true) == .attention)
    }

    @Test func errorOutranksAttentionSource() {
        // A single notification is one type; verify error type beats working/suspended.
        #expect(RowStatusIndicator.suffix(notification: .error, isWorking: false, isSuspended: false) == .error)
    }

    @Test func workingWhenNoErrorOrAttention() {
        #expect(RowStatusIndicator.suffix(notification: nil, isWorking: true, isSuspended: true) == .working)
    }

    @Test(arguments: [NotificationType.taskComplete, .responseComplete])
    func completionNotificationsDoNotProduceSuffix(notification: NotificationType) {
        // taskComplete -> nothing; responseComplete -> bold name (handled in view), no suffix.
        #expect(RowStatusIndicator.suffix(notification: notification, isWorking: false, isSuspended: false) == nil)
    }

    @Test func completionNotificationYieldsToWorking() {
        #expect(RowStatusIndicator.suffix(notification: .responseComplete, isWorking: true, isSuspended: false) == .working)
    }

    @Test func completionNotificationYieldsToSuspended() {
        #expect(RowStatusIndicator.suffix(notification: .taskComplete, isWorking: false, isSuspended: true) == .suspended)
    }

    @Test func suspendedWhenIdle() {
        #expect(RowStatusIndicator.suffix(notification: nil, isWorking: false, isSuspended: true) == .suspended)
    }

    @Test func nothingSuffix() {
        #expect(RowStatusIndicator.suffix(notification: nil, isWorking: false, isSuspended: false) == nil)
    }

    @Test func hibernatedWhenIdleAndHibernated() {
        #expect(RowStatusIndicator.suffix(
            notification: nil, isWorking: false, isSuspended: false, isHibernated: true) == .hibernated)
    }

    @Test func hibernatedIsLowestPriority() {
        // Any louder signal wins the slot over hibernated — it's the calmest state.
        #expect(RowStatusIndicator.suffix(
            notification: nil, isWorking: true, isSuspended: false, isHibernated: true) == .working)
        #expect(RowStatusIndicator.suffix(
            notification: nil, isWorking: false, isSuspended: true, isHibernated: true) == .suspended)
        #expect(RowStatusIndicator.suffix(
            notification: .error, isWorking: false, isSuspended: false, isHibernated: true) == .error)
        #expect(RowStatusIndicator.suffix(
            notification: .attentionNeeded, isWorking: false, isSuspended: false, isHibernated: true) == .attention)
    }

    // MARK: - Prompt on screen

    @Test func promptOnScreenOutranksWorking() {
        // The reported bug: the session IS working (a permission prompt is
        // raised mid-turn), the notification has been auto-marked-read because
        // the worktree is selected, and the row animated the thinking dots.
        #expect(RowStatusIndicator.suffix(
            notification: nil,
            isWorking: true,
            isSuspended: false,
            hasPromptOnScreen: true) == .attention)
    }

    @Test func workingWithoutPromptStillAnimates() {
        #expect(RowStatusIndicator.suffix(
            notification: nil,
            isWorking: true,
            isSuspended: false,
            hasPromptOnScreen: false) == .working)
    }

    @Test func promptOnScreenWithoutWorking() {
        #expect(RowStatusIndicator.suffix(
            notification: nil,
            isWorking: false,
            isSuspended: false,
            hasPromptOnScreen: true) == .attention)
    }

    @Test func errorStillOutranksPromptOnScreen() {
        #expect(RowStatusIndicator.suffix(
            notification: .error,
            isWorking: true,
            isSuspended: false,
            hasPromptOnScreen: true) == .error)
    }

    @Test func promptOnScreenOutranksParked() {
        #expect(RowStatusIndicator.suffix(
            notification: nil,
            isWorking: false,
            isSuspended: false,
            isHibernated: true,
            hasPromptOnScreen: true) == .attention)
    }

    @Test func attentionNotificationStillWorksWithoutPrompt() {
        // The non-selected worktree keeps the pre-existing notification path.
        #expect(RowStatusIndicator.suffix(
            notification: .attentionNeeded,
            isWorking: true,
            isSuspended: false,
            hasPromptOnScreen: false) == .attention)
    }

    @Test func glyphMapping() {
        #expect(SuffixRowIndicator.error.systemImage == "exclamationmark.octagon.fill")
        #expect(SuffixRowIndicator.attention.systemImage == "hand.raised.fill")
        #expect(SuffixRowIndicator.suspended.systemImage == "pause.circle.fill")
        #expect(SuffixRowIndicator.working.systemImage == nil)
        #expect(SuffixRowIndicator.hibernated.systemImage == "moon.zzz.fill")
    }
}

@Suite("RowStatusIndicator.shouldBoldName")
struct ShouldBoldNameTests {
    @Test(arguments: [NotificationType.responseComplete, .attentionNeeded, .focusRequest])
    func boldsForResponseAndAttention(notification: NotificationType) {
        #expect(RowStatusIndicator.shouldBoldName(notification) == true)
    }

    @Test(arguments: [NotificationType.error, .taskComplete])
    func doesNotBoldForErrorOrTaskComplete(notification: NotificationType) {
        #expect(RowStatusIndicator.shouldBoldName(notification) == false)
    }

    @Test func doesNotBoldForNoNotification() {
        #expect(RowStatusIndicator.shouldBoldName(nil) == false)
    }

    /// The row this fix targets has no unread notification left — it was
    /// auto-marked-read on selection — so without this the raised hand would
    /// sit beside a regular-weight name.
    @Test func boldsForAPromptOnScreenWithNoNotification() {
        #expect(RowStatusIndicator.shouldBoldName(nil, hasPromptOnScreen: true) == true)
    }

    @Test func aPromptOnScreenBoldsEvenOverANonBoldingNotification() {
        #expect(RowStatusIndicator.shouldBoldName(.taskComplete, hasPromptOnScreen: true) == true)
    }

    @Test func doesNotBoldWhenThereIsNoPromptAndNoNotification() {
        #expect(RowStatusIndicator.shouldBoldName(nil, hasPromptOnScreen: false) == false)
    }
}
