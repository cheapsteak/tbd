import AppKit
import Foundation
@testable import SwiftTerm
import Testing
@testable import TBDApp
@testable import TBDGhosttyTerminal
import TestSupport

/// What a ⌘-hover underlines, the same whichever engine draws the terminal: the URL or path
/// SwiftTerm's link detection finds under the pointer, on every row it covers, while Command is
/// held, and nothing that only TBD's own ⌘-click matcher finds. Each test runs on every engine this
/// machine can build and expects the same cells from each, so the SwiftTerm engine is the reference
/// the libghostty one is held to.
///
/// The SwiftTerm engine's underline is read from its view's `linkHighlightRange`; the libghostty
/// engine's from the layers its mouse controller draws it with. The engine is built through the
/// factory with click routing on, as a panel's is, in an offscreen window, and events are handed
/// straight to its view's overrides, the way AppKit would call them.
@MainActor
@Suite("Terminal engine ⌘-hover", .fastPassBounded)
struct TerminalEngineCommandHoverTests {

    @Test("a ⌘-hover on a printed URL underlines the URL until Command is let go",
          arguments: TerminalEngineFactory.availableKinds)
    func printedURL(kind: TerminalEngineKind) async throws {
        let fixture = try HoverFixture(kind: kind)
        defer { fixture.tearDown() }
        await fixture.show("see \(HoverFixture.linkURL) now")

        try fixture.command(down: true)
        try fixture.move(column: 14, row: 0, flags: .command)

        let underlined = try fixture.underlined()
        #expect(underlined == [Underline(row: 0, columns: 4..<28)], "\(kind): \(underlined)")

        try fixture.command(down: false)
        let afterRelease = try fixture.underlined()
        #expect(afterRelease.isEmpty, "\(kind): letting go of Command left \(afterRelease)")
    }

    /// The URL is longer than what is left of its row, so it wraps; the pointer is on its second
    /// row, so the cells on the first are found across the wrap.
    @Test("a ⌘-hover on a soft-wrapped URL underlines it on both rows",
          arguments: TerminalEngineFactory.availableKinds)
    func softWrappedURL(kind: TerminalEngineKind) async throws {
        let fixture = try HoverFixture(kind: kind, width: 400)
        defer { fixture.tearDown() }
        let columns = fixture.engine.gridSize.cols
        var url = HoverFixture.linkURL
        while 4 + url.count < columns + 10 { url += "/wrapped-segment" }
        try #require(4 + url.count < 2 * columns, "\(url) runs past a second row of \(columns)")
        await fixture.show("see \(url) now")

        try fixture.command(down: true)
        try fixture.move(column: 2, row: 1, flags: .command)

        let underlined = try fixture.underlined()
        let expected = [
            Underline(row: 0, columns: 4..<columns),
            Underline(row: 1, columns: 0..<(4 + url.count - columns)),
        ]
        #expect(underlined == expected, "\(kind): \(underlined)")
    }

    /// A program that wraps its own lines, as an editor or a TUI does, ends the row with a newline
    /// and indents the next. SwiftTerm still reads the two rows as one line, and so as one URL.
    @Test("a ⌘-hover on a URL its program wrapped underlines it on both rows",
          arguments: TerminalEngineFactory.availableKinds)
    func hardWrappedURL(kind: TerminalEngineKind) async throws {
        let fixture = try HoverFixture(kind: kind, width: 400)
        defer { fixture.tearDown() }
        let columns = fixture.engine.gridSize.cols
        var upper = "see \(HoverFixture.linkURL)/"
        while upper.count < columns { upper += "a" }
        try #require(upper.count == columns, "\(upper) does not fill a row of \(columns)")
        await fixture.show("\(upper)\r\n  more/acme now")

        try fixture.command(down: true)
        try fixture.move(column: 14, row: 0, flags: .command)

        let underlined = try fixture.underlined()
        let expected = [Underline(row: 0, columns: 4..<columns), Underline(row: 1, columns: 2..<11)]
        #expect(underlined == expected, "\(kind): \(underlined)")
    }

    /// The pointer arrives over the URL first and stays; Command goes down after. libghostty-only:
    /// the SwiftTerm view reads where the pointer is from the window server, which a test cannot
    /// move, where the libghostty one asks its mouse controller's `pointerLocation`.
    @Test("pressing Command over a URL underlines it with no move, and letting go clears it",
          .enabled(if: EngineTestSupport.canBuildGhostty, EngineTestSupport.noMetalDevice))
    func commandWithNoMove() async throws {
        let fixture = try HoverFixture(kind: .ghostty)
        defer { fixture.tearDown() }
        await fixture.show("see \(HoverFixture.linkURL) now")
        let view = try #require(fixture.engine.view as? GhosttyTerminalView)
        let overTheURL = try fixture.point(column: 14, row: 0)
        view.mouseController.pointerLocation = { _ in overTheURL }

        try fixture.move(column: 14, row: 0, flags: [])
        let beforeCommand = try fixture.underlined()
        #expect(beforeCommand.isEmpty, "a hover without Command underlined \(beforeCommand)")

        try fixture.command(down: true)
        let withCommand = try fixture.underlined()
        #expect(withCommand == [Underline(row: 0, columns: 4..<28)], "Command over the URL underlined \(withCommand)")

        try fixture.command(down: false)
        let afterRelease = try fixture.underlined()
        #expect(afterRelease.isEmpty, "letting go of Command left \(afterRelease)")
    }

