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

/// An input method that does what it is told. No input method runs in a test process, so this
/// stands in for one: each key it is handed runs the next step of its script, which calls the
/// view's `NSTextInputClient` methods the way a dead key or an IME would. It also keeps the events
/// it was handed, which are the translated ones the real input context would see.
@MainActor
private final class ScriptedInputMethod {
    typealias Step = @MainActor (NSEvent, GhosttyTerminalView) -> Void
    private var steps: [Step]
    private(set) var eventsSeen: [NSEvent] = []

    init(_ steps: [Step]) { self.steps = steps }

    func install(on view: GhosttyTerminalView) {
        view.inputController.inputMethod = { [self] event, view in
            self.eventsSeen.append(event)
            guard !self.steps.isEmpty else { return }
            self.steps.removeFirst()(event, view)
        }
    }

    /// A step that sets `text` as the marked text, with the insertion point after it.
    static func mark(_ text: String) -> Step {
        { _, view in
            view.setMarkedText(
                text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    /// A step that commits `text`.
    static func commit(_ text: String) -> Step {
        { _, view in view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }

    /// A step that commits whatever the event it was handed types, as a plain key does.
    static func commitTypedCharacters() -> Step {
        { event, view in
            view.insertText(event.characters ?? "", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }
}

/// A US layout for the keys these tests press, so the tests give the same answers whatever layout
/// the machine running them has selected.
private let usLayout = KeyboardLayout { event, modifiers in
    usCharacters(keyCode: event.keyCode, modifiers: modifiers)
}

/// What a US layout types for `keyCode` with `modifiers`, for the keys these tests press.
private func usCharacters(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
    let keys: [UInt16: Character] = [
        0x00: "a", 0x09: "v", 0x0B: "b", 0x0E: "e", 0x21: "[", 0x22: "i", 0x26: "j", 0x2D: "n", 0x2E: "m",
    ]
    if keyCode == 0x24 { return "\r" }
    guard let key = keys[keyCode] else { return nil }
    if modifiers.contains(.option), !modifiers.contains(.control) {
        // Option-b types ∫; Option-e is the acute dead key, which types nothing by itself.
        switch key {
        case "b": return "∫"
        case "e": return ""
        default: break
        }
    }
    var character = key
    if modifiers.contains(.shift) {
        character = key == "[" ? "{" : Character(key.uppercased())
    } else if modifiers.contains(.capsLock), key.isLetter {
        character = Character(key.uppercased())
    }
    guard modifiers.contains(.control) else { return String(character) }
    // Control types the C0 byte: a letter's code AND 0x1F, and ESC for [.
    guard let ascii = character.asciiValue else { return nil }
    return String(UnicodeScalar(ascii & 0x1F))
}

/// An 80×24 terminal and a view over it in a 13 pt monospaced font.
@MainActor
private struct KeyViewFixture {
    let terminal: GhosttyTerminal
    let view: GhosttyTerminalView
    let recorder: SentBytes

    init() throws {
        let recorder = SentBytes()
        self.recorder = recorder
        terminal = try GhosttyTerminal(cols: 80, rows: 24, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        let appearance = GhosttyAppearance(
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            foreground: .init(r: 0xDD, g: 0xDD, b: 0xDD),
            background: .init(r: 0x10, g: 0x10, b: 0x10),
            cursor: .init(r: 0xFF, g: 0xFF, b: 0xFF))
        view = try GhosttyTerminalView(terminal: terminal, appearance: appearance)
        view.setFrameSize(NSSize(width: 400, height: 200))
        view.inputController.layout = usLayout
        view.onSend = { recorder.sent.append($0) }
    }
}

/// A key-down for no window.
private func keyDown(
    _ keyCode: UInt16, characters: String, ignoringModifiers: String, flags: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: characters, charactersIgnoringModifiers: ignoringModifiers,
        isARepeat: false, keyCode: keyCode))
}

/// Ctrl-I, Ctrl-M and Ctrl-[ as AppKit delivers them: the layout's C0 character as `characters`.
private func ctrlI(_ flags: NSEvent.ModifierFlags = .control) throws -> NSEvent {
    try keyDown(0x22, characters: "\t", ignoringModifiers: "i", flags: flags)
}

private func ctrlM() throws -> NSEvent {
    try keyDown(0x2E, characters: "\r", ignoringModifiers: "m", flags: .control)
}

private func ctrlBracket() throws -> NSEvent {
    try keyDown(0x21, characters: "\u{1b}", ignoringModifiers: "[", flags: .control)
}

/// A modifier key's own event: `keyCode` pressed, with `flags` held.
private func modifierKey(_ keyCode: UInt16, flags: NSEvent.ModifierFlags) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode))
}

/// An offscreen window holding `view`, 400×200 points, with the view as its first responder. The
/// window is never on screen; the view counts it as visible. Clear `contentView` when done.
@MainActor
private func windowHolding(_ view: GhosttyTerminalView) throws -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 200),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    view.windowVisibility = { _ in true }
    try #require(window.contentView).addSubview(view)
    try #require(window.makeFirstResponder(view), "the view would not take focus")
    return window
}

