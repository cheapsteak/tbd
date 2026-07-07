import Foundation
import Testing
@testable import TBDApp
import TBDShared

@Suite("SwapProfileMenu — busy-session warning")
struct SwapProfileMenuTests {
    @Test func inPlaceSwapOfBusySessionWarnsAboutInterrupt() {
        let caption = SwapProfileMenu.busyCaption(mode: .inPlace, activityState: .working)
        #expect(caption == SwapProfileMenu.interruptsRunCaption)
        #expect(caption?.contains("interrupts current run") == true)
    }

    @Test func inPlaceSwapOfNonBusySessionHasNoWarning() {
        #expect(SwapProfileMenu.busyCaption(mode: .inPlace, activityState: .idle) == nil)
        #expect(SwapProfileMenu.busyCaption(mode: .inPlace, activityState: .unknown) == nil)
        #expect(SwapProfileMenu.busyCaption(mode: .inPlace, activityState: nil) == nil)
    }

    @Test func forkNeverWarnsEvenWhenBusy() {
        // Forking duplicates the conversation into a new tab and leaves the
        // source session untouched — no interruption to warn about.
        #expect(SwapProfileMenu.busyCaption(mode: .fork, activityState: .working) == nil)
        #expect(SwapProfileMenu.busyCaption(mode: .fork, activityState: .idle) == nil)
    }
}
