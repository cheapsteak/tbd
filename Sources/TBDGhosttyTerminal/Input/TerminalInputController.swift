// Adapted from tkzmux c961533 Sources/TkzTerminalView/TerminalInputController.swift (MIT, see LICENSE-tkzmux.txt).
// TerminalInputController — NSEvent → `KeyPress` → bytes on `onSend`.
//
// The view owns one. It owns the keyboard and IME, and forwards every mouse and scroll event to
// the view's `MouseController` without interpreting it.
//
// ## What lives here and what deliberately does not
//
// Nothing here encodes anything. The controller builds a `KeyPress` — plain data, no AppKit — and
// hands it to `GhosttyTerminal.encodeKey(_:optionAsAlt:)`, which is where the libghostty call
// happens, under the terminal's lock. That keeps the whole `NSEvent` → `KeyPress` translation —
// the part that is actually subtle — testable with a synthesized `NSEvent`.
//
// Key bytes come *back* from the terminal and go out on the view's `onSend`. So does pasted and
// IME-inserted text: `ghostty_terminal_paste` writes it through the terminal's pty sink, and
// `GhosttyTerminal.pasteText` takes it back out under the same lock and returns it.
//
// The one exception is `encodeFocus`, which calls `ghostty_focus_encode` (`focus.h`). That function
// is pure: it takes an enum and a buffer, touches no terminal and needs no lock.
//
// ## The option-as-alt trap
//
// libghostty computes `effectiveMods = mods − consumedMods` whenever `text` is non-empty. Building
// the press the obvious way — take `event.characters` (`∫`) and report Option as consumed — encodes
// `∫` even with `MACOS_OPTION_AS_ALT` set. When Option acts as Alt the key must be translated
// *without* Option, so `text` is `"b"` and Option stays **unconsumed**; the encoder then sees `alt`
// in the effective mods and emits `ESC b`.
//
// That is what `translationEvent(for:optionAsAlt:)` is for, and it also has to be the event the
// *input context* sees: AppKit would otherwise commit `∫` through `insertText` before we ever get to
// build a press. Ghostty solves the same problem with `ghostty_surface_key_translation_mods`, an
// apprt API libghostty-vt does not export — `KeyEncoder.translationModifiers(for:optionAsAlt:)`
// reimplements it.

import AppKit
import Foundation
import GhosttyVt
import IOKit.hidsystem

// MARK: - Keyboard layout

/// What the keyboard layout types for a key.
///
/// Every layout-dependent reading the controller makes goes through this, so the tests can fake a
/// layout and give the same answers on a machine set to German or AZERTY as on one set to US.
struct KeyboardLayout: Sendable {
    /// The characters `event`'s key types with `modifiers` held, as
    /// `NSEvent.characters(byApplyingModifiers:)` gives them.
    var characters: @MainActor @Sendable (NSEvent, NSEvent.ModifierFlags) -> String?

    /// The layout the user has selected.
    static let system = KeyboardLayout { event, modifiers in event.characters(byApplyingModifiers: modifiers) }
}

// MARK: - TerminalInputController

@MainActor
final class TerminalInputController {
    /// The view this controller types into. Weak: the view owns the controller.
    weak var view: GhosttyTerminalView?

    /// The preedit string changed. The view draws the preedit itself, from its `NSTextInputClient`
    /// methods; this hook is for anything else that wants to know.
    var onPreeditChange: (@MainActor (String) -> Void)?

    /// Hands a key event to the input method, which may call the view's `NSTextInputClient`
    /// methods (`setMarkedText`, `insertText`, `doCommand`) before it returns. In the app this is
    /// the view's own input context. No input method runs in a test process, so the tests replace
    /// it with one that makes those calls the way a dead key or an IME does.
    var inputMethod: @MainActor (NSEvent, GhosttyTerminalView) -> Void = { event, view in
        _ = view.inputContext?.handleEvent(event)
    }

    /// How the Option key behaves. `.both` by default, as in SwiftTerm, which the app's terminals
    /// have always used: Option-b sends `ESC b` and Option-Backspace deletes a word. `.never` types
    /// the layout's character instead, and is the only setting under which dead keys work
    /// (Option+u, u → `ü`). The view's `optionAsMeta` drives it.
    var optionAsAlt: OptionAsAlt = .both

