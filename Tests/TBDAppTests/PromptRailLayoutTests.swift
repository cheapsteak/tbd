import CoreGraphics
import Testing
@testable import TBDApp

@Suite("PromptRailLayout")
struct PromptRailLayoutTests {
    @Test func pitchClampsAndDivides() {
        #expect(PromptRailLayout(count: 10, railHeight: 600).pitch == 8)
        #expect(PromptRailLayout(count: 200, railHeight: 600).pitch == 4)
        #expect(PromptRailLayout(count: 100, railHeight: 524).pitch == 5)
        #expect(PromptRailLayout(count: 0, railHeight: 600).pitch == 8)
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