    @Test("a hover without Command underlines nothing", arguments: TerminalEngineFactory.availableKinds)
    func noCommand(kind: TerminalEngineKind) async throws {
        let fixture = try HoverFixture(kind: kind)
        defer { fixture.tearDown() }
        await fixture.show("see \(HoverFixture.linkURL) now")

        try fixture.move(column: 14, row: 0, flags: [])

        let underlined = try fixture.underlined()
        #expect(underlined.isEmpty, "\(kind): \(underlined)")
    }

    @Test("a ⌘-hover on an OSC 8 link underlines its text", arguments: TerminalEngineFactory.availableKinds)
    func osc8Link(kind: TerminalEngineKind) async throws {
        let fixture = try HoverFixture(kind: kind)
        defer { fixture.tearDown() }
        await fixture.show("see \u{1b}]8;;\(HoverFixture.linkURL)\u{1b}\\the docs\u{1b}]8;;\u{1b}\\ now")

        try fixture.command(down: true)
        try fixture.move(column: 6, row: 0, flags: .command)

        let underlined = try fixture.underlined()
        #expect(underlined == [Underline(row: 0, columns: 4..<12)], "\(kind): \(underlined)")
    }

    /// A bare file name in the worktree and a pull request number both open on a ⌘-click, through
    /// TBD's matcher, but SwiftTerm's detection finds no link in either, so neither engine
    /// underlines them. The ⌘-click on the file after is the control: TBD's matcher finds it.
    @Test("a ⌘-hover underlines nothing only TBD's own matcher finds",
          arguments: TerminalEngineFactory.availableKinds)
    func matcherTargetsAreNotUnderlined(kind: TerminalEngineKind) async throws {
        let fixture = try HoverFixture(kind: kind)
        defer { fixture.tearDown() }
        await fixture.show("open notes.txt please\r\nmerged in PR #123 today")

        try fixture.command(down: true)
        try fixture.move(column: 7, row: 0, flags: .command)
        let overTheFile = try fixture.underlined()
        #expect(overTheFile.isEmpty, "\(kind): over notes.txt, \(overTheFile)")
        try fixture.move(column: 14, row: 1, flags: .command)
        let overThePullRequest = try fixture.underlined()
        #expect(overThePullRequest.isEmpty, "\(kind): over PR #123, \(overThePullRequest)")

        try await fixture.click(column: 7, row: 0)
        let opened = fixture.recorder.opened
        let file = fixture.worktree.appendingPathComponent("notes.txt").path
        #expect(opened == ["file \(file)"], "\(kind): \(opened)")
    }
}

// MARK: - Fixture and recorder

/// The cells an engine underlines on one row of the screen.
private struct Underline: Equatable, CustomStringConvertible {
    let row: Int
    let columns: Range<Int>

    var description: String { "row \(row) \(columns)" }
}

/// Records what an engine opens, and answers the panel's focus claim.
@MainActor
private final class HoverRecorder: TerminalEngineDelegate {
    /// What opened, in order: `file <path>` for `filePathClicked`, `link <link>` for `openLink`.
    private(set) var opened: [String] = []

    func reset() { opened = [] }

    func engine(_ e: any TerminalEngine, send data: ArraySlice<UInt8>) {}
    func engine(_ e: any TerminalEngine, sizeChanged cols: Int, rows: Int) {}
    func engineBell(_ e: any TerminalEngine) {}
    func engine(_ e: any TerminalEngine, clipboardCopy content: Data) {}
    func engine(_ e: any TerminalEngine, openLink link: String, params: [String: String]) {
        opened.append("link \(link)")
    }
    func engine(_ e: any TerminalEngine, notification title: String, body: String) {}
    func engine(_ e: any TerminalEngine, programStatusPayload payload: [UInt8], observedAt: Date) {}
    func engine(_ e: any TerminalEngine, filePathClicked path: String) {
        opened.append("file \(path)")
    }
    func engineRequestsCloseTab(_ e: any TerminalEngine) {}
    func engineReady(_ e: any TerminalEngine) {}
    func engine(_ e: any TerminalEngine, focusChanged focused: Bool) {}
    /// The panel's answer: take focus on the press.
    func engineMouseDownClaimsFocus(_ e: any TerminalEngine) -> Bool {
        e.view.window?.makeFirstResponder(e.view)
        return true
    }
    func engineMovedToWindow(_ e: any TerminalEngine) {}
    func engine(_ e: any TerminalEngine, controlModePaste data: Data) -> Bool { false }
}

