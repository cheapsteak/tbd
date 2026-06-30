import AppKit
import Testing

@testable import TBDApp

@Suite("TypingDotsView")
struct TypingDotsViewTests {
    @MainActor
    @Test func nsViewIsLayerBackedWithThreeAnimatedDots() {
        let view = TypingDotsNSView(dotColor: .systemRed)
        #expect(view.wantsLayer)
        let dots = view.layer?.sublayers ?? []
        #expect(dots.count == 3)
        // Each dot carries a repeating opacity animation added at construction.
        for dot in dots {
            #expect(dot.animation(forKey: "typingPulse") != nil)
        }
    }
}
