import AppKit
import Foundation
import GhosttyVt
import Metal
@testable import TBDGhosttyCore
@testable import TBDGhosttyTerminal
import TestSupport
import Testing

// GhosttyVt's C terminal type is also named `GhosttyTerminal`; name the Swift class by module.
private typealias Terminal = TBDGhosttyCore.GhosttyTerminal

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
private func makeTerminal() throws -> Terminal {
    try Terminal(cols: 80, rows: 24, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
}

/// An 80×24 terminal and a view over it, with an input method that does nothing, so every key
/// goes to the key encoder as it does when no composition is running.
@MainActor
private struct ShortcutViewFixture {
    let terminal: Terminal
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
private func optionLeft() throws -> NSEvent { try arrow(0x7B, leftArrow, .option) }
private func optionRight() throws -> NSEvent { try arrow(0x7C, rightArrow, .option) }
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

/// `press`'s key again as an event of `type`, with `flags` held.
private func keyEvent(
    _ type: NSEvent.EventType, of press: NSEvent, flags: NSEvent.ModifierFlags, isARepeat: Bool
) throws -> NSEvent {
    let characters = press.characters ?? ""
    let ignoringModifiers = press.charactersIgnoringModifiers ?? ""
    return try #require(NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: characters, charactersIgnoringModifiers: ignoringModifiers,
        isARepeat: isARepeat, keyCode: press.keyCode))
}

/// `press` again as the repeat AppKit sends while its key is held.
private func repeated(_ press: NSEvent) throws -> NSEvent {
    try keyEvent(.keyDown, of: press, flags: press.modifierFlags, isARepeat: true)
}

/// The key-up of `press`'s key, with `flags` held as it is let go: `press`'s own by default.
private func keyUp(of press: NSEvent, flags: NSEvent.ModifierFlags? = nil) throws -> NSEvent {
    try keyEvent(.keyUp, of: press, flags: flags ?? press.modifierFlags, isARepeat: false)
}

/// The flags an arrow's key-up carries once its modifier was let go first, the only way the
/// key-up of a ⌘ arrow arrives: AppKit sends no key-up while ⌘ is down.
private let arrowOnItsOwn: NSEvent.ModifierFlags = [.function, .numericPad]

// MARK: - Reading the terminal

/// Sixty numbered lines, so the primary screen has scrollback to page through.
private let sixtyLines = (0..<60).map { "line \($0)\r\n" }.joined()

