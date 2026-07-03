import Testing
import Foundation
import TBDShared
@testable import TBDApp

/// Pins the M2 paste ruling's view-level interception decision (rider 1 + rider 2).
/// The Coordinator's `onLargePaste` closure carries no untested conditional — the
/// whole size/attach gate lives here, one assertion per branch.
///
/// The ruling: only >4 KiB pastes are intercepted at the view level (SwiftTerm's
/// ≤4 KiB three-call bracketed sequence is correct and ordered when it rides the
/// keystroke path, so it is NOT intercepted). Oversize pastes (> the sidecar
/// paste cap) fall back to SwiftTerm's normal paste rather than being split.
@Suite("PasteInterception.shouldIntercept")
struct PasteInterceptionTests {
    @Test("threshold is 4096 bytes")
    func thresholdConstant() {
        #expect(PasteInterception.thresholdBytes == 4096)
    }

    @Test("not attached → never intercept, regardless of size")
    func notAttached() {
        #expect(!PasteInterception.shouldIntercept(controlModeAttached: false, byteCount: 1))
        #expect(!PasteInterception.shouldIntercept(controlModeAttached: false, byteCount: 100_000))
        #expect(!PasteInterception.shouldIntercept(controlModeAttached: false, byteCount: 0))
    }

    @Test("attached + at-or-below threshold → do not intercept (SwiftTerm 3-call path is ordered)")
    func atOrBelowThreshold() {
        #expect(!PasteInterception.shouldIntercept(controlModeAttached: true, byteCount: 1))
        #expect(!PasteInterception.shouldIntercept(controlModeAttached: true, byteCount: 4096))
    }

    @Test("attached + just over threshold → intercept")
    func justOverThreshold() {
        #expect(PasteInterception.shouldIntercept(controlModeAttached: true, byteCount: 4097))
    }

    @Test("attached + within the paste cap → intercept")
    func withinCap() {
        #expect(PasteInterception.shouldIntercept(
            controlModeAttached: true, byteCount: SidecarFrameCodec.maxPasteBytes))
    }

    @Test("attached but over the paste cap → do not intercept (fall back to keystroke path)")
    func overCapFallsBack() {
        #expect(!PasteInterception.shouldIntercept(
            controlModeAttached: true, byteCount: SidecarFrameCodec.maxPasteBytes + 1))
    }
}
