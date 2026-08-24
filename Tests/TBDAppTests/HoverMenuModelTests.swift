import AppKit
import Testing
import SwiftUI
@testable import TBDApp

@Suite("HoverMenuModel")
@MainActor
struct HoverMenuModelTests {
    // MARK: pure gating helpers

    @Test("plain click creates a default worktree")
    func plainClickOutcome() {
        #expect(HoverMenuModel.plusOutcome(optionHeld: false) == .createDefault)
    }

    @Test("option-click opens the menu")
    func optionClickOutcome() {
        #expect(HoverMenuModel.plusOutcome(optionHeld: true) == .openMenu)
    }

    @Test("plus is hidden when neither hovered nor open")
    func plusHiddenWhenIdle() {
        #expect(HoverMenuModel.shouldShowPlus(hovered: false, menuOpen: false) == false)
    }

    @Test("plus shows when hovered")
    func plusShownWhenHovered() {
        #expect(HoverMenuModel.shouldShowPlus(hovered: true, menuOpen: false) == true)
    }

    @Test("plus stays mounted while its menu is open even if hover dropped")
    func plusShownWhenMenuOpen() {
        #expect(HoverMenuModel.shouldShowPlus(hovered: false, menuOpen: true) == true)
    }

    // MARK: open/close state (zero delays for determinism)

    @Test("hovering the trigger opens the menu after intent")
    func hoverOpens() async {
        let m = HoverMenuModel(openDelay: .zero, closeGrace: .zero)
        m.triggerHover(true)
        await m._drainForTesting()
        #expect(m.isOpen)
    }

    @Test("leaving both trigger and menu closes it")
    func leavingCloses() async {
        let m = HoverMenuModel(openDelay: .zero, closeGrace: .zero)
        m.openImmediately()
        m.triggerHover(false)
        m.menuHover(false)
        await m._drainForTesting()
        #expect(!m.isOpen)
    }

    @Test("moving from trigger into menu keeps it open (close is cancelled)")
    func reenterCancelsClose() async {
        let m = HoverMenuModel(openDelay: .zero, closeGrace: .zero)
        m.openImmediately()
        m.triggerHover(false)  // leaving the button schedules a close
        m.menuHover(true)      // ...but the pointer landed in the popover
        await m._drainForTesting()
        #expect(m.isOpen)
    }

    @Test("openImmediately opens without waiting")
    func openImmediatelyOpens() {
        let m = HoverMenuModel()
        m.openImmediately()
        #expect(m.isOpen)
    }

    @Test("closeNow closes")
    func closeNowCloses() {
        let m = HoverMenuModel()
        m.openImmediately()
        m.closeNow()
        #expect(!m.isOpen)
    }

    // MARK: isTriggerHovered

    @Test("triggerHover toggles isTriggerHovered")
    func triggerHoverTogglesIsTriggerHovered() {
        let m = HoverMenuModel()
        m.triggerHover(true)
        #expect(m.isTriggerHovered)
        m.triggerHover(false)
        #expect(!m.isTriggerHovered)
    }

    @Test("closeNow clears isTriggerHovered")
    func closeNowClearsIsTriggerHovered() {
        let m = HoverMenuModel()
        m.openImmediately()
        m.triggerHover(true)
        m.closeNow()
        #expect(!m.isTriggerHovered)
    }

    // MARK: app deactivation (Cmd-Tab away with the menu up)

    /// Deliver a notification and let the observer's `queue: .main` hop run.
    /// Yielding is a no-op when NotificationCenter delivers synchronously.
    private func postDeactivation(to center: NotificationCenter) async {
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        for _ in 0..<10 { await Task.yield() }
    }

    @Test("an open menu closes when the app resigns active")
    func deactivationClosesOpenMenu() async {
        let center = NotificationCenter()
        let m = HoverMenuModel(openDelay: .zero, closeGrace: .zero, notificationCenter: center)
        m.openImmediately()
        #expect(m.isOpen)

        await postDeactivation(to: center)
        #expect(!m.isOpen)
    }

    /// The stuck case: the pointer is parked over the panel when the app
    /// deactivates. `.onHover` delivers no exit event, so `overMenu` would stay
    /// true forever and `reconcile()` would never even schedule a close.
    @Test("deactivation closes the menu even with the pointer parked over it")
    func deactivationClosesMenuWithPointerParkedOverIt() async {
        let center = NotificationCenter()
        let m = HoverMenuModel(openDelay: .zero, closeGrace: .zero, notificationCenter: center)
        m.openImmediately()
        m.menuHover(true)   // pointer sitting on the panel — no exit event will come
        await m._drainForTesting()
        #expect(m.isOpen)

        await postDeactivation(to: center)
        #expect(!m.isOpen)

        // Hover state must be cleared too, or the next reconcile would resurrect
        // the menu from the stale flags rather than from a real hover.
        #expect(!m.isTriggerHovered)
        m.menuHover(false)
        await m._drainForTesting()
        #expect(!m.isOpen)
        #expect(!m.isTriggerHovered)
    }

    @Test("deactivation posted to a different center does not close the menu")
    func deactivationOnForeignCenterIsIgnored() async {
        let center = NotificationCenter()
        let other = NotificationCenter()
        let m = HoverMenuModel(openDelay: .zero, closeGrace: .zero, notificationCenter: center)
        m.openImmediately()
        m.menuHover(true)

        await postDeactivation(to: other)
        #expect(m.isOpen)
    }
}