/// The first scrollable row the viewport shows.
private func viewportOffset(of terminal: Terminal) throws -> Int {
    try terminal.withLocked { state in
        TerminalScrollMetrics.read(try #require(state.raw, "the terminal is closed")).offset
    }
}

/// The bytes `event` encodes to on `terminal`, through the same translation the view runs.
@MainActor
private func encoded(_ event: NSEvent, on terminal: Terminal, optionAsAlt: OptionAsAlt = .never) -> [UInt8] {
    let press = TerminalInputController.keyPress(
        event: event, action: .press, optionAsAlt: optionAsAlt, layout: shortcutLayout)
    return terminal.encodeKey(press, optionAsAlt: optionAsAlt)
}

/// The bytes `keyUp` encodes to on `terminal` as a release of its own key, as the view sends the
/// release of a key no shortcut took, with Option as Meta, the view's default.
@MainActor
private func encodedRelease(_ keyUp: NSEvent, on terminal: Terminal) -> [UInt8] {
    let release = TerminalInputController.keyPress(
        event: keyUp, translationEvent: keyUp, action: .release, optionAsAlt: .both, text: "",
        layout: shortcutLayout)
    return terminal.encodeKey(release, optionAsAlt: .both)
}

/// The bytes a plain `action` of `key`, with no modifiers, encodes to on `terminal`.
private func encodedPlain(_ key: GhosttyKey, _ action: KeyPress.Action, on terminal: Terminal) -> [UInt8] {
    terminal.encodeKey(KeyPress(action: action, key: key), optionAsAlt: .both)
}

/// The event type of a Kitty key sequence: the field after the colon in its modifiers
/// (`CSI 1;1:3H`), `2` for a repeat and `3` for a release. Nil when the sequence has none, as a
/// press may leave it out.
private func kittyEventType(_ bytes: [UInt8]) -> String? {
    let sequence = String(decoding: bytes, as: UTF8.self)
    guard sequence.hasPrefix("\u{1b}[") else { return nil }
    let fields = sequence.dropFirst(2).dropLast().split(separator: ";", omittingEmptySubsequences: false)
    guard fields.count > 1 else { return nil }
    let modifiers = fields[1].split(separator: ":", omittingEmptySubsequences: false)
    guard modifiers.count > 1 else { return nil }
    return String(modifiers[1])
}

private func describe(_ bytes: [UInt8]?) -> String {
    guard let bytes else { return "nil" }
    return String(decoding: bytes, as: UTF8.self).debugDescription
}

private func describeEditing(_ editing: NaturalTextEditing?) -> String {
    guard let editing else { return "nil" }
    switch editing {
    case .bytes(let bytes): return describe(bytes)
    case .encodedKey(let key): return "\(key) through the key encoder"
    }
}

/// Offers each of `events` to `fixture`'s view as AppKit offers a ⌘ key, through
/// `performKeyEquivalent`, and returns what the view sent, one entry per key that sent anything.
@MainActor
private func sentForKeyEquivalents(_ events: [NSEvent], on fixture: ShortcutViewFixture) -> [[UInt8]] {
    fixture.recorder.sent = []
    for event in events {
        _ = fixture.view.performKeyEquivalent(with: event)
    }
    return fixture.recorder.sent
}

/// Delivers a key-down to `view` as AppKit does: a ⌘ key to `performKeyEquivalent`, and to
/// `keyDown` only if that left it; any other key to `keyDown`.
@MainActor
private func deliver(_ event: NSEvent, to view: GhosttyTerminalView) {
    if event.modifierFlags.contains(.command), view.performKeyEquivalent(with: event) { return }
    view.keyDown(with: event)
}

/// The macOS shortcuts the app's SwiftTerm terminals answer with bytes of their own, through
/// `TBDTerminalView`'s natural text editing and SwiftTerm's `keyDown` and `doCommand(by:)`. The
/// libghostty view has to send the same bytes for the same keys, so a terminal behaves the same
/// whichever engine draws it.
@Suite(.fastPassBounded)
@MainActor
struct MacShortcutParityTests {
    // MARK: - Natural text editing

    /// On the primary screen, where a shell prompt is, the shortcuts are iTerm2's Natural Text
    /// Editing: ⌘← and ⌘→ go to Ctrl-A and Ctrl-E, ⌥← and ⌥→ to `ESC b` and `ESC f`, ⌘⌫ to
    /// Ctrl-U, and ⌥⌫ and ⌥⌦ to the readline word deletions.
    @Test func naturalTextEditingShortcutsMapToShellLineEditing() throws {
        let cases: [(name: String, event: NSEvent, bytes: [UInt8])] = try [
            ("⌘←", cmdLeft(), [0x01]),
            ("⌘→", cmdRight(), [0x05]),
            ("⌥←", optionLeft(), [0x1B, 0x62]),
            ("⌥→", optionRight(), [0x1B, 0x66]),
            ("⌘⌫", cmdBackspace(), [0x15]),
            ("⌥⌫", optionBackspace(), [0x1B, 0x7F]),
            ("⌥⌦", optionForwardDelete(), [0x1B, 0x64]),
        ]
        for shortcut in cases {
            let mapped = TerminalInputController.naturalTextEditing(for: shortcut.event, onAlternateScreen: false)
            let expected: NaturalTextEditing? = .bytes(shortcut.bytes)
            #expect(mapped == expected, "\(shortcut.name) mapped to \(describeEditing(mapped))")
        }
    }

    /// On the alternate screen ⌘← and ⌘→ are a plain Home and End through the key encoder, for
    /// the program's modes to shape, because tmux, screen and vim give Ctrl-A a meaning of their
    /// own. Every other shortcut sends the bytes it sends on the primary screen.
    @Test func naturalTextEditingOnTheAlternateScreenSendsHomeAndEnd() throws {
        let cases: [(name: String, event: NSEvent, editing: NaturalTextEditing)] = try [
            ("⌘←", cmdLeft(), .encodedKey(GHOSTTY_KEY_HOME)),
            ("⌘→", cmdRight(), .encodedKey(GHOSTTY_KEY_END)),
            ("⌥←", optionLeft(), .bytes([0x1B, 0x62])),
            ("⌥→", optionRight(), .bytes([0x1B, 0x66])),
            ("⌘⌫", cmdBackspace(), .bytes([0x15])),
            ("⌥⌫", optionBackspace(), .bytes([0x1B, 0x7F])),
            ("⌥⌦", optionForwardDelete(), .bytes([0x1B, 0x64])),
        ]
        for shortcut in cases {
            let mapped = TerminalInputController.naturalTextEditing(for: shortcut.event, onAlternateScreen: true)
            let expected: NaturalTextEditing? = shortcut.editing
            #expect(mapped == expected, "on the alternate screen \(shortcut.name) mapped to \(describeEditing(mapped))")
        }
    }

    /// Only the one modifier: Shift, Control, or ⌘ and ⌥ together decline, as in
    /// `TBDTerminalView`, and so do the keys on their own and other ⌘ and ⌥ keys, on either
    /// screen. Fn-Delete on its own is one of them: iTerm2's preset sends Ctrl-D for it, which
    /// ends the shell on an empty line, so it stays forward Delete.
    @Test(arguments: [false, true])
    func naturalTextEditingDeclinesOtherModifiersAndKeys(onAlternateScreen: Bool) throws {
        let cases: [(name: String, event: NSEvent)] = try [
            ("⇧⌘←", arrow(0x7B, leftArrow, [.command, .shift])),
            ("⌃⌘←", arrow(0x7B, leftArrow, [.command, .control])),
            ("⌥⌘←", arrow(0x7B, leftArrow, [.command, .option])),
            ("⇧⌥←", arrow(0x7B, leftArrow, [.option, .shift])),
            ("⌃⌥←", arrow(0x7B, leftArrow, [.option, .control])),
            ("⌥⌘⌫", keyDown(0x33, "\u{7F}", flags: [.command, .option])),
            ("⇧⌥⌫", keyDown(0x33, "\u{7F}", flags: [.option, .shift])),
            ("⌃⌥⌫", keyDown(0x33, "\u{7F}", flags: [.option, .control])),
            ("⌘⌦", keyDown(0x75, forwardDelete, flags: [.command, .function])),
            ("⌥↑", arrow(0x7E, upArrow, .option)),
            ("←", arrow(0x7B, leftArrow)),
            ("⌫", keyDown(0x33, "\u{7F}")),
            ("⌦", keyDown(0x75, forwardDelete, flags: .function)),
            ("⌘A", keyDown(0x00, "a", flags: .command)),
        ]
        for shortcut in cases {
            let mapped = TerminalInputController.naturalTextEditing(
                for: shortcut.event, onAlternateScreen: onAlternateScreen)
            #expect(mapped == nil, "\(shortcut.name) mapped to \(describeEditing(mapped))")
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
            ("⌘←", cmdLeft(), [0x01]),
            ("⌘→", cmdRight(), [0x05]),
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

    /// ⌘← and ⌘→ follow the screen. On the primary screen they send Ctrl-A and Ctrl-E, under
    /// DECCKM too, which oh-my-zsh turns on at its prompt. On the alternate screen they send Home
    /// and End in the form the program's cursor-key mode asks for: `ESC [ H` without DECCKM,
    /// `ESC O H` with it. Back on the primary screen they send Ctrl-A and Ctrl-E again.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func commandArrowsFollowTheScreen() throws {
        let fixture = try ShortcutViewFixture()
        let terminal = fixture.terminal
        let arrows = try [cmdLeft(), cmdRight()]
        let lineEdges: [[UInt8]] = [[0x01], [0x05]]

        let primary = sentForKeyEquivalents(arrows, on: fixture)
        #expect(primary == lineEdges, "on the primary screen ⌘← then ⌘→ sent \(primary)")

        terminal.feed(text: "\u{1b}[?1h")
        let primaryUnderCursorKeys = sentForKeyEquivalents(arrows, on: fixture)
        #expect(primaryUnderCursorKeys == lineEdges,
                "on the primary screen under DECCKM ⌘← then ⌘→ sent \(primaryUnderCursorKeys)")

        terminal.feed(text: "\u{1b}[?1l\u{1b}[?1049h")
        let onAlternate = terminal.withLocked { $0.isAlternateScreen }
        try #require(onAlternate, "?1049h did not switch to the alternate screen")
        let normal = sentForKeyEquivalents(arrows, on: fixture)
        let normalHomeEnd: [[UInt8]] = [Array("\u{1b}[H".utf8), Array("\u{1b}[F".utf8)]
        #expect(normal == normalHomeEnd, "on the alternate screen ⌘← then ⌘→ sent \(normal)")

        terminal.feed(text: "\u{1b}[?1h")
        let application = sentForKeyEquivalents(arrows, on: fixture)
        let applicationHomeEnd: [[UInt8]] = [Array("\u{1b}OH".utf8), Array("\u{1b}OF".utf8)]
        #expect(application == applicationHomeEnd,
                "on the alternate screen under DECCKM ⌘← then ⌘→ sent \(application)")

        terminal.feed(text: "\u{1b}[?1049l")
        let stillOnAlternate = terminal.withLocked { $0.isAlternateScreen }
        try #require(!stillOnAlternate, "?1049l did not return to the primary screen")
        let back = sentForKeyEquivalents(arrows, on: fixture)
        #expect(back == lineEdges, "back on the primary screen ⌘← then ⌘→ sent \(back)")
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

    /// ⌥← and ⌥→ send `ESC b` and `ESC f` whether or not Option is Meta, on either screen, and
    /// under DECCKM and Kitty flags too, where the key encoder would send a modified arrow.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice), arguments: [true, false])
    func optionArrowsMoveByWordOnEitherScreen(optionAsMeta: Bool) throws {
        let fixture = try ShortcutViewFixture()
        let view = fixture.view
        view.optionAsMeta = optionAsMeta
        let words: [[UInt8]] = [[0x1B, 0x62], [0x1B, 0x66]]

        view.keyDown(with: try optionLeft())
        view.keyDown(with: try optionRight())
        let primary = fixture.recorder.sent
        #expect(primary == words, "with Option as Meta \(optionAsMeta) on the primary screen ⌥← then ⌥→ sent \(primary)")

        fixture.recorder.sent = []
        fixture.terminal.feed(text: "\u{1b}[?1049h\u{1b}[?1h\u{1b}[>1u")
        let modes = fixture.terminal.withLocked { (alternate: $0.isAlternateScreen, kitty: $0.kittyKeyboardFlags) }
        try #require(modes.alternate && modes.kitty == 1, "the alternate screen and Kitty flags did not take: \(modes)")
        view.keyDown(with: try optionLeft())
        view.keyDown(with: try optionRight())
        let alternate = fixture.recorder.sent
        #expect(alternate == words,
                "with Option as Meta \(optionAsMeta) on the alternate screen ⌥← then ⌥→ sent \(alternate)")
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
        #expect(sent == [[0x01]], "the focused terminal sent \(sent) for ⌘←")
    }

    // MARK: - Releases

    /// A shortcut that sends fixed bytes sends no release under Kitty flags that report key
    /// releases, because the program was never told its key was pressed. That holds with the
    /// modifier still down at the release and with it let go first. The flags report every key as
    /// an escape code as well, so Backspace has a release to send: without that flag the Kitty
    /// protocol reports no release of Backspace.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aShortcutThatSendsBytesSendsNoRelease() throws {
        let fixture = try ShortcutViewFixture()
        let terminal = fixture.terminal
        // Disambiguate, report event types, report all keys.
        terminal.feed(text: "\u{1b}[>11u")
        let kittyFlags = terminal.withLocked { $0.kittyKeyboardFlags }
        try #require(kittyFlags == 11, "pushing Kitty flags 11 set \(kittyFlags)")

        let optionArrow: NSEvent.ModifierFlags = [.option, .function, .numericPad]
        let cases: [(name: String, press: NSEvent, releaseFlags: NSEvent.ModifierFlags, bytes: [UInt8])] = try [
            ("⌥←", optionLeft(), optionArrow, [0x1B, 0x62]),
            ("⌥← with ⌥ let go first", optionLeft(), arrowOnItsOwn, [0x1B, 0x62]),
            ("⌥→", optionRight(), optionArrow, [0x1B, 0x66]),
            ("⌘⌫ with ⌘ let go first", cmdBackspace(), [], [0x15]),
            ("⌥⌫", optionBackspace(), .option, [0x1B, 0x7F]),
            ("⌥⌦", optionForwardDelete(), [.option, .function], [0x1B, 0x64]),
            ("⌘← with ⌘ let go first", cmdLeft(), arrowOnItsOwn, [0x01]),
            ("⌘→ with ⌘ let go first", cmdRight(), arrowOnItsOwn, [0x05]),
        ]
        for shortcut in cases {
            let release = try keyUp(of: shortcut.press, flags: shortcut.releaseFlags)
            let ownRelease = encodedRelease(release, on: terminal)
            try #require(!ownRelease.isEmpty, "the key encoder has no release of \(shortcut.name)'s key to hold back")

            fixture.recorder.sent = []
            deliver(shortcut.press, to: fixture.view)
            fixture.view.keyUp(with: release)
            let sent = fixture.recorder.sent
            #expect(sent == [shortcut.bytes], "\(shortcut.name) pressed and let go sent \(sent)")
        }
    }

    /// On the alternate screen ⌘← and ⌘→ go out as Home and End, so under Kitty flags that report
    /// event types their releases are Home's and End's, not the arrows' whose keys they are.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func commandArrowsOnTheAlternateScreenReleaseHomeAndEnd() throws {
        let fixture = try ShortcutViewFixture()
        let terminal = fixture.terminal
        // The alternate screen, then Kitty's disambiguate and report-event-types flags.
        terminal.feed(text: "\u{1b}[?1049h\u{1b}[>3u")
        let modes = terminal.withLocked { (alternate: $0.isAlternateScreen, kitty: $0.kittyKeyboardFlags) }
        try #require(modes.alternate && modes.kitty == 3, "the alternate screen and Kitty flags did not take: \(modes)")

        let cases: [(name: String, press: NSEvent, key: GhosttyKey, keyName: String)] = try [
            ("⌘←", cmdLeft(), GHOSTTY_KEY_HOME, "Home"),
            ("⌘→", cmdRight(), GHOSTTY_KEY_END, "End"),
        ]
        for shortcut in cases {
            let release = try keyUp(of: shortcut.press, flags: arrowOnItsOwn)
            let keyPress = encodedPlain(shortcut.key, .press, on: terminal)
            let keyRelease = encodedPlain(shortcut.key, .release, on: terminal)
            let arrowRelease = encodedRelease(release, on: terminal)
            try #require(!keyRelease.isEmpty && keyRelease != arrowRelease,
                         "\(shortcut.keyName)'s release \(describe(keyRelease)) is not told from the arrow's \(describe(arrowRelease))")
            let eventType = kittyEventType(keyRelease)
            #expect(eventType == "3",
                    "\(shortcut.keyName)'s release \(describe(keyRelease)) has event type \(String(describing: eventType))")

            fixture.recorder.sent = []
            deliver(shortcut.press, to: fixture.view)
            fixture.view.keyUp(with: release)
            let sent = fixture.recorder.sent
            #expect(sent == [keyPress, keyRelease],
                    "on the alternate screen \(shortcut.name) pressed and let go sent \(sent), not \(shortcut.keyName)'s press and release")
        }
    }

    /// Holding ⌘← on the alternate screen under Kitty flags that report event types sends Home's
    /// press, then Home's repeats rather than more presses, then Home's release.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func holdingCommandLeftOnTheAlternateScreenRepeatsHome() throws {
        let fixture = try ShortcutViewFixture()
        let terminal = fixture.terminal
        terminal.feed(text: "\u{1b}[?1049h\u{1b}[>3u")
        let modes = terminal.withLocked { (alternate: $0.isAlternateScreen, kitty: $0.kittyKeyboardFlags) }
        try #require(modes.alternate && modes.kitty == 3, "the alternate screen and Kitty flags did not take: \(modes)")

        let homePress = encodedPlain(GHOSTTY_KEY_HOME, .press, on: terminal)
        let homeRepeat = encodedPlain(GHOSTTY_KEY_HOME, .repeated, on: terminal)
        let homeRelease = encodedPlain(GHOSTTY_KEY_HOME, .release, on: terminal)
        try #require(homeRepeat != homePress, "Home's repeat \(describe(homeRepeat)) is its press")
        let eventType = kittyEventType(homeRepeat)
        #expect(eventType == "2", "Home's repeat \(describe(homeRepeat)) has event type \(String(describing: eventType))")

        let press = try cmdLeft()
        deliver(press, to: fixture.view)
        deliver(try repeated(press), to: fixture.view)
        deliver(try repeated(press), to: fixture.view)
        fixture.view.keyUp(with: try keyUp(of: press, flags: arrowOnItsOwn))
        let sent = fixture.recorder.sent
        #expect(sent == [homePress, homeRepeat, homeRepeat, homeRelease],
                "holding ⌘← on the alternate screen sent \(sent)")
    }

    /// A key's repeats keep the release its press decided. ⌥← held sends `ESC b` for the press and
    /// each repeat, and no release. ← pressed on its own went out as itself, so its release does
    /// too, after ⌥ pressed while it was held turned its repeats into `ESC b`.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func repeatsKeepTheReleaseThePressDecided() throws {
        let fixture = try ShortcutViewFixture()
        let view = fixture.view
        let terminal = fixture.terminal
        terminal.feed(text: "\u{1b}[>3u")
        let kittyFlags = terminal.withLocked { $0.kittyKeyboardFlags }
        try #require(kittyFlags == 3, "pushing Kitty flags 3 set \(kittyFlags)")
        let word: [UInt8] = [0x1B, 0x62]
        let optionArrow: NSEvent.ModifierFlags = [.option, .function, .numericPad]

        let shortcut = try optionLeft()
        view.keyDown(with: shortcut)
        view.keyDown(with: try repeated(shortcut))
        view.keyDown(with: try repeated(shortcut))
        view.keyUp(with: try keyUp(of: shortcut, flags: optionArrow))
        let held = fixture.recorder.sent
        #expect(held == [word, word, word], "⌥← held and let go sent \(held)")

        fixture.recorder.sent = []
        let plain = try arrow(0x7B, leftArrow)
        let release = try keyUp(of: plain, flags: optionArrow)
        let leftPress = encoded(plain, on: terminal, optionAsAlt: .both)
        let leftRelease = encodedRelease(release, on: terminal)
        try #require(!leftRelease.isEmpty, "the key encoder has no release of ← with ⌥ held")
        view.keyDown(with: plain)
        view.keyDown(with: try repeated(shortcut))
        view.keyUp(with: release)
        let thenOption = fixture.recorder.sent
        #expect(thenOption == [leftPress, word, leftRelease], "← pressed, then ⌥ while it was held, sent \(thenOption)")
    }

    /// A key that is not a shortcut keeps its own press and release under Kitty flags that report
    /// event types, after a shortcut on the same key too: after ⌥← pressed and let go, and after
    /// ⌘← let go while ⌘ was down, whose key-up AppKit never sends.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aPlainArrowKeepsItsReleaseAfterAShortcutOnTheSameKey() throws {
        let fixture = try ShortcutViewFixture()
        let view = fixture.view
        let terminal = fixture.terminal
        terminal.feed(text: "\u{1b}[>3u")
        let kittyFlags = terminal.withLocked { $0.kittyKeyboardFlags }
        try #require(kittyFlags == 3, "pushing Kitty flags 3 set \(kittyFlags)")

        let plain = try arrow(0x7B, leftArrow)
        let release = try keyUp(of: plain)
        let leftPress = encoded(plain, on: terminal, optionAsAlt: .both)
        let leftRelease = encodedRelease(release, on: terminal)
        try #require(!leftRelease.isEmpty, "the key encoder has no release of ←")

        view.keyDown(with: plain)
        view.keyUp(with: release)
        let alone = fixture.recorder.sent
        #expect(alone == [leftPress, leftRelease], "← pressed and let go sent \(alone)")

        fixture.recorder.sent = []
        let shortcut = try optionLeft()
        view.keyDown(with: shortcut)
        view.keyUp(with: try keyUp(of: shortcut))
        view.keyDown(with: plain)
        view.keyUp(with: release)
        let afterWord = fixture.recorder.sent
        #expect(afterWord == [[0x1B, 0x62], leftPress, leftRelease], "⌥← and then ← sent \(afterWord)")

        fixture.recorder.sent = []
        deliver(try cmdLeft(), to: view)
        view.keyDown(with: plain)
        view.keyUp(with: release)
        let afterLostRelease = fixture.recorder.sent
        #expect(afterLostRelease == [[0x01], leftPress, leftRelease],
                "⌘← with no key-up, and then ← sent \(afterLostRelease)")
    }

    /// Without Kitty's report-event-types flag no key has a release to send, so the shortcuts and
    /// a plain ← send their press and nothing when let go, on the alternate screen too.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice), arguments: ["", "\u{1b}[>1u"])
    func withoutReportedEventsReleasesSendNothing(kittyPush: String) throws {
        let fixture = try ShortcutViewFixture()
        let terminal = fixture.terminal
        terminal.feed(text: "\u{1b}[?1049h" + kittyPush)
        let modes = terminal.withLocked { (alternate: $0.isAlternateScreen, kitty: $0.kittyKeyboardFlags) }
        try #require(modes.alternate && modes.kitty & 2 == 0,
                     "the alternate screen without report-event-types did not take: \(modes)")

        let plain = try arrow(0x7B, leftArrow)
        let cases: [(name: String, press: NSEvent, bytes: [UInt8])] = try [
            ("⌥←", optionLeft(), [0x1B, 0x62]),
            ("⌘⌫", cmdBackspace(), [0x15]),
            ("⌘←", cmdLeft(), encodedPlain(GHOSTTY_KEY_HOME, .press, on: terminal)),
            ("←", plain, encoded(plain, on: terminal, optionAsAlt: .both)),
        ]
        for key in cases {
            fixture.recorder.sent = []
            deliver(key.press, to: fixture.view)
            fixture.view.keyUp(with: try keyUp(of: key.press))
            let sent = fixture.recorder.sent
            #expect(sent == [key.bytes],
                    "with Kitty flags \(modes.kitty) \(key.name) pressed and let go sent \(sent)")
        }
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
