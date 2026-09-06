import AppKit
import Foundation
import Testing
@testable import TBDApp

/// Every key the composer sees, decided in one pure function.
///
/// The property that matters most is the **closed-menu** one: with no menu up,
/// Tab, Up, Down and Escape must mean exactly what they mean in any text box.
/// A router that returned a menu action there would steal keys from a person who
/// is only typing, and it would do it invisibly.
///
/// `menuOpen` is a parameter rather than state because the caller reads the
/// controller at decision time — a stale flag is then impossible by construction.
@MainActor
@Suite("ComposerKeyRouter")
struct ComposerKeyRouterTests {
    private let newline = #selector(NSResponder.insertNewline(_:))
    private let optionNewline = #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
    private let tab = #selector(NSResponder.insertTab(_:))
    private let up = #selector(NSResponder.moveUp(_:))
    private let down = #selector(NSResponder.moveDown(_:))
    private let cancel = #selector(NSResponder.cancelOperation(_:))

    private func act(
        _ selector: Selector, shift: Bool = false, command: Bool = false,
        control: Bool = false, marked: Bool = false, menuOpen: Bool = false
    ) -> ComposerKeyRouter.Action {
        ComposerKeyRouter.action(
            selector: selector, shiftHeld: shift, commandHeld: command,
            controlHeld: control, hasMarkedText: marked, menuOpen: menuOpen)
    }

    // MARK: - Menu closed

    /// **The load-bearing negative.** With the menu closed, no key may resolve to
    /// a menu action.
    @Test func withTheMenuClosedNothingIsAMenuAction() {
        for selector in [newline, optionNewline, tab, up, down, cancel] {
            for shift in [false, true] {
                let action = act(selector, shift: shift, menuOpen: false)
                #expect(
                    ![.menuUp, .menuDown, .menuAccept, .menuClose].contains(action),
                    "\(selector) shift=\(shift) resolved to \(action) with no menu open")
            }
        }
    }

    @Test func returnSendsAndShiftBreaksTheLine() {
        #expect(act(newline) == .submit)
        #expect(act(newline, shift: true) == .newline)
        #expect(act(optionNewline) == .newline)
    }

    /// Cmd+Return always sends, menu open or closed — the escape hatch when a
    /// row is highlighted and the person meant the text they typed.
    @Test func commandReturnAlwaysSends() {
        #expect(act(newline, command: true) == .submit)
        #expect(act(newline, command: true, menuOpen: true) == .submit)
        #expect(act(newline, shift: true, command: true, menuOpen: true) == .submit)
    }

    @Test func escapeBlursWhenNoMenuIsOpen() {
        #expect(act(cancel) == .blur)
    }

    @Test func tabAndArrowsPassThroughWhenNoMenuIsOpen() {
        #expect(act(tab) == .passThrough)
        #expect(act(up) == .passThrough)
        #expect(act(down) == .passThrough)
    }

    // MARK: - Menu open

    @Test func theMenuOwnsItsKeys() {
        #expect(act(tab, menuOpen: true) == .menuAccept)
        #expect(act(up, menuOpen: true) == .menuUp)
        #expect(act(down, menuOpen: true) == .menuDown)
        #expect(act(cancel, menuOpen: true) == .menuClose)
        #expect(act(newline, menuOpen: true) == .menuAccept)
    }

    /// Shift+Return keeps breaking the line even with the menu up: it is the one
    /// gesture whose whole meaning is "not now, I am still writing".
    @Test func shiftReturnStillBreaksTheLineWithTheMenuOpen() {
        #expect(act(newline, shift: true, menuOpen: true) == .newline)
        #expect(act(optionNewline, menuOpen: true) == .newline)
    }

    /// Ctrl+N and Ctrl+P move the selection, the emacs bindings AppKit resolves
    /// to the same move commands.
    @Test func controlNAndPMoveTheSelection() {
        #expect(act(down, control: true, menuOpen: true) == .menuDown)
        #expect(act(up, control: true, menuOpen: true) == .menuUp)
    }

    // MARK: - IME

    /// **Marked text passes through unconditionally**, menu open or closed. While
    /// a Japanese or Chinese candidate window is up, Return commits the
    /// composition; sending there would submit a half-typed sentence AND swallow
    /// the commit.
    @Test func markedTextPassesThroughEverything() {
        for selector in [newline, optionNewline, tab, up, down, cancel] {
            for menuOpen in [false, true] {
                #expect(
                    act(selector, marked: true, menuOpen: menuOpen) == .passThrough,
                    "\(selector) menuOpen=\(menuOpen) must pass through during composition")
            }
        }
    }
}
