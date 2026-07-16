import AppKit
import SwiftUI
import Testing
@testable import TBDApp

@Suite("FloatingPanel key capability")
@MainActor
struct FloatingPanelKeyTests {
    @Test func nonKeyByDefault() {
        #expect(FloatingPanel(content: Text("x")).canBecomeKey == false)
    }

    @Test func keyCapableWhenRequested() {
        #expect(FloatingPanel(content: Text("x"), canBecomeKey: true).canBecomeKey == true)
    }

    @Test func jumpMenuPanelStillKeyCapable() {
        #expect(JumpMenuPanel(content: Text("x")).canBecomeKey == true)
    }
}
