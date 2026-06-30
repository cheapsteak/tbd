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

    @Test func glyphMapping() {
        #expect(SuffixRowIndicator.error.systemImage == "exclamationmark.octagon.fill")
        #expect(SuffixRowIndicator.attention.systemImage == "hand.raised.fill")
        #expect(SuffixRowIndicator.suspended.systemImage == "pause.circle.fill")
        #expect(SuffixRowIndicator.working.systemImage == nil)
    }
}
