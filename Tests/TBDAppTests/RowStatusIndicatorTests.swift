import Testing

@testable import TBDApp
import TBDShared

@Suite("RowStatusIndicator")
struct RowStatusIndicatorTests {
    @Test func pendingWinsOverEverything() {
        let result = RowStatusIndicator.resolve(
            isPending: true,
            isWorking: true,
            notification: .error,
            isSuspended: true,
            hasPRStatus: true
        )
        #expect(result == .pendingSpinner)
    }

    @Test func workingWinsOverNotificationSuspendedAndPR() {
        let result = RowStatusIndicator.resolve(
            isPending: false,
            isWorking: true,
            notification: .taskComplete,
            isSuspended: true,
            hasPRStatus: true
        )
        #expect(result == .workingSpinner)
    }

    @Test func workingSpinnerHidesPRStatus() {
        let result = RowStatusIndicator.resolve(
            isPending: false,
            isWorking: true,
            notification: nil,
            isSuspended: false,
            hasPRStatus: true
        )
        #expect(result == .workingSpinner)
    }

    @Test func notificationWinsOverSuspendedAndPR() {
        let result = RowStatusIndicator.resolve(
            isPending: false,
            isWorking: false,
            notification: .responseComplete,
            isSuspended: true,
            hasPRStatus: true
        )
        #expect(result == .notificationBadge(.responseComplete))
    }

    @Test func suspendedWinsOverPR() {
        let result = RowStatusIndicator.resolve(
            isPending: false,
            isWorking: false,
            notification: nil,
            isSuspended: true,
            hasPRStatus: true
        )
        #expect(result == .suspended)
    }

    @Test func prStatusAlone() {
        let result = RowStatusIndicator.resolve(
            isPending: false,
            isWorking: false,
            notification: nil,
            isSuspended: false,
            hasPRStatus: true
        )
        #expect(result == .prStatus)
    }

    @Test func nothingSetReturnsNil() {
        let result = RowStatusIndicator.resolve(
            isPending: false,
            isWorking: false,
            notification: nil,
            isSuspended: false,
            hasPRStatus: false
        )
        #expect(result == nil)
    }
}