    /// The keyboard layout keys are read through. A test seam; the app uses the system's.
    var layout: KeyboardLayout = .system

    // MARK: State

    /// The IME's marked (preedit) text, or `""`.
    private(set) var preedit: String = ""

    /// The IME's selection inside `preedit`.
    private(set) var preeditSelectedRange = NSRange(location: NSNotFound, length: 0)

    /// Non-nil only while a `keyDown` is being interpreted. `insertText` appends to it instead of
    /// pasting, which is how a committed IME composition becomes a key press rather than a paste.
    var keyTextAccumulator: [String]?

    init() {}

    /// True while an input method is composing.
    var hasMarkedText: Bool { !preedit.isEmpty }

    // MARK: - Routing

    /// Handles one key, modifier, mouse or scroll event. Returns true when it was consumed.
    func handle(_ event: NSEvent) -> Bool {
        guard let view else { return false }
        switch event.type {
        case .keyDown:
            return handleKeyDown(event, in: view)
        case .keyUp:
            return handleKeyUp(event)
        case .flagsChanged:
            return handleFlagsChanged(event)
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged,
             .mouseMoved, .mouseEntered, .mouseExited, .scrollWheel:
            return view.mouseController.handle(event)
        default:
            return false
        }
    }

    /// Focus changed. This is the DEC 1004 (focus reporting) hook: a program that sets mode 1004
    /// gets `CSI I` and `CSI O`. The mouse controller also drops any held buttons on focus loss.
    func focusDidChange(_ isFocused: Bool) {
        guard let view else { return }
        view.mouseController.focusDidChange(isFocused)
        guard view.terminal.withLocked({ $0.mode(1004) }) else { return }
        view.send(Self.encodeFocus(gained: isFocused))
    }

    // MARK: - Key down

