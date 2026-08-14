import AppKit
import Testing
@testable import TBDApp

@Suite("Accessibility window geometry guard", .serialized)
@MainActor
struct AccessibilityWindowGeometryGuardTests {
    @Test("rejects a non-finite Accessibility position")
    func rejectsNonFinitePosition() {
        AccessibilityWindowGeometryGuard.install()
        let window = makeWindow()
        let originalFrame = window.frame

        setAccessibilityValue(
            NSValue(point: NSPoint(x: -556, y: CGFloat.nan)),
            selectorName: "accessibilitySetPositionAttribute:",
            on: window
        )

        #expect(window.frame == originalFrame)
    }

    @Test("forwards a finite Accessibility position")
    func forwardsFinitePosition() {
        AccessibilityWindowGeometryGuard.install()
        let window = makeWindow()

        setAccessibilityValue(
            NSValue(point: NSPoint(x: 40, y: 50)),
            selectorName: "accessibilitySetPositionAttribute:",
            on: window
        )

        #expect(window.frame.origin == NSPoint(x: 40, y: 50))
    }

    @Test("rejects a non-finite Accessibility size")
    func rejectsNonFiniteSize() {
        AccessibilityWindowGeometryGuard.install()
        let window = makeWindow()
        let originalFrame = window.frame

        setAccessibilityValue(
            NSValue(size: NSSize(width: CGFloat.infinity, height: 240)),
            selectorName: "accessibilitySetSizeAttribute:",
            on: window
        )

        #expect(window.frame == originalFrame)
    }

    @Test("forwards a finite Accessibility size")
    func forwardsFiniteSize() {
        AccessibilityWindowGeometryGuard.install()
        let window = makeWindow()
        let originalSize = window.frame.size

        setAccessibilityValue(
            NSValue(size: NSSize(width: 420, height: 310)),
            selectorName: "accessibilitySetSizeAttribute:",
            on: window
        )

        #expect(window.frame.size != originalSize)
        #expect(window.frame.width == 420)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 10, y: 20, width: 320, height: 240),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    private func setAccessibilityValue(
        _ value: NSValue,
        selectorName: String,
        on window: NSWindow
    ) {
        let selector = NSSelectorFromString(selectorName)
        #expect(window.responds(to: selector))
        _ = window.perform(selector, with: value)
    }
}
