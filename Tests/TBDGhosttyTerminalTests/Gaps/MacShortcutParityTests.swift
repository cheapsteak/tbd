import AppKit
import Foundation
import Metal
@testable import TBDGhosttyTerminal
import TestSupport
import Testing

/// What a view sent. Main-actor isolated, so a `@MainActor` callback can append to it without
/// capturing a mutable local.
@MainActor
private final class SentBytes {
    var sent: [[UInt8]] = []
}

/// A view that counts the keys that reach it, to show whether the terminal view passed a key on
/// up the responder chain.
@MainActor
private final class KeyCountingView: NSView {
    var keyDowns = 0
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { keyDowns += 1 }
}

/// What a US layout types for the keys these tests press, so the answers do not depend on the
/// layout the machine running them has selected.
private let shortcutLayout = KeyboardLayout { event, modifiers in
    switch event.keyCode {
    case 0x24: return "\r"
    case 0x35: return "\u{1b}"
    case 0x2F: return "."
    case 0x1F: return modifiers.contains(.option) ? "ø" : "o"
    default: return nil
    }
}

/// An 80×24 terminal with a hundred lines of scrollback and no callbacks.
private func makeTerminal() throws -> GhosttyTerminal {
    try GhosttyTerminal(cols: 80, rows: 24, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
}

/// An 80×24 terminal and a view over it, with an input method that does nothing, so every key
/// goes to the key encoder as it does when no composition is running.
@MainActor
private struct ShortcutViewFixture {
    let terminal: GhosttyTerminal
    let view: GhosttyTerminalView
    let recorder: SentBytes

    init() throws {
        let recorder = SentBytes()
        self.recorder = recorder
        terminal = try makeTerminal()
        let appearance = GhosttyAppearance(
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            foreground: .init(r: 0xDD, g: 0xDD, b: 0xDD),
            background: .init(r: 0x10, g: 0x10, b: 0x10),
            cursor: .init(r: 0xFF, g: 0xFF, b: 0xFF))
        view = try GhosttyTerminalView(terminal: terminal, appearance: appearance)
        view.setFrameSize(NSSize(width: 400, height: 200))
        view.inputController.layout = shortcutLayout
        view.inputController.inputMethod = { _, _ in }
        view.onSend = { recorder.sent.append($0) }
    }
}

/// An offscreen window whose content view is `parent`, with `view` inside it and `firstResponder`
/// focused. The window is never on screen; the view counts it as visible. Clear `contentView`
/// when done.
@MainActor
private func mountedWindow(
    holding view: GhosttyTerminalView, in parent: NSView, focusing firstResponder: NSResponder
) throws -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 200),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    parent.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
    window.contentView = parent
    view.windowVisibility = { _ in true }
    parent.addSubview(view)
    try #require(window.makeFirstResponder(firstResponder), "\(firstResponder) would not take focus")
    return window
}

// MARK: - Events

private let leftArrow = "\u{F702}"
private let rightArrow = "\u{F703}"
private let upArrow = "\u{F700}"
private let forwardDelete = "\u{F728}"
private let pageUpKey = "\u{F72C}"
private let pageDownKey = "\u{F72D}"

/// A key-down for no window. `ignoringModifiers` defaults to `characters`.
private func keyDown(
    _ keyCode: UInt16, _ characters: String, ignoringModifiers: String? = nil, flags: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: characters, charactersIgnoringModifiers: ignoringModifiers ?? characters,
        isARepeat: false, keyCode: keyCode))
}

/// The arrows and the keys of the navigation block carry Fn, and the arrows the numeric-pad bit,
/// as AppKit delivers them.
private func arrow(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try keyDown(keyCode, characters, flags: flags.union([.function, .numericPad]))
}

private func cmdLeft() throws -> NSEvent { try arrow(0x7B, leftArrow, .command) }
private func cmdRight() throws -> NSEvent { try arrow(0x7C, rightArrow, .command) }
private func cmdUp() throws -> NSEvent { try arrow(0x7E, upArrow, .command) }
private func cmdBackspace() throws -> NSEvent { try keyDown(0x33, "\u{7F}", flags: .command) }
private func optionBackspace() throws -> NSEvent { try keyDown(0x33, "\u{7F}", flags: .option) }
private func optionForwardDelete() throws -> NSEvent { try keyDown(0x75, forwardDelete, flags: [.option, .function]) }
private func cmdPeriod() throws -> NSEvent { try keyDown(0x2F, ".", flags: .command) }
private func cmdOptionO() throws -> NSEvent { try keyDown(0x1F, "ø", ignoringModifiers: "o", flags: [.command, .option]) }
private func shiftReturn(_ flags: NSEvent.ModifierFlags = .shift) throws -> NSEvent { try keyDown(0x24, "\r", flags: flags) }
private func shiftEscape() throws -> NSEvent { try keyDown(0x35, "\u{1b}", flags: .shift) }

