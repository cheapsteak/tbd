import CoreGraphics
import Testing
@testable import TBDApp

@Suite("PromptRailLayout")
struct PromptRailLayoutTests {
    private static func isClose(_ a: CGFloat, _ b: CGFloat, within tolerance: CGFloat = 1e-9) -> Bool {
        abs(a - b) <= tolerance
    }

    /// The lens's need at the shipped strength: `26 × 6 / 0.85`, about 184pt.
    @Test func lensNeedAtShippedStrength() {
        #expect(PromptRailLayout.lensPeak == 26)
        #expect(PromptRailLayout.lensRadius == 6)
        #expect(Self.isClose(PromptRailLayout.lensNeed, 26 * 6 / 0.85))
        #expect(Self.isClose(PromptRailLayout.lensNeed, 183.53, within: 0.01))
    }

    /// In a 600pt rail (576pt free) a short session spreads its notches over
    /// the lens's need, mid-length sessions keep 8pt, and long ones divide
    /// the free height down to the 4pt floor.
    @Test func pitchMakesRoomForTheLens() {
        func pitch(_ count: Int) -> CGFloat {
            PromptRailLayout(count: count, railHeight: 600).pitch
        }
        let need = PromptRailLayout.lensNeed
        #expect(Self.isClose(pitch(1), need), "1 prompt rests \(pitch(1)) apart")
        #expect(Self.isClose(pitch(12), need / 12), "12 prompts rest \(pitch(12)) apart")
        #expect(Self.isClose(pitch(23), 8), "23 prompts rest \(pitch(23)) apart")
        #expect(Self.isClose(pitch(40), 8), "40 prompts rest \(pitch(40)) apart")
        #expect(Self.isClose(pitch(72), 8), "72 prompts rest \(pitch(72)) apart")
        #expect(Self.isClose(pitch(120), 4.8), "120 prompts rest \(pitch(120)) apart")
        #expect(Self.isClose(pitch(300), 4), "300 prompts rest \(pitch(300)) apart")
        #expect(Self.isClose(pitch(0), 8), "no prompts rest \(pitch(0)) apart")

        // The column is capped at the free height: 100 − 24 = 76pt.
        let cramped = PromptRailLayout(count: 1, railHeight: 100)
        #expect(Self.isClose(cramped.pitch, 76), "a cramped rail rests its prompt \(cramped.pitch) apart")

        let short = PromptRailLayout(count: 12, railHeight: 600)
        #expect(Self.isClose(short.contentHeight, 24 + need),
                "12 prompts' content is \(short.contentHeight)pt, not \(24 + need)")
        #expect(!short.overflows)
    }

    /// 19 prompts in a 108pt rail rest at `84 / 19`, and `19 × (84 / 19)`
    /// rounds past 84 by about 1e-14. That is no overflow: the rail neither
    /// windows nor offsets its notches.
    @Test func roundedPitchDoesNotOverflow() throws {
        let layout = PromptRailLayout(count: 19, railHeight: 108)
        try #require(layout.pitch == 84 / CGFloat(19), "precondition: 19 prompts in 108pt rest at the free pitch")
        try #require(layout.contentHeight > 108,
                     "precondition: the content rounds past the rail, by \(layout.contentHeight - 108)")
        #expect(!layout.overflows, "a rounding error windowed the rail")
        #expect(layout.scrollOffset(keepingVisible: 18, current: 0) == 0)
        let geometry = PromptRailLensGeometry(layout: layout, restOffset: 0)
        #expect(!geometry.restOverflows)
    }

    @Test func overflowOffsetKeepsActiveInsideMargins() {
        let layout = PromptRailLayout(count: 300, railHeight: 600)
        #expect(layout.overflows)
        #expect(layout.scrollOffset(keepingVisible: 0, current: 0) == 0)
        #expect(layout.scrollOffset(keepingVisible: 299, current: 0) == layout.contentHeight - 600)
        let offset = layout.scrollOffset(keepingVisible: 150, current: 0)
        #expect((40...560).contains(layout.notchCenterY(150) - offset))

        let fits = PromptRailLayout(count: 10, railHeight: 600)
        #expect(!fits.overflows)
        #expect(fits.scrollOffset(keepingVisible: 5, current: 30) == 0)
    }

    /// The length is the turn's work; activity changes only the thickness.
    @Test func notchRectTakesItsLengthAndActiveThickness() {
        let layout = PromptRailLayout(count: 5, railHeight: 600)
        let center = layout.notchCenterY(2)
        #expect(layout.notchRect(2, active: false, length: 9)
                    == CGRect(x: 2, y: center - 1, width: 9, height: 2))
        #expect(layout.notchRect(2, active: true, length: 9)
                    == CGRect(x: 2, y: center - 1.5, width: 9, height: 3))
        #expect(PromptRailLayout.notchLeading == 2)
    }

    @Test func hitTestFindsNearestNotch() {
        let layout = PromptRailLayout(count: 10, railHeight: 600)
        #expect(layout.index(atRailY: layout.notchCenterY(3), offset: 0) == 3)
        #expect(layout.index(atRailY: 0, offset: 0) == 0)
        #expect(layout.index(atRailY: 599, offset: 0) == 9)
        #expect(PromptRailLayout(count: 0, railHeight: 600).index(atRailY: 10, offset: 0) == nil)
    }
}
