// Adapted from tkzmux c961533 Sources/TkzTerminalView/TerminalInputController.swift (MIT, see third_party/tkzmux). PORT comments mark vt-1.0.0 changes.
// TerminalInputController — NSEvent → `KeyPress` → pty bytes (M1.7).
// See docs/keys.md.
//
// This is the single `TerminalViewInputDelegate`: it owns the keyboard and IME, and forwards every
// mouse/scroll event to a `TerminalMouseHandling` without interpreting it.
//
// ## What lives here and what deliberately does not
//
// Nothing here encodes anything. The controller builds a `KeyPress` — plain data, no AppKit — and
// hands it to `TerminalSession.encodeKey(_:optionAsAlt:)` on the view's visible session, which is
// where the libghostty call happens, under the session lock. (The `encodeKey` property overrides
// that for tests and for a host with no `TerminalSession`.) That keeps every C call inside the
// allowed files, and makes the whole `NSEvent` → `KeyPress` translation — the part that
// is actually subtle — unit-testable with a synthesized `NSEvent` and no window, no pty and no
// terminal.
//
// Key bytes come *back* from the session and go out through `writeInput`. Pasted and IME-inserted
// text is the opposite: `ghostty_terminal_paste` writes it through the session's own pty sink, so
// this file must never also write it — that would send every paste twice.
//
// The one exception is `encodeFocus`, which calls `ghostty_focus_encode` (`focus.h`). That function
// is pure: it takes an enum and a buffer, touches no terminal and needs no lock, so keeping it here
// costs nothing and avoids a seam through Core for two bytes.
//
// ## The option-as-alt trap (verified M1.7)
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
import os

// MARK: - Mouse seam

/// The seam the `MouseController` implements.
///
/// `TerminalInputController` is the only `TerminalViewInputDelegate`; every mouse and scroll event
/// the view forwards is routed here unchanged, with the view it came from.
@MainActor public protocol TerminalMouseHandling: AnyObject {
    /// Returns true if the event was consumed.
    func handle(_ event: NSEvent, in view: TerminalMetalView) -> Bool

    /// Focus changed. `TerminalInputController` is the *only* `TerminalViewInputDelegate`, so this
    /// is the mouse handler's only route to a focus change — a handler that tracks held buttons has
    /// to drop them when the window loses focus, or the next drag reports a phantom button.
    /// Defaulted to a no-op so a handler that does not care need not implement it.
    func focusDidChange(_ isFocused: Bool, in view: TerminalMetalView?)
}

extension TerminalMouseHandling {
    public func focusDidChange(_ isFocused: Bool, in view: TerminalMetalView?) {}
}

// MARK: - TerminalInputController

@MainActor
public final class TerminalInputController: TerminalViewInputDelegate {
    // MARK: Seams

    /// Override for how a key press becomes bytes.
    ///
    /// **Normally nil, and nil is now the working case**: with no override the controller calls
    /// `TerminalSession.encodeKey(_:optionAsAlt:)` on the view's own visible session, which runs
    /// `KeyEncoder` under the session lock against the live terminal — the seam that did not exist
    /// while the keyboard controller was written. The closure stays as a test hook (and as the seam a host with no
    /// `TerminalSession` would fill in); it is never a text pass-through fallback, because Enter,
    /// the cursor keys and every Ctrl combination would be silently wrong.
    public var encodeKey: (@MainActor (KeyPress) throws -> [UInt8])?

    /// Where encoded bytes go. `DevWindowController.writeInput` does the `ioQueue` hop, so this is
    /// safe to call from the main actor and `Pty.write` is never called from main.
    public var writeInput: (@MainActor (Data) -> Void)?

    /// Override for text that arrived outside a `keyDown` — the emoji picker, dictation, a drag &
    /// drop. With no override the controller calls `TerminalSession.pasteText(_:source:allowUnsafe:)`
    /// with `source: .text`, which is `ghostty_terminal_paste(source: TEXT)`: never a bracketed
    /// paste event, and the bytes leave through the session's **own** pty sink, so nothing here
    /// writes them a second time.
    public var insertPastedText: (@MainActor (String) -> Void)?

    /// Whether the visible terminal has DEC mode 1004 (focus reporting) set —
    /// `session.mode(1004)`. Focus reports are only sent when it does; the recorded `claude-boot`
    /// fixture shows Claude Code sets it.
    public var isFocusReportingEnabled: (@MainActor () -> Bool)?

    /// The preedit string changed. The renderer has no preedit overlay yet (required delta, see the
    /// final report), so this is the hook the overlay will hang off.
    public var onPreeditChange: (@MainActor (String) -> Void)?

    /// the `MouseController`. Weak: the app owns it, exactly as it owns this controller.
    public weak var mouseHandler: (any TerminalMouseHandling)?

    /// How the Option key behaves. `.never` is the macOS-native default and the only setting under
    /// which dead keys work (Option+u, u → `ü`); config will drive it later.
    public var optionAsAlt: OptionAsAlt = .never

    // MARK: State

