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

    @Test("popover binding set to false routes through closeNow")
    func bindingDismissCloses() {
        let m = HoverMenuModel()
        m.openImmediately()
        #expect(m.isOpenBinding.wrappedValue == true)
        m.isOpenBinding.wrappedValue = false
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
}