private func pageUp(_ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try keyDown(0x74, pageUpKey, flags: flags.union(.function))
}

private func pageDown(_ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try keyDown(0x79, pageDownKey, flags: flags.union(.function))
}

// MARK: - Reading the terminal

/// Sixty numbered lines, so the primary screen has scrollback to page through.
private let sixtyLines = (0..<60).map { "line \($0)\r\n" }.joined()

/// The first scrollable row the viewport shows.
private func viewportOffset(of terminal: GhosttyTerminal) throws -> Int {
    try terminal.withLocked { state in
        TerminalScrollMetrics.read(try #require(state.raw, "the terminal is closed")).offset
    }
}

/// The bytes `event` encodes to on `terminal`, through the same translation the view runs.
@MainActor
private func encoded(_ event: NSEvent, on terminal: GhosttyTerminal, optionAsAlt: OptionAsAlt = .never) -> [UInt8] {
    let press = TerminalInputController.keyPress(
        event: event, action: .press, optionAsAlt: optionAsAlt, layout: shortcutLayout)
    return terminal.encodeKey(press, optionAsAlt: optionAsAlt)
}

private func describe(_ bytes: [UInt8]?) -> String {
    guard let bytes else { return "nil" }
    return String(decoding: bytes, as: UTF8.self).debugDescription
}

/// The macOS shortcuts the app's SwiftTerm terminals answer with bytes of their own, through
/// `TBDTerminalView`'s natural text editing and SwiftTerm's `keyDown` and `doCommand(by:)`. The
/// libghostty view has to send the same bytes for the same keys, so a terminal behaves the same
/// whichever engine draws it.
@Suite(.fastPassBounded)
@MainActor
struct MacShortcutParityTests {
    // MARK: - Natural text editing

    /// ⌘←, ⌘→ and ⌘⌫ go to Home, End and Ctrl-U; ⌥⌫ and ⌥⌦ to the readline word deletions.
    @Test func naturalTextEditingShortcutsMapToShellLineEditing() throws {
        let cases: [(name: String, event: NSEvent, bytes: [UInt8])] = try [
            ("⌘←", cmdLeft(), [0x1B, 0x5B, 0x48]),
            ("⌘→", cmdRight(), [0x1B, 0x5B, 0x46]),
            ("⌘⌫", cmdBackspace(), [0x15]),
            ("⌥⌫", optionBackspace(), [0x1B, 0x7F]),
            ("⌥⌦", optionForwardDelete(), [0x1B, 0x64]),
        ]
        for shortcut in cases {
            let mapped: [UInt8]? = TerminalInputController.naturalTextEditingBytes(for: shortcut.event)
            let expected: [UInt8]? = shortcut.bytes
            #expect(mapped == expected, "\(shortcut.name) mapped to \(describe(mapped))")
        }
    }

    /// Only the one modifier: Shift, Control, or ⌘ and ⌥ together decline, as in
    /// `TBDTerminalView`, and so do the keys on their own and other ⌘ keys.
    @Test func naturalTextEditingDeclinesOtherModifiersAndKeys() throws {
        let cases: [(name: String, event: NSEvent)] = try [
            ("⇧⌘←", arrow(0x7B, leftArrow, [.command, .shift])),
            ("⌃⌘←", arrow(0x7B, leftArrow, [.command, .control])),
            ("⌥⌘←", arrow(0x7B, leftArrow, [.command, .option])),
            ("⌥⌘⌫", keyDown(0x33, "\u{7F}", flags: [.command, .option])),
            ("⇧⌥⌫", keyDown(0x33, "\u{7F}", flags: [.option, .shift])),
            ("⌃⌥⌫", keyDown(0x33, "\u{7F}", flags: [.option, .control])),
            ("⌘⌦", keyDown(0x75, forwardDelete, flags: [.command, .function])),
            ("⌥←", arrow(0x7B, leftArrow, .option)),
            ("←", arrow(0x7B, leftArrow)),
            ("⌫", keyDown(0x33, "\u{7F}")),
            ("⌘A", keyDown(0x00, "a", flags: .command)),
        ]
        for shortcut in cases {
            let mapped = TerminalInputController.naturalTextEditingBytes(for: shortcut.event)
            #expect(mapped == nil, "\(shortcut.name) mapped to \(describe(mapped))")
        }
    }

    /// AppKit offers ⌘ keys to `performKeyEquivalent` before any menu, and the view takes the
    /// three ⌘ shortcuts there, as `TBDTerminalView` does, so a menu item with the same key does
    /// not win. A ⌘ key that is not one of them goes on to the menus.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func commandEditingShortcutsAreTakenAsKeyEquivalents() throws {
        let fixture = try ShortcutViewFixture()
        let view = fixture.view
        let shortcuts: [(name: String, event: NSEvent, bytes: [UInt8])] = try [
            ("⌘←", cmdLeft(), [0x1B, 0x5B, 0x48]),
            ("⌘→", cmdRight(), [0x1B, 0x5B, 0x46]),
            ("⌘⌫", cmdBackspace(), [0x15]),
        ]
        for shortcut in shortcuts {
            fixture.recorder.sent = []
            let handled = view.performKeyEquivalent(with: shortcut.event)
            #expect(handled, "\(shortcut.name) was left for the menus")
            let sent = fixture.recorder.sent
            #expect(sent == [shortcut.bytes], "\(shortcut.name) sent \(sent)")
        }

        fixture.recorder.sent = []
        let menuKey = view.performKeyEquivalent(with: try cmdUp())
        #expect(!menuKey, "⌘↑ was taken before the menus could see it")
        #expect(fixture.recorder.sent.isEmpty, "⌘↑ as a key equivalent sent \(fixture.recorder.sent)")
    }

    /// ⌥⌫ and ⌥⌦ send the word deletions whether or not Option is Meta, and under Kitty flags too,
    /// where the key encoder would send `CSI 127;3u` and `CSI 3;3~`.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice), arguments: [true, false])
    func optionDeletionsIgnoreOptionAsMetaAndKittyFlags(optionAsMeta: Bool) throws {
        let fixture = try ShortcutViewFixture()
        let view = fixture.view
        view.optionAsMeta = optionAsMeta
        fixture.terminal.feed(text: "\u{1b}[>1u")
        let kittyFlags = fixture.terminal.withLocked { $0.kittyKeyboardFlags }
        try #require(kittyFlags == 1, "pushing disambiguate set Kitty flags \(kittyFlags)")

        view.keyDown(with: try optionBackspace())
        view.keyDown(with: try optionForwardDelete())
        let sent = fixture.recorder.sent
        let expected: [[UInt8]] = [[0x1B, 0x7F], [0x1B, 0x64]]
        #expect(sent == expected, "with Option as Meta \(optionAsMeta) ⌥⌫ then ⌥⌦ sent \(sent)")
    }

    /// The shortcuts belong to the focused terminal only: `performKeyEquivalent` is offered to
    /// every view in the window, and a terminal that is not first responder sends nothing and
    /// leaves the key for the view that is.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func shortcutsGoOnlyToTheFocusedTerminal() throws {
        let fixture = try ShortcutViewFixture()
        let view = fixture.view
        let parent = KeyCountingView()
        let window = try mountedWindow(holding: view, in: parent, focusing: parent)
        defer { window.contentView = nil }

        let handled = view.performKeyEquivalent(with: try cmdLeft())
        #expect(!handled, "a terminal that is not first responder took ⌘←")
        view.keyDown(with: try optionBackspace())
        view.keyDown(with: try cmdUp())
        #expect(fixture.recorder.sent.isEmpty, "a terminal that is not first responder sent \(fixture.recorder.sent)")
        #expect(parent.keyDowns == 2, "\(parent.keyDowns) of the 2 keys went on up the responder chain")

        try #require(window.makeFirstResponder(view), "the view would not take focus")
        let focused = view.performKeyEquivalent(with: try cmdLeft())
        #expect(focused, "the focused terminal left ⌘← for the menus")
        let sent = fixture.recorder.sent
        #expect(sent == [[0x1B, 0x5B, 0x48]], "the focused terminal sent \(sent) for ⌘←")
    }

    // MARK: - ⌘ keys no menu took

    /// A ⌘ key that reaches `keyDown` gets what SwiftTerm's key bindings give it. ⌘. is
    /// `cancelOperation:` and sends Escape. ⌘↑ sends nothing without Kitty flags, and is consumed
    /// rather than passed up the chain to beep. Under Kitty flags they go with Super held. ⌘Help
    /// sends nothing there either: SwiftTerm does not encode `NSHelpFunctionKey`.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func commandKeysNoMenuTookSendWhatSwiftTermSends() throws {
        let fixture = try ShortcutViewFixture()
        let view = fixture.view
        let parent = KeyCountingView()
        let window = try mountedWindow(holding: view, in: parent, focusing: view)
        defer { window.contentView = nil }

        view.keyDown(with: try cmdPeriod())
        let cancel = fixture.recorder.sent
        #expect(cancel == [[0x1B]], "⌘. sent \(cancel)")

        fixture.recorder.sent = []
        view.keyDown(with: try cmdUp())
        view.keyDown(with: try keyDown(0x00, "a", flags: .command))
        #expect(fixture.recorder.sent.isEmpty, "⌘↑ and ⌘A without Kitty flags sent \(fixture.recorder.sent)")
        #expect(parent.keyDowns == 0, "\(parent.keyDowns) ⌘ keys went on up the responder chain")

        fixture.terminal.feed(text: "\u{1b}[>1u")
        view.keyDown(with: try cmdUp())
        view.keyDown(with: try cmdPeriod())
        view.keyDown(with: try keyDown(0x72, "\u{F746}", flags: [.command, .function]))
        let kitty = fixture.recorder.sent
        let expected: [[UInt8]] = [Array("\u{1b}[1;9A".utf8), Array("\u{1b}[27;9u".utf8)]
        #expect(kitty == expected, "under Kitty flags ⌘↑, ⌘. and ⌘Help sent \(kitty)")
    }

    /// ⌘⌥O switches Option between Meta and the layout's characters, as in SwiftTerm, and
    /// sends nothing.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func commandOptionOTogglesOptionAsMeta() throws {
        let fixture = try ShortcutViewFixture()
        let view = fixture.view
        #expect(view.optionAsMeta, "Option is not Meta by default")

        view.keyDown(with: try cmdOptionO())
        #expect(!view.optionAsMeta, "⌘⌥O left Option as Meta")
        view.keyDown(with: try cmdOptionO())
        #expect(view.optionAsMeta, "a second ⌘⌥O did not make Option Meta again")
        #expect(fixture.recorder.sent.isEmpty, "⌘⌥O sent \(fixture.recorder.sent)")
    }

    // MARK: - Page Up and Page Down

    /// On the primary screen, PageUp and PageDown page the viewport through the scrollback and send
    /// nothing, as SwiftTerm's `pageUp()` and `pageDown()` do. With Shift held the key goes to the
    /// program.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func pageKeysScrollThePrimaryScreen() throws {
        let fixture = try ShortcutViewFixture()
        let view = fixture.view
        let terminal = fixture.terminal
        terminal.feed(text: sixtyLines)
        let rows = terminal.withLocked { $0.rows }
        let bottom = try viewportOffset(of: terminal)
        try #require(bottom >= rows, "sixty lines left \(bottom) rows of scrollback, less than a \(rows)-row page")

        view.keyDown(with: try pageUp())
        let afterUp = try viewportOffset(of: terminal)
        #expect(afterUp == bottom - rows, "PageUp moved the viewport from \(bottom) to \(afterUp), not a \(rows)-row page")
        view.keyDown(with: try pageDown())
        let afterDown = try viewportOffset(of: terminal)
        #expect(afterDown == bottom, "PageDown moved the viewport from \(afterUp) to \(afterDown), not back to \(bottom)")
        #expect(fixture.recorder.sent.isEmpty, "paging the viewport sent \(fixture.recorder.sent)")

        view.keyDown(with: try pageUp(.shift))
        let shifted = fixture.recorder.sent
        #expect(shifted == [Array("\u{1b}[5;2~".utf8)], "⇧PageUp sent \(shifted)")
        let afterShift = try viewportOffset(of: terminal)
        #expect(afterShift == bottom, "⇧PageUp moved the viewport from \(bottom) to \(afterShift)")
    }

    /// A program that made the page keys its own gets them: under application cursor keys, on the
    /// alternate screen, and under Kitty flags PageUp sends `CSI 5 ~` and scrolls nothing.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice),
          arguments: [("DECCKM", "\u{1b}[?1h"), ("the alternate screen", "\u{1b}[?1049h"), ("Kitty flags", "\u{1b}[>1u")])
    func pageKeysGoToAProgramThatClaimedThem(mode: String, enable: String) throws {
        let fixture = try ShortcutViewFixture()
        let view = fixture.view
        let terminal = fixture.terminal
        terminal.feed(text: sixtyLines + enable)
        let before = try viewportOffset(of: terminal)

        view.keyDown(with: try pageUp())
        let sent = fixture.recorder.sent
        #expect(sent == [Array("\u{1b}[5~".utf8)], "under \(mode) PageUp sent \(sent)")
        let after = try viewportOffset(of: terminal)
        #expect(after == before, "under \(mode) PageUp moved the viewport from \(before) to \(after)")
    }

    /// With Option as Meta, ⌥PageUp goes to the program as `CSI 5;3~`, as SwiftTerm sends it.
    /// Without, Option is no modifier to SwiftTerm, which pages the key through `pageUp()`: the
    /// viewport pages, under DECCKM too, and on the alternate screen the program gets plain
    /// `CSI 5 ~`, not the `CSI 5;3~` the key encoder would send.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func optionPageUpFollowsOptionAsMeta() throws {
        let fixture = try ShortcutViewFixture()
        let view = fixture.view
        let terminal = fixture.terminal
        terminal.feed(text: sixtyLines)
        let rows = terminal.withLocked { $0.rows }
        let bottom = try viewportOffset(of: terminal)

        view.optionAsMeta = true
        view.keyDown(with: try pageUp(.option))
        let meta = fixture.recorder.sent
        #expect(meta == [Array("\u{1b}[5;3~".utf8)], "⌥PageUp with Option as Meta sent \(meta)")

        fixture.recorder.sent = []
        view.optionAsMeta = false
        view.keyDown(with: try pageUp(.option))
        #expect(fixture.recorder.sent.isEmpty, "⌥PageUp without Meta sent \(fixture.recorder.sent)")
        let afterUp = try viewportOffset(of: terminal)
        #expect(afterUp == bottom - rows, "⌥PageUp without Meta moved the viewport from \(bottom) to \(afterUp)")

        view.keyDown(with: try pageDown(.option))
        terminal.feed(text: "\u{1b}[?1h")
        view.keyDown(with: try pageUp(.option))
        #expect(fixture.recorder.sent.isEmpty, "under DECCKM ⌥PageUp without Meta sent \(fixture.recorder.sent)")
        let underCursorKeys = try viewportOffset(of: terminal)
        #expect(underCursorKeys == bottom - rows,
                "under DECCKM ⌥PageUp without Meta moved the viewport from \(bottom) to \(underCursorKeys)")

        terminal.feed(text: "\u{1b}[?1049h")
        view.keyDown(with: try pageUp(.option))
        let claimed = fixture.recorder.sent
        #expect(claimed == [Array("\u{1b}[5~".utf8)], "on the alternate screen ⌥PageUp without Meta sent \(claimed)")
    }

    // MARK: - Shift-Enter and Shift-Escape

    /// Without Kitty flags or modifyOtherKeys, ⇧↩ is Return and ⇧Esc is Escape, as macOS binds
    /// them in SwiftTerm, not the `CSI 27;2;13~` a shell prints. Alt held as Meta puts an ESC in
    /// front, as for Alt-Enter.
    @Test func shiftEnterAndShiftEscapeSendThePlainKey() throws {
        let terminal = try makeTerminal()
        defer { terminal.close() }

        let enter = encoded(try shiftReturn(), on: terminal)
        #expect(enter == [0x0D], "⇧↩ sent \(describe(enter))")
        let escape = encoded(try shiftEscape(), on: terminal)
        #expect(escape == [0x1B], "⇧Esc sent \(describe(escape))")
        let meta = encoded(try shiftReturn([.shift, .option]), on: terminal, optionAsAlt: .both)
        #expect(meta == [0x1B, 0x0D], "⌥⇧↩ with Option as Meta sent \(describe(meta))")
        let plain = encoded(try keyDown(0x24, "\r"), on: terminal)
        #expect(plain == [0x0D], "↩ sent \(describe(plain))")
    }

    /// A program that asked for modified keys gets them: `CSI 13;2u` under Kitty flags, and the
    /// xterm form under modifyOtherKeys level 2. The probe that tells level 2 apart leaves the
    /// encoder's next key alone.
    @Test func shiftEnterStaysModifiedWhenTheProgramAsksForIt() throws {
        let kitty = try makeTerminal()
        defer { kitty.close() }
        kitty.feed(text: "\u{1b}[>1u")
        let csiU = encoded(try shiftReturn(), on: kitty)
        #expect(csiU == Array("\u{1b}[13;2u".utf8), "under Kitty flags ⇧↩ sent \(describe(csiU))")

        let xterm = try makeTerminal()
        defer { xterm.close() }
        xterm.feed(text: "\u{1b}[>4;2m")
        let enter = encoded(try shiftReturn(), on: xterm)
        #expect(enter == Array("\u{1b}[27;2;13~".utf8), "under modifyOtherKeys 2 ⇧↩ sent \(describe(enter))")
        let escape = encoded(try shiftEscape(), on: xterm)
        #expect(escape == Array("\u{1b}[27;2;27~".utf8), "under modifyOtherKeys 2 ⇧Esc sent \(describe(escape))")
        let plain = encoded(try keyDown(0x24, "\r"), on: xterm)
        #expect(plain == [0x0D], "after the probe ↩ sent \(describe(plain))")

        xterm.feed(text: "\u{1b}[>4;0m")
        let reset = encoded(try shiftReturn(), on: xterm)
        #expect(reset == [0x0D], "with modifyOtherKeys reset ⇧↩ sent \(describe(reset))")
    }

    /// The parser replaces only Shift and Shift-Alt with Enter or Escape, and only without Kitty
    /// flags.
    @Test func legacyShiftedEnterOrEscapeReplacesOnlyItsForms() {
        let replaced: [(form: String, bytes: [UInt8])] = [
            ("\u{1b}[27;2;13~", [0x0D]),
            ("\u{1b}[27;2;27~", [0x1B]),
            ("\u{1b}[27;4;13~", [0x1B, 0x0D]),
            ("\u{1b}[27;4;27~", [0x1B, 0x1B]),
        ]
        for form in replaced {
            let bytes: [UInt8]? = KeyEncoder.legacyShiftedEnterOrEscape(replacing: Array(form.form.utf8), kittyFlags: 0)
            let expected: [UInt8]? = form.bytes
            #expect(bytes == expected, "\(form.form.debugDescription) became \(describe(bytes))")
        }

        let kept = ["\u{1b}[27;5;13~", "\u{1b}[27;6;27~", "\u{1b}[27;2;9~", "\u{1b}[27;2;127~", "\u{1b}[5;2~", "\u{1b}[13;2u"]
        for form in kept {
            let bytes = KeyEncoder.legacyShiftedEnterOrEscape(replacing: Array(form.utf8), kittyFlags: 0)
            #expect(bytes == nil, "\(form.debugDescription) became \(describe(bytes))")
        }
        let underKitty = KeyEncoder.legacyShiftedEnterOrEscape(replacing: Array("\u{1b}[27;2;13~".utf8), kittyFlags: 1)
        #expect(underKitty == nil, "under Kitty flags the form became \(describe(underKitty))")
    }

    // MARK: - Select All

    /// Edit > Select All selects the whole screen, scrollback included, as in SwiftTerm, and
    /// sends nothing.
    @Test func selectAllSelectsTheScrollbackToo() throws {
        let terminal = try makeTerminal()
        defer { terminal.close() }
        terminal.feed(text: sixtyLines)

        let selected = terminal.selectAll()
        #expect(selected, "Select All selected nothing")
        let text = try #require(terminal.copySelectionText(), "Select All left no selection to copy")
        #expect(text.hasPrefix("line 0\n"), "the selection starts \(text.prefix(20).debugDescription)")
        #expect(text.contains("line 59"), "the selection stops before the last line: \(text.suffix(40).debugDescription)")
    }

    /// The view's `selectAll(_:)`, which Edit > Select All and ⌘A reach, does the same.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func selectAllActionSelectsEverything() throws {
        let fixture = try ShortcutViewFixture()
        fixture.terminal.feed(text: sixtyLines)

        fixture.view.selectAll(nil)
        let text = try #require(fixture.terminal.copySelectionText(), "selectAll(_:) left no selection to copy")
        #expect(text.hasPrefix("line 0\n") && text.contains("line 59"),
                "selectAll(_:) selected \(text.prefix(20).debugDescription)…\(text.suffix(40).debugDescription)")
        #expect(fixture.recorder.sent.isEmpty, "selectAll(_:) sent \(fixture.recorder.sent)")
    }
}