    /// The IME's marked (preedit) text, or `""`.
    public private(set) var preedit: String = ""

    /// The IME's selection inside `preedit`.
    public private(set) var preeditSelectedRange = NSRange(location: NSNotFound, length: 0)

    /// Non-nil only while a `keyDown` is being interpreted. `insertText` appends to it instead of
    /// pasting, which is how a committed IME composition becomes a key press rather than a paste.
    var keyTextAccumulator: [String]?

    /// The view the last event came from. `insertText` from the input context (dictation, the
    /// emoji picker) arrives with no view of its own, so this is how that text finds a session.
    /// Weak because the app owns the view; a stale one simply makes the insert inert.
    private weak var lastView: TerminalMetalView?

    private let logger = Logger(subsystem: "ghosttyview", category: "input")

    public init() {}

    /// True while an input method is composing.
    public var hasMarkedText: Bool { !preedit.isEmpty }

    // MARK: - TerminalViewInputDelegate

    public func terminalView(_ view: TerminalMetalView, handle event: NSEvent) -> Bool {
        lastView = view
        switch event.type {
        case .keyDown:
            return handleKeyDown(event, in: view)
        case .keyUp:
            return handleKeyUp(event, in: view)
        case .flagsChanged:
            return handleFlagsChanged(event, in: view)
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged,
             .mouseMoved, .mouseEntered, .mouseExited, .scrollWheel:
            return mouseHandler?.handle(event, in: view) ?? false
        default:
            return false
        }
    }

    public func terminalView(_ view: TerminalMetalView, didChangeFocus isFocused: Bool) {
        if isFocused { lastView = view }
        mouseHandler?.focusDidChange(isFocused, in: view)
        guard isFocusReportingEnabled?() ?? false else { return }
        let bytes = Self.encodeFocus(gained: isFocused)
        guard !bytes.isEmpty else { return }
        writeInput?(Data(bytes))
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
    public func acceptsKeyDown(_ event: NSEvent, in view: TerminalMetalView) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.modifierFlags.contains(.command) { return false }
        if let window = view.window, window.firstResponder !== view { return false }
        return true
    }

