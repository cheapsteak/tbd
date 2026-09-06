import AppKit

/// What the composer does with one resolved key command.
///
/// Pure, and the **only** decision site. The existing `ComposerReturnKey`
/// answers the same question for the two first-message sheets and stays exactly
/// as it is; this extends the shape with the one input those sheets do not have —
/// whether a completion menu is open — because a second decision site is how a
/// composer ends up with a key that means one thing in one branch and another
/// somewhere else.
///
/// The four inputs are exactly what `doCommandBy` can know: the command AppKit
/// resolved the keystroke to, the modifiers on the current event, and whether an
/// input method is mid-composition.
///
/// `menuOpen` is a **parameter**, never state held here. The caller reads its
/// controller at decision time, so a stale flag — a menu that closed between the
/// keystroke and the decision — is impossible by construction rather than by
/// discipline.
enum ComposerKeyRouter {
    enum Action: Equatable {
        /// Send the message.
        case submit
        /// Insert a line break and keep composing.
        case newline
        /// Move the completion selection.
        case menuUp
        case menuDown
        /// Accept the highlighted row, or the first when none is highlighted.
        case menuAccept
        /// Close the menu, leaving the text untouched.
        case menuClose
        /// Give up first responder — Escape with no menu open, which returns
        /// focus to the transcript.
        case blur
        /// Not ours. Let AppKit do whatever it would have done.
        case passThrough
    }

    static func action(
        selector: Selector,
        shiftHeld: Bool,
        commandHeld: Bool,
        controlHeld: Bool,
        hasMarkedText: Bool,
        menuOpen: Bool
    ) -> Action {
        // Unconditional, before anything else. While an input method has marked
        // text, every key belongs to the composition — including Return, which
        // commits it, and the arrows, which move through candidates.
        guard !hasMarkedText else { return .passThrough }

        // Cmd+Return always sends, menu open or closed: the escape hatch for a
        // person who highlighted a row and then decided they meant their own
        // words.
        if commandHeld, selector == #selector(NSResponder.insertNewline(_:)) {
            return .submit
        }

        if selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            // Option+Return: a line break, whatever else is on screen.
            return .newline
        }

        if selector == #selector(NSResponder.insertNewline(_:)) {
            // Shift+Return keeps meaning "not now, I am still writing" even with
            // the menu up. `StandardKeyBinding.dict` has no Shift+Return entry,
            // so the modifier is the only thing separating it from a plain
            // Return.
            if shiftHeld { return .newline }
            return menuOpen ? .menuAccept : .submit
        }

        guard menuOpen else {
            // With no menu, Escape gives up first responder and everything else
            // is AppKit's business. Tab must insert a tab, and the arrows must
            // move the caret — a composer that stole them would break multi-line
            // editing for a person who is only typing.
            if selector == #selector(NSResponder.cancelOperation(_:)) { return .blur }
            return .passThrough
        }

        // `controlHeld` is not read to DISTINGUISH anything here: AppKit resolves
        // Ctrl+N and Ctrl+P to the same `moveDown:` / `moveUp:` commands as the
        // arrows, so both gestures arrive already unified. It stays in the
        // signature because the router's contract is "everything doCommandBy can
        // know", and a future binding that needs it must not change every call
        // site.
        _ = controlHeld
        switch selector {
        case #selector(NSResponder.moveUp(_:)): return .menuUp
        case #selector(NSResponder.moveDown(_:)): return .menuDown
        case #selector(NSResponder.insertTab(_:)): return .menuAccept
        case #selector(NSResponder.cancelOperation(_:)): return .menuClose
        default: return .passThrough
        }
    }
}
