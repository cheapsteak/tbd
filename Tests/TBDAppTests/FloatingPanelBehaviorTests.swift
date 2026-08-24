import AppKit
import SwiftUI
import Testing
@testable import TBDApp

@Suite("FloatingPanel window behavior")
@MainActor
struct FloatingPanelBehaviorTests {
    // MARK: - Key capability

    @Test func nonKeyByDefault() {
        #expect(FloatingPanel(content: Text("x")).canBecomeKey == false)
    }

    @Test func keyCapableWhenRequested() {
        #expect(FloatingPanel(content: Text("x"), canBecomeKey: true).canBecomeKey == true)
    }

    @Test func jumpMenuPanelStillKeyCapable() {
        #expect(JumpMenuPanel(content: Text("x")).canBecomeKey == true)
    }

    // MARK: - Deactivation behavior
    //
    // WHY these are pinned: window levels are windowserver-global, so a panel at
    // `.popUpMenu` floats above *other applications'* windows, not just TBD's.
    // `hidesOnDeactivate` is the thing that pulls it back down when TBD stops
    // being the active app. NSPanel defaults it to true only for *titled*
    // panels; a `.borderless`/`.nonactivatingPanel` panel like this one opts out
    // of that default, so `FloatingPanel.init` sets it explicitly — and a
    // refactor that dropped that line would silently restore the bug where the
    // hover menu paints over whatever app the user switched to. `.transient`
    // and `.ignoresCycle` keep the same menu-shaped panel out of Mission Control
    // and off other Spaces.

    @Test func hidesOnDeactivateByDefault() {
        #expect(FloatingPanel(content: Text("x")).hidesOnDeactivate == true)
    }

    @Test func hidesOnDeactivateWhenKeyCapable() {
        // The variant `FloatingMenuAnchor` actually constructs for the hover menu.
        #expect(FloatingPanel(content: Text("x"), canBecomeKey: true).hidesOnDeactivate == true)
    }

    @Test func jumpMenuPanelHidesOnDeactivate() {
        #expect(JumpMenuPanel(content: Text("x")).hidesOnDeactivate == true)
    }

    @Test func transientCollectionBehaviorByDefault() {
        #expect(FloatingPanel(content: Text("x")).collectionBehavior == [.transient, .ignoresCycle])
    }

    @Test func transientCollectionBehaviorWhenKeyCapable() {
        let panel = FloatingPanel(content: Text("x"), canBecomeKey: true)
        #expect(panel.collectionBehavior == [.transient, .ignoresCycle])
    }

    @Test func jumpMenuPanelIsTransient() {
        #expect(JumpMenuPanel(content: Text("x")).collectionBehavior == [.transient, .ignoresCycle])
    }
}