    /// Whether this controller should consume a `.keyDown`.
    ///
    /// `performKeyEquivalent` and `keyDown` deliver the *same* `NSEvent`, so this rule has to be
    /// path-independent — there is no way to tell which one we are on:
    ///
    /// * ⌘ held → decline, so menu items and app shortcuts (⌘P) work. The view then calls `super`,
    ///   which lets AppKit continue up the responder chain.
    /// * we are not the window's first responder → decline. `performKeyEquivalent` is offered to
    ///   the *whole* view hierarchy, not just the focused view, so without this a background
    ///   terminal would swallow keys meant for a text field.
    /// * otherwise handle it and return true. On the `performKeyEquivalent` path that suppresses
    ///   the subsequent `keyDown`, so a Ctrl combination is processed exactly once either way.
    func acceptsKeyDown(_ event: NSEvent, in view: GhosttyTerminalView) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.modifierFlags.contains(.command) { return false }
        if let window = view.window, window.firstResponder !== view { return false }
        return true
    }

    private func handleKeyDown(_ event: NSEvent, in view: GhosttyTerminalView) -> Bool {
        guard acceptsKeyDown(event, in: view) else { return false }

        // Solid cursor while typing.
        view.resetCursorBlink()

        // The IME sees the event *first*, and it sees the option-as-alt translated one — see the
        // file header. `handleEvent` may call back into `insertText` / `setMarkedText` / `doCommand`
        // synchronously, which is why the accumulator is installed around it.
        let translation = Self.translationEvent(for: event, optionAsAlt: optionAsAlt, layout: layout)
        let action: KeyPress.Action = event.isARepeat ? .repeated : .press
        let markedBefore = hasMarkedText

        keyTextAccumulator = []
        inputMethod(translation, view)
        let accumulated = keyTextAccumulator ?? []
        keyTextAccumulator = nil

        // Composing if there is preedit now (the obvious case) *or* if there was preedit before:
        // that key probably only cancelled the composition (Japanese + backspace) and must not
        // reach the pty.
        let composing = hasMarkedText || markedBefore

        if !accumulated.isEmpty {
            // The IME committed text. Send it as key presses so programs see typed input, never a
            // paste — one press per committed string, `composing` false because the composition is
            // finished, whatever the preedit state is now.
            for text in accumulated where !Self.isBareControl(text, composing: composing) {
                send(Self.keyPress(
                    event: event, translationEvent: translation, action: action,
                    optionAsAlt: optionAsAlt, text: text, composing: false, layout: layout))
            }
            return true
        }

        // A bare control character arriving mid-composition belongs to the IME, not the terminal.
        if Self.isBareControl(event.characters, composing: composing) { return true }

        send(Self.keyPress(
            event: event, translationEvent: translation, action: action,
            optionAsAlt: optionAsAlt, text: Self.filteredText(of: translation, layout: layout),
            composing: composing, layout: layout))
        return true
    }

    // MARK: - Key up / modifiers

    /// A release. Releases need the kitty `REPORT_EVENTS` flag (2), so most programs get nothing.
    /// Wired anyway for TUIs that do ask for them.
    private func handleKeyUp(_ event: NSEvent) -> Bool {
        guard !hasMarkedText else { return true }
        send(Self.keyPress(
            event: event, translationEvent: event, action: .release,
            optionAsAlt: optionAsAlt, text: "", composing: false, layout: layout))
        return true
    }

    /// `flagsChanged` carries no action bit: the modifier's own keycode says *which* modifier, and
    /// whether that modifier's bit is still set in the flags says press or release.
    ///
    /// The subtlety is sides. Holding both Shifts and letting one go still leaves `.shift` set, so
    /// a naive reading reports a second press. The device masks disambiguate: for a right-hand
    /// keycode, it is only a press if that side's raw bit is set.
    private func handleFlagsChanged(_ event: NSEvent) -> Bool {
        guard !hasMarkedText else { return true }

        let bit: KeyModifiers
        switch event.keyCode {
        case 0x39: bit = .capsLock                 // kVK_CapsLock
        case 0x38, 0x3C: bit = .shift              // kVK_Shift / kVK_RightShift
        case 0x3B, 0x3E: bit = .control            // kVK_Control / kVK_RightControl
        case 0x3A, 0x3D: bit = .alt                // kVK_Option / kVK_RightOption
        case 0x37, 0x36: bit = .super_             // kVK_Command / kVK_RightCommand
        default: return false                      // Fn and friends: nothing to encode.
        }

        let mods = Self.modifiers(from: event.modifierFlags)
        var action: KeyPress.Action = .release
        if !mods.isDisjoint(with: bit) {
            let raw = event.modifierFlags.rawValue
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C: sidePressed = raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: sidePressed = raw & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: sidePressed = raw & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: sidePressed = raw & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: sidePressed = true
            }
            if sidePressed { action = .press }
        }

        send(KeyPress(
            action: action,
            key: MacKeyCodes.key(forVirtualKeyCode: event.keyCode),
            mods: mods,
            consumedMods: [],
            text: "",
            unshiftedCodepoint: 0,
            composing: false))
        return true
    }

    // MARK: - Text input callbacks (driven by GhosttyTerminalView+TextInput)

    /// `insertText` from the input context.
    ///
    /// Inside a `keyDown` this only accumulates: the caller turns it into key presses so the pty
    /// sees typed input. Outside one — emoji picker, dictation, drag & drop — there is no key to
    /// attach it to, so it is pasted with `source: .text`.
    func insertFromInputContext(_ text: String) {
        setPreedit("", selectedRange: NSRange(location: NSNotFound, length: 0))
        guard !text.isEmpty else { return }
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
            return
        }
        // `source: .text` is what makes this an insert rather than a paste: libghostty never turns
        // it into a bracketed-paste or Kitty paste event. `allowUnsafe` is true because the user
        // produced this text here and now — the safety prompt exists for the *clipboard*, whose
        // contents came from somewhere else.
        guard let view else { return }
        view.send(view.terminal.pasteText(text, source: .text, allowUnsafe: true).bytes)
    }

    // MARK: - Clipboard image chord

    /// ⌘V with an image and no text on the pasteboard.
    ///
    /// A program running in the terminal cannot read the pasteboard through the pty, so the ones
    /// that want an image (Claude Code) read the system clipboard *themselves* when they see a
    /// Ctrl-V keystroke. `MouseController.pasteFromPasteboard` calls this when there is nothing to
    /// paste as text, and the chord is encoded exactly like a physical Ctrl-V — through the key
    /// encoder, so the bytes are `0x16` in legacy mode and `CSI 118;5u` under the kitty protocol —
    /// rather than a hard-coded control byte. The image itself never passes through the terminal.
    ///
    /// Press then release: the release encodes to nothing in legacy mode and to a proper event
    /// under kitty `REPORT_EVENTS`. Returns true when the press produced bytes.
    @discardableResult
    func sendClipboardImageChord() -> Bool {
        let wrote = send(Self.clipboardImageChord(.press))
        _ = send(Self.clipboardImageChord(.release))
        return wrote
    }

    /// Ctrl-V as the view layer would deliver a real one: `text` empty because control-character
    /// encoding is libghostty's job from `key` + `mods` (see `KeyPress.text`).
    static func clipboardImageChord(_ action: KeyPress.Action) -> KeyPress {
        KeyPress(
            action: action,
            key: GHOSTTY_KEY_V,
            mods: .control,
            consumedMods: [],
            text: "",
            unshiftedCodepoint: UInt32(UnicodeScalar("v").value),
            composing: false)
    }

    func setPreedit(_ text: String, selectedRange: NSRange) {
        guard preedit != text || preeditSelectedRange != selectedRange else { return }
        preedit = text
        preeditSelectedRange = selectedRange
        onPreeditChange?(text)
    }

    // MARK: - NSEvent → KeyPress

    /// Build the `KeyPress` for one event, exactly as `KeyEncoder`'s field documentation requires.
    ///
    /// Pure and static so the whole translation tests against a synthesized `NSEvent`.
    ///
    /// - Parameters:
    ///   - event: the real event — the source of `mods`, `keyCode` and `unshiftedCodepoint`.
    ///   - translationEvent: the event macOS translated the text with (see the file header). Pass
    ///     nil to derive it.
    ///   - text: the text to send, already filtered. Pass nil to take it from `translationEvent`.
    ///   - layout: the keyboard layout to read the key through.
    static func keyPress(
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        action: KeyPress.Action,
        optionAsAlt: OptionAsAlt,
        text: String? = nil,
        composing: Bool = false,
        layout: KeyboardLayout = .system
    ) -> KeyPress {
        let mods = modifiers(from: event.modifierFlags)
        let translation = translationEvent
            ?? Self.translationEvent(for: event, optionAsAlt: optionAsAlt, layout: layout)

        // macOS has no API for "which modifiers were spent producing this text", so this is
        // Ghostty's long-standing heuristic: Control and Command never contribute, everything else
        // did — applied to the *translation* mods, which is what makes Option survive as Alt.
        let consumed = KeyEncoder
            .translationModifiers(for: mods, optionAsAlt: optionAsAlt)
            .subtracting([.control, .super_])

        var unshifted: UInt32 = 0
        if event.type == .keyDown || event.type == .keyUp,
           let scalar = layout.characters(event, [])?.unicodeScalars.first {
            unshifted = scalar.value
        }

        return KeyPress(
            action: action,
            key: MacKeyCodes.key(forVirtualKeyCode: event.keyCode),
            mods: mods,
            consumedMods: consumed,
            text: text ?? filteredText(of: translation, layout: layout),
            unshiftedCodepoint: unshifted,
            composing: composing)
    }

    /// The event macOS should translate the key with, given the option-as-alt setting.
    ///
    /// Returns `event` itself when nothing changes. That identity matters: AppKit's Korean input
    /// method behaves differently when handed a reconstructed event, so a copy is only made when
    /// the flags genuinely differ.
    ///
    /// Only the four device-independent bits are toggled, on top of the *original* raw flags — the
    /// low bits carry device sides and dead-key state that AppKit needs to keep composing.
    static func translationEvent(
        for event: NSEvent, optionAsAlt: OptionAsAlt, layout: KeyboardLayout = .system
    ) -> NSEvent {
        let mods = modifiers(from: event.modifierFlags)
        let translation = KeyEncoder.translationModifiers(for: mods, optionAsAlt: optionAsAlt)

        var flags = event.modifierFlags
        set(&flags, .shift, translation.contains(.shift))
        set(&flags, .control, translation.contains(.control))
        set(&flags, .option, translation.contains(.alt))
        set(&flags, .command, translation.contains(.super_))
        guard flags != event.modifierFlags else { return event }

        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: flags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: layout.characters(event, flags) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode) ?? event
    }

    private static func set(_ flags: inout NSEvent.ModifierFlags, _ flag: NSEvent.ModifierFlags, _ on: Bool) {
        if on { flags.insert(flag) } else { flags.remove(flag) }
    }

    /// `NSEvent.modifierFlags` → `KeyModifiers`, **including the side bits**.
    ///
    /// `NSEvent.ModifierFlags` only has device-independent bits (`deviceIndependentFlagsMask` is
    /// `0xFFFF0000`); the side lives in the low half of the raw value, under the IOKit device masks
    /// from `IOKit/hidsystem/IOLLEvent.h`. A side bit is only meaningful when its modifier is set,
    /// and its absence means "left" — libghostty cannot represent "both sides".
    static func modifiers(from flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var mods: KeyModifiers = []
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.alt) }
        if flags.contains(.command) { mods.insert(.super_) }
        if flags.contains(.capsLock) { mods.insert(.capsLock) }

        let raw = flags.rawValue
        if mods.contains(.shift), raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods.insert(.shiftRight) }
        if mods.contains(.control), raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods.insert(.controlRight) }
        if mods.contains(.alt), raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods.insert(.altRight) }
        if mods.contains(.super_), raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods.insert(.superRight) }
        return mods
    }

    /// The text for a key event, filtered to what `ghostty_key_event_set_utf8` accepts.
    ///
    /// A single control character is re-read *without* Control, because control-character encoding
    /// (Ctrl-A → 0x01) is libghostty's job, derived from `key` + `mods`. Function keys arrive as
    /// macOS PUA codepoints and must never reach the terminal. Shift+Tab is the live case: AppKit
    /// reports U+0019, the re-read gives U+0009, and both are C0 — so the answer is `""` and the
    /// encoder produces `ESC[Z` / `ESC[9;2u` from the key alone.
    static func filteredText(of event: NSEvent, layout: KeyboardLayout = .system) -> String {
        guard let characters = event.characters else { return "" }
        guard characters.unicodeScalars.count == 1, let scalar = characters.unicodeScalars.first else {
            return characters
        }
        if (0xF700...0xF8FF).contains(scalar.value) { return "" }
        if scalar.value < 0x20 {
            let relaxed = layout.characters(event, event.modifierFlags.subtracting(.control))
            return sanitize(relaxed ?? "")
        }
        return sanitize(characters)
    }

    static func sanitize(_ text: String) -> String {
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else { return text }
        if scalar.value < 0x20 || scalar.value == 0x7F { return "" }
        if (0xF700...0xF8FF).contains(scalar.value) { return "" }
        return text
    }

    /// A lone control character produced while an IME is composing — Ctrl-H inside a Japanese
    /// composition cancels the preedit and must not also delete the text before it.
    static func isBareControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text, text.unicodeScalars.count == 1,
              let scalar = text.unicodeScalars.first else { return false }
        return scalar.value < 0x20 || scalar.value == 0x7F
    }

    // MARK: - Focus reporting

    /// `ghostty_focus_encode` (`focus.h`): `CSI I` gained, `CSI O` lost. Only sent when DEC mode
    /// 1004 is set — the caller checks, this only encodes.
    static func encodeFocus(gained: Bool) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 16)
        var written = 0
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            ghostty_focus_encode(
                gained ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST,
                pointer.baseAddress, pointer.count, &written)
        }
        guard result == GHOSTTY_SUCCESS, written > 0, written <= buffer.count else { return [] }
        return Array(buffer[0..<written])
    }

    // MARK: - Output

    /// Encode one press and send it on the view's `onSend`.
    ///
    /// Returns true when bytes were sent. An empty encoding (a release in legacy mode, a bare
    /// modifier) is normal and returns false.
    @discardableResult
    private func send(_ press: KeyPress) -> Bool {
        guard let view else { return false }
        let bytes = view.terminal.encodeKey(press, optionAsAlt: optionAsAlt)
        guard !bytes.isEmpty else { return false }
        view.send(bytes)
        return true
    }
}