/// An engine from the factory over a scratch worktree holding `notes.txt`, with a GitHub remote,
/// mounted in an offscreen window, with a `HoverRecorder` as its delegate.
@MainActor
private final class HoverFixture {
    /// The URL every link fixture points at.
    static let linkURL = "https://example.com/acme"

    let engine: any TerminalEngine
    let recorder = HoverRecorder()
    let window: NSWindow
    /// A scratch directory standing in for the worktree.
    let worktree: URL
    private let suite: TestDefaultsSuite
    private let appearance: AppearanceSettings
    private var nextEventNumber = 1

    /// - Parameter width: the window's width, in points.
    init(kind: TerminalEngineKind, width: CGFloat = 1000) throws {
        // Under the run's scratch root, whose path is short and holds only path characters.
        let worktree = URL(fileURLWithPath: fencedScratchRoot(prefix: "cmd-hover"), isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: worktree.appendingPathComponent("notes.txt"))
        self.worktree = worktree
        // `UserDefaults.standard` on this unbundled executable is the developer's real
        // TBDApp.plist.
        suite = TestDefaultsSuite("TBDAppTests.EngineCommandHover")
        appearance = AppearanceSettings(defaults: suite.defaults)
        engine = TerminalEngineFactory.make(
            kind: kind, font: appearance.font, appearance: appearance,
            configuration: TerminalEngineConfiguration(
                worktreePath: worktree.path, remoteURL: "https://github.com/acme/widgets"),
            experimentEnabled: false)
        engine.delegate = recorder
        engine.setClickRouting(enabled: true)
        window = EngineTestSupport.mount(engine.view, size: NSSize(width: width, height: 400))
        #expect(engine.kind == kind, "asked for \(kind), the factory built \(engine.kind)")
    }

    func tearDown() {
        // Command is let go first: the SwiftTerm view keeps watching its window's mouse moves
        // while Command is down.
        try? command(down: false)
        engine.delegate = nil
        EngineTestSupport.unmount(window)
        try? FileManager.default.removeItem(at: worktree)
        suite.tearDown()
    }

    /// Clears the screen and writes `text` from the top-left cell.
    func show(_ text: String) async {
        engine.feed(Array("\u{1b}[H\u{1b}[2J\(text)".utf8)[...])
        await EngineTestSupport.settle()
        recorder.reset()
    }

    /// The window point at the centre of the cell at `column`, `row`, by the view's own cell size.
    func point(column: Int, row: Int) throws -> NSPoint {
        if let view = engine.view as? GhosttyTerminalView {
            let cell = view.cellSize
            return view.convert(
                NSPoint(x: (CGFloat(column) + 0.5) * cell.width, y: (CGFloat(row) + 0.5) * cell.height), to: nil)
        }
        let view = try #require(engine.view as? TBDTerminalView, "the engine's view is a \(type(of: engine.view))")
        let cell = view.cellDimensions()
        return view.convert(
            NSPoint(x: (CGFloat(column) + 0.5) * cell.width, y: view.bounds.height - (CGFloat(row) + 0.5) * cell.height),
            to: nil)
    }

    /// The left Command key pressed (`down`) or let go, as its own `flagsChanged` event.
    func command(down: Bool) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: down ? .command : [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0x37))
        engine.view.flagsChanged(with: event)
    }

    /// The pointer moved onto the cell at `column`, `row`, with `flags` held.
    func move(column: Int, row: Int, flags: NSEvent.ModifierFlags) throws {
        engine.view.mouseMoved(with: try mouseEvent(
            .mouseMoved, at: try point(column: column, row: row), flags: flags, eventNumber: 0, clickCount: 0))
    }

    /// A ⌘-press and its release at the cell at `column`, `row`.
    func click(column: Int, row: Int) async throws {
        let location = try point(column: column, row: row)
        let number = nextEventNumber
        nextEventNumber += 1
        engine.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: location, flags: .command, eventNumber: number))
        engine.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: location, flags: .command, eventNumber: number))
        await EngineTestSupport.settle()
    }

    /// The cells the engine underlines, one span per row of the screen, top row first.
    func underlined() throws -> [Underline] {
        if let view = engine.view as? GhosttyTerminalView {
            return view.mouseController.underlinedSpans.map { Underline(row: $0.row, columns: $0.columns) }
        }
        let view = try #require(engine.view as? TBDTerminalView, "the engine's view is a \(type(of: engine.view))")
        // SwiftTerm keeps the rows in its buffer's numbering, which counts the scrollback.
        let top = view.withTerminal { $0.buffer.yDisp }
        return (view.linkHighlightRange ?? []).map { Underline(row: $0.row - top, columns: $0.range) }
    }

    private func mouseEvent(
        _ type: NSEvent.EventType, at location: NSPoint, flags: NSEvent.ModifierFlags, eventNumber: Int,
        clickCount: Int = 1
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: eventNumber, clickCount: clickCount, pressure: type == .mouseMoved ? 0 : 1))
    }
}