/// Sixty numbered lines, so the primary screen has scrollback to scroll back through.
private let sixtyLines = (0..<60).map { "line \($0)\r\n" }.joined()

/// The first scrollable row the viewport shows.
private func viewportOffset(of terminal: GhosttyTerminal) throws -> Int {
    try terminal.withLocked { state in
        TerminalScrollMetrics.read(try #require(state.raw, "the terminal is closed")).offset
    }
}

/// The bytes `event` encodes to on `terminal`, through the same translation the view runs.
@MainActor
private func bytes(for event: NSEvent, on terminal: GhosttyTerminal, optionAsAlt: OptionAsAlt = .never) -> [UInt8] {
    let press = TerminalInputController.keyPress(event: event, action: .press, optionAsAlt: optionAsAlt, layout: usLayout)
    return terminal.encodeKey(press, optionAsAlt: optionAsAlt)
}

private func describe(_ bytes: [UInt8]) -> String {
    String(decoding: bytes, as: UTF8.self).debugDescription
}

/// How many pixels of `layer`, drawn on its own into a clear bitmap, have any ink.
@MainActor
private func inkedPixels(of layer: CATextLayer, scale: CGFloat) throws -> Int {
    let width = max(1, Int((layer.bounds.width * scale).rounded(.up)))
    let height = max(1, Int((layer.bounds.height * scale).rounded(.up)))
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.scaleBy(x: scale, y: scale)
    layer.draw(in: context)
    let data = try #require(context.data)
    let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
    var count = 0
    for index in 0..<(width * height) where pixels[index * 4 + 3] > 0 { count += 1 }
    return count
}

@Suite(.fastPassBounded)
@MainActor
struct KeyAndIMETests {
    // MARK: - Ctrl-I, Ctrl-M, Ctrl-[

    /// With no Kitty keyboard flags, the three keys libghostty encodes as CSI u go out as the C0
    /// bytes a shell reads. Caps Lock does not change that; Alt as Meta puts an ESC first. A
    /// control key libghostty already sends as C0 is untouched.
    @Test func ctrlIMBracketMapToTabReturnEscWithoutCsiU() throws {
        let terminal = try GhosttyTerminal(cols: 80, rows: 24, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        defer { terminal.close() }
        #expect(terminal.withLocked { $0.kittyKeyboardFlags } == 0, "a new terminal starts with Kitty flags set")

        let tab = bytes(for: try ctrlI(), on: terminal)
        #expect(tab == [0x09], "Ctrl-I sent \(describe(tab))")
        let enter = bytes(for: try ctrlM(), on: terminal)
        #expect(enter == [0x0D], "Ctrl-M sent \(describe(enter))")
        let escape = bytes(for: try ctrlBracket(), on: terminal)
        #expect(escape == [0x1B], "Ctrl-[ sent \(describe(escape))")

        let capsLocked = try keyDown(0x22, characters: "\t", ignoringModifiers: "I", flags: [.control, .capsLock])
        let capsTab = bytes(for: capsLocked, on: terminal)
        #expect(capsTab == [0x09], "Ctrl-I under Caps Lock sent \(describe(capsTab))")

        let meta = bytes(for: try ctrlI([.control, .option]), on: terminal, optionAsAlt: .both)
        #expect(meta == [0x1B, 0x09], "Ctrl-Option-I with Option as Meta sent \(describe(meta))")

        let ctrlJ = bytes(for: try keyDown(0x26, characters: "\n", ignoringModifiers: "j", flags: .control), on: terminal)
        #expect(ctrlJ == [0x0A], "Ctrl-J sent \(describe(ctrlJ))")
    }

    /// With no Kitty keyboard flags, Ctrl-Shift-letter sends the letter's control byte, as SwiftTerm
    /// does: Ctrl-Shift-V is 0x16. A program that pushed Kitty flags gets the CSI u it asked for.
    @Test func ctrlShiftLetterSendsTheControlByteWithoutCsiU() throws {
        let terminal = try GhosttyTerminal(cols: 80, rows: 24, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        defer { terminal.close() }
        let ctrlShiftV = try keyDown(0x09, characters: "\u{16}", ignoringModifiers: "V", flags: [.control, .shift])

        let paste = bytes(for: ctrlShiftV, on: terminal)
        #expect(paste == [0x16], "Ctrl-Shift-V sent \(describe(paste))")
        let tab = bytes(for: try ctrlI([.control, .shift]), on: terminal)
        #expect(tab == [0x09], "Ctrl-Shift-I sent \(describe(tab))")

        terminal.feed(text: "\u{1b}[>1u")
        let csiU = bytes(for: ctrlShiftV, on: terminal)
        #expect(csiU == Array("\u{1b}[118;6u".utf8), "under Kitty flags Ctrl-Shift-V sent \(describe(csiU))")
    }

    /// A program that pushes Kitty keyboard flags asked for CSI u, and gets it; popping the flags
    /// goes back to the C0 bytes. Under xterm's modifyOtherKeys 2 the program gets that form.
    @Test func ctrlIMBracketStayCsiUWhenTheProgramAsksForIt() throws {
        let terminal = try GhosttyTerminal(cols: 80, rows: 24, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        defer { terminal.close() }

        terminal.feed(text: "\u{1b}[>1u")
        #expect(terminal.withLocked { $0.kittyKeyboardFlags } == 1, "pushing disambiguate did not set the flag")
        let tab = bytes(for: try ctrlI(), on: terminal)
        #expect(tab == Array("\u{1b}[105;5u".utf8), "under Kitty flags Ctrl-I sent \(describe(tab))")
        let enter = bytes(for: try ctrlM(), on: terminal)
        #expect(enter == Array("\u{1b}[109;5u".utf8), "under Kitty flags Ctrl-M sent \(describe(enter))")
        let escape = bytes(for: try ctrlBracket(), on: terminal)
        #expect(escape == Array("\u{1b}[91;5u".utf8), "under Kitty flags Ctrl-[ sent \(describe(escape))")

        terminal.feed(text: "\u{1b}[<u")
        let popped = bytes(for: try ctrlI(), on: terminal)
        #expect(popped == [0x09], "after the flags were popped Ctrl-I sent \(describe(popped))")

        let xterm = try GhosttyTerminal(cols: 80, rows: 24, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        defer { xterm.close() }
        xterm.feed(text: "\u{1b}[>4;2m")
        let modified = bytes(for: try ctrlI(), on: xterm)
        #expect(modified.starts(with: Array("\u{1b}[27;".utf8)) && modified.last == UInt8(ascii: "~"),
                "under modifyOtherKeys 2 Ctrl-I sent \(describe(modified))")
    }

    // MARK: - IME

    /// The composition shows over the cursor cell, as wide as it is, in the terminal's colours.
    /// The input method's candidate window is placed at the same cell. The commit takes the
    /// composition away and sends the text, which the program echoes into the grid.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func markedTextAppearsInFrameAndIsReplacedOnCommit() throws {
        let fixture = try KeyViewFixture()
        let view = fixture.view
        let window = try windowHolding(view)
        defer { window.contentView = nil }

        fixture.terminal.feed(text: "abc")
        let input = ScriptedInputMethod([
            ScriptedInputMethod.mark("n"), ScriptedInputMethod.mark("に"), ScriptedInputMethod.commit("に"),
        ])
        input.install(on: view)

        view.keyDown(with: try keyDown(0x2D, characters: "n", ignoringModifiers: "n"))
        #expect(view.preeditTextLayer?.string as? String == "n", "the first step shows \(String(describing: view.preeditTextLayer?.string))")
        view.keyDown(with: try keyDown(0x22, characters: "i", ignoringModifiers: "i"))
        #expect(fixture.recorder.sent.isEmpty, "keys that only composed sent \(fixture.recorder.sent)")

        let overlay = try #require(view.preeditLayer, "composing left no overlay")
        let text = try #require(view.preeditTextLayer, "the overlay has no text layer")
        #expect(text.string as? String == "に", "the overlay shows \(String(describing: text.string))")
        let cell = view.cellSize
        #expect(abs(overlay.frame.minX - cell.width * 3) < 0.01 && abs(overlay.frame.minY) < 0.01,
                "the overlay sits at \(overlay.frame.origin), not on the cursor after abc (cell \(cell))")
        #expect(abs(overlay.frame.height - cell.height) < 0.01, "the overlay is \(overlay.frame.height) pt high")
        #expect(overlay.frame.width > cell.width * 2 - 0.01, "a wide character got an overlay \(overlay.frame.width) pt wide")
        #expect(overlay.backgroundColor != nil, "the overlay does not cover the cells under it")
        let ink = try inkedPixels(of: text, scale: max(window.backingScaleFactor, 1))
        #expect(ink > 0, "the overlay's text drew nothing")

        let candidates = view.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let expected = window.convertToScreen(view.convert(
            NSRect(x: cell.width * 3, y: 0, width: cell.width, height: cell.height), to: nil))
        #expect(abs(candidates.minX - expected.minX) < 0.5 && abs(candidates.minY - expected.minY) < 0.5,
                "the candidate window goes to \(candidates), not to the cursor cell at \(expected)")

        view.keyDown(with: try keyDown(0x24, characters: "\r", ignoringModifiers: "\r"))
        #expect(view.preeditLayer == nil, "the commit left the composition on screen")
        #expect(!view.hasMarkedText(), "the commit left marked text")
        #expect(fixture.recorder.sent == [Array("に".utf8)], "the commit sent \(fixture.recorder.sent)")

        // The program's echo puts the committed text where the composition was.
        for chunk in fixture.recorder.sent { fixture.terminal.feed(chunk[...]) }
        let line = fixture.terminal.withLocked { $0.lineText(0) }
        #expect(line.hasPrefix("abcに"), "after the echo row 0 reads \(line.debugDescription)")
    }

    /// While the user has scrolled back, the composition and the candidate window sit on the row
    /// the cursor shows on in the viewport, not on its row in the active area. A cursor scrolled
    /// out of view puts them on the bottom row. Composing sends nothing, so it does not scroll.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func compositionWhileScrolledBackSitsOnTheCursorRow() throws {
        let fixture = try KeyViewFixture()
        let view = fixture.view
        let terminal = fixture.terminal
        let window = try windowHolding(view)
        defer { window.contentView = nil }
        view.applyPendingGridResize()
        let rows = terminal.withLocked { $0.rows }
        try #require(rows >= 10, "the view fits only \(rows) rows")

        // The cursor on active row 5, column 3; the viewport three rows back puts it on row 8.
        terminal.feed(text: sixtyLines + "\u{1b}[6;4H")
        _ = terminal.mouseWheel(rows: -3, at: SurfacePoint(x: 1, y: 1), mods: [])
        let scrolledBack = try viewportOffset(of: terminal)
        ScriptedInputMethod([ScriptedInputMethod.mark("n")]).install(on: view)
        view.keyDown(with: try keyDown(0x2D, characters: "n", ignoringModifiers: "n"))
        #expect(fixture.recorder.sent.isEmpty, "composing sent \(fixture.recorder.sent)")
        let afterComposing = try viewportOffset(of: terminal)
        #expect(afterComposing == scrolledBack, "composing scrolled the viewport from \(scrolledBack) to \(afterComposing)")

        let cell = view.cellSize
        let overlay = try #require(view.preeditLayer, "composing left no overlay")
        #expect(abs(overlay.frame.minX - cell.width * 3) < 0.01 && abs(overlay.frame.minY - cell.height * 8) < 0.01,
                "the overlay sits at \(overlay.frame.origin), not on viewport row 8 (cell \(cell))")
        let rowEight = window.convertToScreen(view.convert(
            NSRect(x: cell.width * 3, y: cell.height * 8, width: cell.width, height: cell.height), to: nil))
        let bottomRow = window.convertToScreen(view.convert(
            NSRect(x: cell.width * 3, y: cell.height * CGFloat(rows - 1), width: cell.width, height: cell.height), to: nil))
        let candidates = view.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        #expect(abs(candidates.minY - rowEight.minY) < 0.5 && abs(candidates.minX - rowEight.minX) < 0.5,
                "the candidate window goes to \(candidates), not to viewport row 8 at \(rowEight)")

        _ = terminal.mouseWheel(rows: -20, at: SurfacePoint(x: 1, y: 1), mods: [])
        let below = view.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        #expect(abs(below.minY - bottomRow.minY) < 0.5,
                "with the cursor below the viewport the candidate window goes to \(below), not to the bottom row at \(bottomRow)")
    }

    /// The composition follows the cursor when program output moves it, and goes, with the marked
    /// text, when the view stops being first responder.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func compositionFollowsOutputAndEndsWhenFocusLeaves() throws {
        let fixture = try KeyViewFixture()
        let view = fixture.view
        let window = try windowHolding(view)
        defer { window.contentView = nil }
        ScriptedInputMethod([ScriptedInputMethod.mark("n")]).install(on: view)
        view.keyDown(with: try keyDown(0x2D, characters: "n", ignoringModifiers: "n"))
        let cell = view.cellSize
        let before = try #require(view.preeditLayer, "composing left no overlay").frame.minX

        fixture.terminal.feed(text: "ab")
        view.renderTick()
        let after = try #require(view.preeditLayer, "a frame took the overlay away").frame.minX
        #expect(abs(after - before - cell.width * 2) < 0.01,
                "two characters of output moved the overlay from x \(before) to \(after) (cell \(cell.width))")

        try #require(window.makeFirstResponder(nil), "the view would not give up focus")
        #expect(view.preeditLayer == nil, "losing focus left the composition on screen")
        #expect(!view.hasMarkedText(), "losing focus left marked text")
        #expect(fixture.recorder.sent.isEmpty, "discarding the composition sent \(fixture.recorder.sent)")
    }

    /// Typing brings a viewport the user scrolled back down to the cursor, as SwiftTerm does. A
    /// modifier on its own and a ⌘ shortcut leave it where it is.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func typingScrollsTheViewportToTheBottom() throws {
        let fixture = try KeyViewFixture()
        let view = fixture.view
        let terminal = fixture.terminal
        // Kitty's "report all keys", so a modifier on its own has bytes to send as well.
        terminal.feed(text: sixtyLines + "\u{1b}[>8u")
        let bottom = try viewportOffset(of: terminal)
        _ = terminal.mouseWheel(rows: -5, at: SurfacePoint(x: 1, y: 1), mods: [])
        let scrolledBack = try viewportOffset(of: terminal)
        try #require(scrolledBack == bottom - 5, "scrolling back five rows moved the viewport from \(bottom) to \(scrolledBack)")
        ScriptedInputMethod([ScriptedInputMethod.commitTypedCharacters()]).install(on: view)

        view.flagsChanged(with: try modifierKey(0x38, flags: .shift))
        let afterShift = try viewportOffset(of: terminal)
        #expect(afterShift == scrolledBack, "a Shift press scrolled the viewport from \(scrolledBack) to \(afterShift)")
        _ = view.performKeyEquivalent(with: try keyDown(0x00, characters: "a", ignoringModifiers: "a", flags: .command))
        let afterCommand = try viewportOffset(of: terminal)
        #expect(afterCommand == scrolledBack, "⌘A scrolled the viewport from \(scrolledBack) to \(afterCommand)")

        fixture.recorder.sent = []
        view.keyDown(with: try keyDown(0x00, characters: "a", ignoringModifiers: "a"))
        #expect(!fixture.recorder.sent.isEmpty, "typing a sent nothing")
        let afterTyping = try viewportOffset(of: terminal)
        #expect(afterTyping == bottom, "after typing the viewport is at row \(afterTyping), not \(bottom)")
    }

    /// With Option typing the layout's characters, Option-E is a dead key: it composes the accent
    /// and sends nothing, and the next e commits é.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func deadKeySequenceCommitsComposedCharacter() throws {
        let fixture = try KeyViewFixture()
        let view = fixture.view
        view.optionAsMeta = false
        let input = ScriptedInputMethod([ScriptedInputMethod.mark("´"), ScriptedInputMethod.commit("é")])
        input.install(on: view)

        view.keyDown(with: try keyDown(0x0E, characters: "", ignoringModifiers: "e", flags: .option))
        #expect(fixture.recorder.sent.isEmpty, "the dead key sent \(fixture.recorder.sent)")
        #expect(view.preeditTextLayer?.string as? String == "´",
                "the dead key shows \(String(describing: view.preeditTextLayer?.string))")
        #expect(input.eventsSeen.first?.modifierFlags.contains(.option) == true,
                "the input method was handed Option-E without Option, so it cannot compose")

        view.keyDown(with: try keyDown(0x0E, characters: "e", ignoringModifiers: "e"))
        #expect(fixture.recorder.sent == [[0xC3, 0xA9]], "the dead key sequence sent \(fixture.recorder.sent)")
        #expect(view.preeditLayer == nil, "the commit left the accent on screen")
    }

    /// Option is Meta by default, as in SwiftTerm: Option-b sends ESC b, and the input method sees
    /// the key without Option. With the setting off, Option-b types the layout's character.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func optionAsMetaFollowsSetting() throws {
        let fixture = try KeyViewFixture()
        let view = fixture.view
        let input = ScriptedInputMethod([
            ScriptedInputMethod.commitTypedCharacters(), ScriptedInputMethod.commitTypedCharacters(),
        ])
        input.install(on: view)
        let optionB = try keyDown(0x0B, characters: "∫", ignoringModifiers: "b", flags: .option)

        #expect(view.optionAsMeta, "Option is not Meta by default, so Option-b would type ∫")
        view.keyDown(with: optionB)
        #expect(fixture.recorder.sent == [[0x1B, UInt8(ascii: "b")]], "Option-b as Meta sent \(fixture.recorder.sent)")
        #expect(input.eventsSeen.last?.modifierFlags.contains(.option) == false,
                "the input method was handed Option-b with Option, so it would type ∫")

        fixture.recorder.sent = []
        view.optionAsMeta = false
        #expect(!view.optionAsMeta, "the setting did not stick")
        view.keyDown(with: optionB)
        #expect(fixture.recorder.sent == [Array("∫".utf8)], "Option-b without Meta sent \(fixture.recorder.sent)")
    }
}