    private func handleKeyDown(_ event: NSEvent, in view: TerminalMetalView) -> Bool {
        guard acceptsKeyDown(event, in: view) else { return false }

        // Solid cursor while typing.
        view.resetCursorBlink()

        // The IME sees the event *first*, and it sees the option-as-alt translated one — see the
        // file header. `handleEvent` may call back into `insertText` / `setMarkedText` / `doCommand`
        // synchronously, which is why the accumulator is installed around it.
        let translation = Self.translationEvent(for: event, optionAsAlt: optionAsAlt)
        let action: KeyPress.Action = event.isARepeat ? .repeated : .press
        let markedBefore = hasMarkedText

        keyTextAccumulator = []
        _ = view.inputContext?.handleEvent(translation)
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
                    optionAsAlt: optionAsAlt, text: text, composing: false), in: view)
            }
            return true
        }

        // A bare control character arriving mid-composition belongs to the IME, not the terminal.
        if Self.isBareControl(event.characters, composing: composing) { return true }

        send(Self.keyPress(
            event: event, translationEvent: translation, action: action,
            optionAsAlt: optionAsAlt, text: Self.filteredText(of: translation), composing: composing),
            in: view)
        return true
    }

    // MARK: - Key up / modifiers

    /// A release. **Expected to produce zero bytes under Claude Code**: releases need the kitty
    /// `REPORT_EVENTS` flag (2) and `CSI > 5 u` is `DISAMBIGUATE | REPORT_ALTERNATES`. Wired anyway
    /// for TUIs that do ask for them.
    private func handleKeyUp(_ event: NSEvent, in view: TerminalMetalView) -> Bool {
        guard !hasMarkedText else { return true }
        send(Self.keyPress(
            event: event, translationEvent: event, action: .release,
            optionAsAlt: optionAsAlt, text: "", composing: false), in: view)
        return true
    }

    /// `flagsChanged` carries no action bit: the modifier's own keycode says *which* modifier, and
    /// whether that modifier's bit is still set in the flags says press or release.
    ///
    /// The subtlety is sides. Holding both Shifts and letting one go still leaves `.shift` set, so
    /// a naive reading reports a second press. The device masks disambiguate: for a right-hand
    /// keycode, it is only a press if that side's raw bit is set.
    private func handleFlagsChanged(_ event: NSEvent, in view: TerminalMetalView) -> Bool {
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
            composing: false), in: view)
        return true
    }

    // MARK: - Text input callbacks (driven by TerminalMetalView+TextInput)

    /// `insertText` from the input context.
    ///
    /// Inside a `keyDown` this only accumulates: the caller turns it into key presses so the pty
    /// sees typed input. Outside one — emoji picker, dictation, drag & drop — there is no key to
    /// attach it to, so it is pasted with `source: TEXT`.
    func insertFromInputContext(_ text: String) {
        setPreedit("", selectedRange: NSRange(location: NSNotFound, length: 0))
        guard !text.isEmpty else { return }
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
            return
        }
        if let insertPastedText {
            insertPastedText(text)
            return
        }
        // `source: .text` is what makes this an insert rather than a paste: libghostty never turns
        // it into a bracketed-paste or Kitty paste event, and the bytes leave through the session's
        // own pty sink. `allowUnsafe` is true because the user produced this text here and now —
        // the safety prompt exists for the *clipboard*, whose contents came from somewhere else.
        guard let session = lastView?.session else { return }
        do {
            _ = try session.pasteText(text, source: .text, allowUnsafe: true)
        } catch {
            logger.error("text insert failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Clipboard image chord

    /// ⌘V with an image and no text on the pasteboard.
    ///
    /// A program running in the terminal cannot read the pasteboard through the pty, so the ones
    /// that want an image (Claude Code) read the system clipboard *themselves* when they see a
    /// Ctrl-V keystroke. `MouseController.pasteFromPasteboard` calls this through its
    /// `pasteClipboardImage` seam when there is nothing to paste as text, and the chord is
    /// encoded exactly like a physical Ctrl-V — through the session's key encoder, so the bytes
    /// are `0x16` in legacy mode and `CSI 118;5u` under the kitty protocol Claude Code turns on —
    /// rather than a hard-coded control byte. The image itself never passes through tkzmux.
    ///
    /// Press then release: the release encodes to nothing in legacy mode and to a proper event
    /// under kitty `REPORT_EVENTS`. Returns true when the press produced bytes.
    @discardableResult
    public func sendClipboardImageChord(in view: TerminalMetalView) -> Bool {
        lastView = view
        let press = Self.clipboardImageChord(.press)
        let wrote = send(press, in: view)
        _ = send(Self.clipboardImageChord(.release), in: view)
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
    /// Pure and static so the whole translation tests headlessly against a synthesized `NSEvent`.
    ///
    /// - Parameters:
    ///   - event: the real event — the source of `mods`, `keyCode` and `unshiftedCodepoint`.
    ///   - translationEvent: the event macOS translated the text with (see the file header). Pass
    ///     nil to derive it.
    ///   - text: the text to send, already filtered. Pass nil to take it from `translationEvent`.
    public static func keyPress(
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        action: KeyPress.Action,
        optionAsAlt: OptionAsAlt,
        text: String? = nil,
        composing: Bool = false
    ) -> KeyPress {
        let mods = modifiers(from: event.modifierFlags)
        let translation = translationEvent ?? Self.translationEvent(for: event, optionAsAlt: optionAsAlt)

        // macOS has no API for "which modifiers were spent producing this text", so this is
        // Ghostty's long-standing heuristic: Control and Command never contribute, everything else
        // did — applied to the *translation* mods, which is what makes Option survive as Alt.
        let consumed = KeyEncoder
            .translationModifiers(for: mods, optionAsAlt: optionAsAlt)
            .subtracting([.control, .super_])

        var unshifted: UInt32 = 0
        if event.type == .keyDown || event.type == .keyUp,
           let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
            unshifted = scalar.value
        }

        return KeyPress(
            action: action,
            key: MacKeyCodes.key(forVirtualKeyCode: event.keyCode),
            mods: mods,
            consumedMods: consumed,
            text: text ?? filteredText(of: translation),
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
    public static func translationEvent(for event: NSEvent, optionAsAlt: OptionAsAlt) -> NSEvent {
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
            characters: event.characters(byApplyingModifiers: flags) ?? "",
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
    public static func modifiers(from flags: NSEvent.ModifierFlags) -> KeyModifiers {
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
    public static func filteredText(of event: NSEvent) -> String {
        guard let characters = event.characters else { return "" }
        guard characters.unicodeScalars.count == 1, let scalar = characters.unicodeScalars.first else {
            return characters
        }
        if (0xF700...0xF8FF).contains(scalar.value) { return "" }
        if scalar.value < 0x20 {
            let relaxed = event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
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
    public static func encodeFocus(gained: Bool) -> [UInt8] {
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

    /// Encode one press and write it.
    ///
    /// The encoder lives inside `TerminalSession` (it needs the terminal handle *and* the session
    /// lock), so the default path is `view.session`. `encodeKey` overrides it for tests and for a
    /// host that drives something other than a `TerminalSession`.
    ///
    /// Key bytes are **returned** by the session, never written by it — `writeInput` is the only
    /// thing that puts them on the pty. (Paste is the opposite; see `insertPastedText`.)
    ///
    /// Returns true when bytes were written. An empty encoding (a release in legacy mode, a bare
    /// modifier) is normal and returns false without logging.
    @discardableResult
    private func send(_ press: KeyPress, in view: TerminalMetalView) -> Bool {
        do {
            let bytes: [UInt8]
            if let encodeKey {
                bytes = try encodeKey(press)
            } else if let session = view.session {
                bytes = try session.encodeKey(press, optionAsAlt: optionAsAlt)
            } else {
                return false
            }
            guard !bytes.isEmpty else { return false }
            writeInput?(Data(bytes))
            return true
        } catch {
            logger.error("key encode failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
