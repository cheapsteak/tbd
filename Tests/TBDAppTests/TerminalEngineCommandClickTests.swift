import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import TBDApp
@testable import TBDGhosttyTerminal
import TestSupport

/// What a ⌘-click on plain text opens, the same whichever engine draws the terminal: a path on one
/// row, found by TBD's own matcher; a path soft-wrapped across rows, or a URL, found by SwiftTerm's
/// link detection; and an OSC 8 link, which wins over both. What TBD's matcher finds opens at the
/// press; what SwiftTerm's detection finds, and an OSC 8 link, at the release, so a ⌘-drag from
/// one opens nothing. Each test runs on every engine this machine can build and expects the same
/// delegate calls from each, so the SwiftTerm engine is the reference the libghostty one is held
/// to.
///
/// The engine is built through the factory with click routing on, as a panel's is, in an
/// offscreen window, and mouse events are handed straight to its view's overrides, the way AppKit
/// would call them.
@MainActor
@Suite("Terminal engine ⌘-click", .fastPassBounded)
struct TerminalEngineCommandClickTests {

    // MARK: - Paths and URLs

    @Test("a ⌘-click on an absolute path opens the file", arguments: TerminalEngineFactory.availableKinds)
    func absolutePath(kind: TerminalEngineKind) async throws {
        let fixture = try CommandClickFixture(kind: kind)
        defer { fixture.tearDown() }
        let path = fixture.notesPath
        await fixture.show("see \(path) now")

        try await fixture.click(column: 6, row: 0)

        let opened = fixture.recorder.opened
        #expect(opened == ["file \(path)"], "\(kind): \(opened)")
    }

    @Test("a ⌘-click on a path relative to the worktree opens the file", arguments: TerminalEngineFactory.availableKinds)
    func relativePath(kind: TerminalEngineKind) async throws {
        let fixture = try CommandClickFixture(kind: kind)
        defer { fixture.tearDown() }
        await fixture.show("open notes.txt please")

        try await fixture.click(column: 7, row: 0)

        let opened = fixture.recorder.opened
        let expected = URL(fileURLWithPath: fixture.worktree.path).appendingPathComponent("notes.txt").path
        #expect(opened == ["file \(expected)"], "\(kind): \(opened)")
    }

    /// The path is longer than a row, so it wraps; the click is on its second row, which on its own
    /// names no file. SwiftTerm's detection joins the rows and hands the whole path to `openLink`,
    /// which the panel resolves to the file.
    @Test("a ⌘-click on a soft-wrapped path hands the whole path on", arguments: TerminalEngineFactory.availableKinds)
    func softWrappedPath(kind: TerminalEngineKind) async throws {
        let fixture = try CommandClickFixture(kind: kind, width: 400)
        defer { fixture.tearDown() }
        let columns = fixture.engine.gridSize.cols
        var path = "/srv/acme"
        while path.count < columns + 10 { path += "/wrapped-segment" }
        path += "/notes.txt"
        try #require(path.count > columns, "\(path) fits on one row of \(columns)")
        await fixture.show(path)

        try await fixture.click(column: 2, row: 1)

        let opened = fixture.recorder.opened
        #expect(opened == ["link \(path)"], "\(kind): \(opened)")
    }

    @Test("a ⌘-click on a printed URL opens it", arguments: TerminalEngineFactory.availableKinds)
    func printedURL(kind: TerminalEngineKind) async throws {
        let fixture = try CommandClickFixture(kind: kind)
        defer { fixture.tearDown() }
        await fixture.show("see \(CommandClickFixture.linkURL) now")

        try await fixture.click(column: 14, row: 0)

        let opened = fixture.recorder.opened
        #expect(opened == ["link \(CommandClickFixture.linkURL)"], "\(kind): \(opened)")
    }

    /// The link's text is a path to a real file, so TBD's matcher would open it too. The OSC 8 link
    /// is all that opens, once.
    @Test("a ⌘-click on an OSC 8 link opens only the link, once", arguments: TerminalEngineFactory.availableKinds)
    func osc8LinkWins(kind: TerminalEngineKind) async throws {
        let fixture = try CommandClickFixture(kind: kind)
        defer { fixture.tearDown() }
        await fixture.show("\u{1b}]8;;\(CommandClickFixture.linkURL)\u{1b}\\\(fixture.notesPath)\u{1b}]8;;\u{1b}\\")

        try await fixture.click(column: 3, row: 0)

        let opened = fixture.recorder.opened
        #expect(opened == ["link \(CommandClickFixture.linkURL)"], "\(kind): \(opened)")
    }

    @Test("a ⌘-click on plain text opens nothing", arguments: TerminalEngineFactory.availableKinds)
    func plainText(kind: TerminalEngineKind) async throws {
        let fixture = try CommandClickFixture(kind: kind)
        defer { fixture.tearDown() }
        await fixture.show("just some words")

        try await fixture.click(column: 2, row: 0)

        let opened = fixture.recorder.opened
        #expect(opened.isEmpty, "\(kind): \(opened)")
    }

    // MARK: - The press

    /// A ⌘-click that opens something never reaches a program holding the mouse. The plain click
    /// after is the control: it is reported, so the program held the mouse throughout.
    @Test("a ⌘-click that opens a path or a URL sends the program nothing", arguments: TerminalEngineFactory.availableKinds)
    func openingClickSendsNothing(kind: TerminalEngineKind) async throws {
        let fixture = try CommandClickFixture(kind: kind)
        defer { fixture.tearDown() }
        await fixture.show("\(fixture.notesPath)\r\nsee \(CommandClickFixture.linkURL) now")
        fixture.engine.feed(Array("\u{1b}[?1002h\u{1b}[?1006h".utf8)[...])
        await EngineTestSupport.settle()
        fixture.recorder.reset()

        try await fixture.click(column: 3, row: 0)
        try await fixture.click(column: 14, row: 1)

        let opened = fixture.recorder.opened
        #expect(opened == ["file \(fixture.notesPath)", "link \(CommandClickFixture.linkURL)"], "\(kind): \(opened)")
        let sentByCommandClicks = fixture.recorder.sends
        #expect(sentByCommandClicks.isEmpty,
                "\(kind): the ⌘-clicks reached the program: \(sentByCommandClicks.map(EngineTestSupport.describe))")

        try await fixture.click(column: 40, row: 5, flags: [])
        let reports = fixture.recorder.sends
        #expect(reports.count == 2,
                "\(kind): the control click sent \(reports.map(EngineTestSupport.describe)), not a press and a release")
    }

    /// The click that brings a background window forward opens a path TBD's matcher finds, and
    /// nothing else: SwiftTerm's view consumes it before its own link detection would see it.
    @Test("the activating ⌘-click opens a path but not a printed URL", arguments: TerminalEngineFactory.availableKinds)
    func activatingClick(kind: TerminalEngineKind) async throws {
        let fixture = try CommandClickFixture(kind: kind)
        defer { fixture.tearDown() }
        await fixture.show("\(fixture.notesPath)\r\nsee \(CommandClickFixture.linkURL) now")

        try await fixture.click(column: 3, row: 0, activating: true)
        try await fixture.click(column: 14, row: 1, activating: true)

        let opened = fixture.recorder.opened
        #expect(opened == ["file \(fixture.notesPath)"], "\(kind): \(opened)")

        // Control: the same click on the URL, in a window already active, opens it.
        try await fixture.click(column: 14, row: 1)
        let openedAfter = fixture.recorder.opened
        #expect(openedAfter == ["file \(fixture.notesPath)", "link \(CommandClickFixture.linkURL)"], "\(kind): \(openedAfter)")
    }

    /// A press the panel declines lands where an overlay leaves the terminal uncovered, and the
    /// overlay owns it. libghostty-only: SwiftTerm's view skips TBD's matcher for that press but
    /// still runs its own detection on the release, so it opens a URL or a path that detection
    /// finds even there.
    @Test("a ⌘-click the panel declines opens nothing",
          .enabled(if: EngineTestSupport.canBuildGhostty, EngineTestSupport.noMetalDevice))
    func declinedPress() async throws {
        let fixture = try CommandClickFixture(kind: .ghostty)
        defer { fixture.tearDown() }
        await fixture.show("\(fixture.notesPath)\r\nsee \(CommandClickFixture.linkURL) now\r\nopen notes.txt please")
        fixture.recorder.claimsPress = false

        try await fixture.click(column: 3, row: 0)
        try await fixture.click(column: 14, row: 1)
        try await fixture.click(column: 7, row: 2)

        let opened = fixture.recorder.opened
        #expect(opened.isEmpty, "a declined ⌘-click opened \(opened)")

        // Control: claimed, the same clicks open all three.
        fixture.recorder.claimsPress = true
        try await fixture.click(column: 3, row: 0)
        try await fixture.click(column: 14, row: 1)
        try await fixture.click(column: 7, row: 2)
        let openedWhenClaimed = fixture.recorder.opened
        #expect(openedWhenClaimed.count == 3, "claimed ⌘-clicks opened \(openedWhenClaimed)")
    }

    /// With click routing off, as on a local PTY's terminal, TBD's matcher does not run, so a bare
    /// file name opens nothing; SwiftTerm's detection still finds a URL, as the SwiftTerm view's
    /// mouse-up does.
    @Test("with click routing off, a ⌘-click opens a URL but not a bare file name",
          arguments: TerminalEngineFactory.availableKinds)
    func routingOff(kind: TerminalEngineKind) async throws {
        let fixture = try CommandClickFixture(kind: kind, routesClicks: false)
        defer { fixture.tearDown() }
        await fixture.show("open notes.txt please\r\nsee \(CommandClickFixture.linkURL) now")

        try await fixture.click(column: 7, row: 0)
        try await fixture.click(column: 14, row: 1)

        let opened = fixture.recorder.opened
        #expect(opened == ["link \(CommandClickFixture.linkURL)"], "\(kind): \(opened)")
    }

    // MARK: - Drags and the release

    /// SwiftTerm's view opens what its link detection finds, and an OSC 8 link, at the release, and
    /// not after a drag, so a ⌘-drag that starts on either selects text and opens nothing. The
    /// ⌘-clicks after are the control: the same presses, released where they went down, open both.
    @Test("a ⌘-drag from a printed URL or an OSC 8 link selects and opens nothing",
          arguments: TerminalEngineFactory.availableKinds)
    func commandDragFromALinkSelects(kind: TerminalEngineKind) async throws {
        let fixture = try CommandClickFixture(kind: kind)
        defer { fixture.tearDown() }
        await fixture.show(CommandClickFixture.twoLinks)

        try await fixture.drag(from: fixture.point(column: 14, row: 0), to: fixture.point(column: 20, row: 0))
        let selectedFromURL = try fixture.hasSelection()
        #expect(selectedFromURL, "\(kind): the ⌘-drag from the URL selected nothing")
        try await fixture.drag(from: fixture.point(column: 3, row: 1), to: fixture.point(column: 12, row: 1))
        let selectedFromLink = try fixture.hasSelection()
        #expect(selectedFromLink, "\(kind): the ⌘-drag from the OSC 8 link selected nothing")
        let openedByDrags = fixture.recorder.opened
        #expect(openedByDrags.isEmpty, "\(kind): the ⌘-drags opened \(openedByDrags)")

        try await fixture.click(column: 14, row: 0)
        try await fixture.click(column: 3, row: 1)
        let openedByClicks = fixture.recorder.opened
        #expect(openedByClicks == CommandClickFixture.twoLinksOpened, "\(kind): \(openedByClicks)")
    }

    /// With a program holding the mouse, SwiftTerm's view keeps every ⌘-press from it and measures
    /// the drag itself: a press that moved more than 3 points opens nothing at its release. The
    /// ⌘-clicks after open both links and send nothing either, and the plain click after that is
    /// reported, so the program held the mouse throughout.
    @Test("with a program holding the mouse, a ⌘-drag from a printed URL or an OSC 8 link opens and sends nothing",
          arguments: TerminalEngineFactory.availableKinds)
    func commandDragFromALinkWhileTheProgramHoldsTheMouse(kind: TerminalEngineKind) async throws {
        let fixture = try CommandClickFixture(kind: kind)
        defer { fixture.tearDown() }
        await fixture.show(CommandClickFixture.twoLinks)
        await fixture.programTakesTheMouse()

        try await fixture.drag(from: fixture.point(column: 14, row: 0), to: fixture.point(column: 20, row: 0))
        try await fixture.drag(from: fixture.point(column: 3, row: 1), to: fixture.point(column: 12, row: 1))
        let openedByDrags = fixture.recorder.opened
        #expect(openedByDrags.isEmpty, "\(kind): the ⌘-drags opened \(openedByDrags)")

        try await fixture.click(column: 14, row: 0)
        try await fixture.click(column: 3, row: 1)
        let openedByClicks = fixture.recorder.opened
        #expect(openedByClicks == CommandClickFixture.twoLinksOpened, "\(kind): \(openedByClicks)")
        let sent = fixture.recorder.sends
        #expect(sent.isEmpty, "\(kind): the ⌘-presses reached the program: \(sent.map(EngineTestSupport.describe))")

        let controlReported = try await fixture.controlClickIsReported()
        #expect(controlReported, "\(kind): the control click was not reported, so the program never held the mouse")
    }

    /// A ⌘-press that moves a point before its release is still a click while a program holds the
    /// mouse: SwiftTerm's view lets it move 3 points. With reporting off the move extends a
    /// selection, and SwiftTerm opens nothing after any selection drag, however short.
    @Test("a ⌘-press on a URL that moves a point opens it only while a program holds the mouse",
          arguments: TerminalEngineFactory.availableKinds, [true, false])
    func commandPressThatMovesAPoint(kind: TerminalEngineKind, programHoldsTheMouse: Bool) async throws {
        let fixture = try CommandClickFixture(kind: kind)
        defer { fixture.tearDown() }
        await fixture.show("see \(CommandClickFixture.linkURL) now")
        if programHoldsTheMouse { await fixture.programTakesTheMouse() }

        let pressed = try fixture.point(column: 14, row: 0)
        try await fixture.drag(from: pressed, to: NSPoint(x: pressed.x + 1, y: pressed.y))

        let opened = fixture.recorder.opened
        let expected: [String] = programHoldsTheMouse ? ["link \(CommandClickFixture.linkURL)"] : []
        #expect(opened == expected, "\(kind), the program holding the mouse \(programHoldsTheMouse): \(opened)")
    }

    /// SwiftTerm's view opens a link at the release only while ⌘ is still held, so a ⌘-press whose
    /// ⌘ is let go before the button opens nothing, and sends a program holding the mouse nothing.
    /// Control: ⌘ held through the release, the same clicks open both links.
    @Test("⌘ let go before the button on a printed URL or an OSC 8 link opens nothing",
          arguments: TerminalEngineFactory.availableKinds, [false, true])
    func commandLetGoBeforeTheButton(kind: TerminalEngineKind, programHoldsTheMouse: Bool) async throws {
        let fixture = try CommandClickFixture(kind: kind)
        defer { fixture.tearDown() }
        await fixture.show(CommandClickFixture.twoLinks)
        if programHoldsTheMouse { await fixture.programTakesTheMouse() }

        try await fixture.click(column: 14, row: 0, releaseFlags: [])
        try await fixture.click(column: 3, row: 1, releaseFlags: [])
        let openedByLetGo = fixture.recorder.opened
        #expect(openedByLetGo.isEmpty, "\(kind): letting ⌘ go before the button opened \(openedByLetGo)")
        if programHoldsTheMouse {
            let sent = fixture.recorder.sends
            #expect(sent.isEmpty, "\(kind): the ⌘-presses reached the program: \(sent.map(EngineTestSupport.describe))")
        }

        try await fixture.click(column: 14, row: 0)
        try await fixture.click(column: 3, row: 1)
        let openedByClicks = fixture.recorder.opened
        #expect(openedByClicks == CommandClickFixture.twoLinksOpened, "\(kind): \(openedByClicks)")
    }

    /// What TBD's own matcher finds opens at the press, on either engine, so a ⌘-drag that starts
    /// on it opens it, once, and selects nothing.
    @Test("a ⌘-drag from a path TBD's matcher finds opens it at the press",
          arguments: TerminalEngineFactory.availableKinds)
    func commandDragFromAMatchedPath(kind: TerminalEngineKind) async throws {
        let fixture = try CommandClickFixture(kind: kind)
        defer { fixture.tearDown() }
        let path = fixture.notesPath
        await fixture.show("see \(path) now")

        try await fixture.drag(from: fixture.point(column: 6, row: 0), to: fixture.point(column: 16, row: 0))

        let opened = fixture.recorder.opened
        #expect(opened == ["file \(path)"], "\(kind): \(opened)")
        let selected = try fixture.hasSelection()
        #expect(!selected, "\(kind): the ⌘-drag that opened the path also selected")
    }

    /// SwiftTerm's view keeps every ⌘-press from a program holding the mouse, one that opens nothing
    /// included: ⌘ is TBD's link modifier, and a mouse report has no bit for it, so the program
    /// would read a plain click. The plain click after is the control.
    @Test("with a program holding the mouse, a ⌘-click on plain text sends it nothing",
          arguments: TerminalEngineFactory.availableKinds)
    func commandClickOnPlainTextSendsNothing(kind: TerminalEngineKind) async throws {
        let fixture = try CommandClickFixture(kind: kind)
        defer { fixture.tearDown() }
        await fixture.show("just some words")
        await fixture.programTakesTheMouse()

        try await fixture.click(column: 2, row: 0)

        let opened = fixture.recorder.opened
        #expect(opened.isEmpty, "\(kind): \(opened)")
        let sent = fixture.recorder.sends
        #expect(sent.isEmpty, "\(kind): the ⌘-click reached the program: \(sent.map(EngineTestSupport.describe))")
        let controlReported = try await fixture.controlClickIsReported()
        #expect(controlReported, "\(kind): the control click was not reported, so the program never held the mouse")
    }
}

// MARK: - Fixture and recorder

/// Records what an engine opens and sends, and answers the panel's focus claim.
@MainActor
private final class CommandClickRecorder: TerminalEngineDelegate {
    /// What opened, in order: `file <path>` for `filePathClicked`, `link <link>` for `openLink`.
    private(set) var opened: [String] = []
    /// Each send, on its own.
    private(set) var sends: [[UInt8]] = []
    /// What `engineMouseDownClaimsFocus` answers.
    var claimsPress = true

    func reset() {
        opened = []
        sends = []
    }

    func engine(_ e: any TerminalEngine, send data: ArraySlice<UInt8>) { sends.append(Array(data)) }
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
    /// The panel's answer: take focus on a claimed press.
    func engineMouseDownClaimsFocus(_ e: any TerminalEngine) -> Bool {
        if claimsPress { e.view.window?.makeFirstResponder(e.view) }
        return claimsPress
    }
    func engineMovedToWindow(_ e: any TerminalEngine) {}
    func engine(_ e: any TerminalEngine, controlModePaste data: Data) -> Bool { false }
}

/// An engine from the factory over a scratch worktree holding `notes.txt`, mounted in an
/// offscreen window, with a `CommandClickRecorder` as its delegate.
@MainActor
private final class CommandClickFixture {
    /// The URL every link fixture points at.
    static let linkURL = "https://example.com/acme"
    /// The URL the OSC 8 link in `twoLinks` points at.
    static let osc8URL = "https://example.com/widgets"
    /// `linkURL` printed on row 0, on columns 4 to 27, and on row 1 an OSC 8 link to `osc8URL`, on
    /// columns 0 to 20, whose text names no file and holds no URL.
    static var twoLinks: String {
        "see \(linkURL) now\r\n\u{1b}]8;;\(osc8URL)\u{1b}\\open the widgets page\u{1b}]8;;\u{1b}\\"
    }
    /// What a ⌘-click on each of `twoLinks`, the printed URL first, opens.
    static var twoLinksOpened: [String] { ["link \(linkURL)", "link \(osc8URL)"] }

    let engine: any TerminalEngine
    let recorder = CommandClickRecorder()
    let window: NSWindow
    /// A scratch directory standing in for the worktree.
    let worktree: URL
    private let suite: TestDefaultsSuite
    private let appearance: AppearanceSettings
    private var nextEventNumber = 1

    /// The absolute path of the worktree's `notes.txt`.
    var notesPath: String { worktree.appendingPathComponent("notes.txt").path }

    /// - Parameter width: the window's width, in points. Wide enough by default for the scratch
    ///   worktree's absolute path to fit on one row.
    init(kind: TerminalEngineKind, width: CGFloat = 1000, routesClicks: Bool = true) throws {
        // Under the run's scratch root, whose path is short and holds only path characters. The
        // per-user `$TMPDIR` can hold an underscore, which ends a path for TBD's matcher.
        let worktree = URL(fileURLWithPath: fencedScratchRoot(prefix: "cmd-click"), isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: worktree.appendingPathComponent("notes.txt"))
        self.worktree = worktree
        // `UserDefaults.standard` on this unbundled executable is the developer's real
        // TBDApp.plist.
        suite = TestDefaultsSuite("TBDAppTests.EngineCommandClick")
        appearance = AppearanceSettings(defaults: suite.defaults)
        engine = TerminalEngineFactory.make(
            kind: kind, font: appearance.font, appearance: appearance,
            configuration: TerminalEngineConfiguration(worktreePath: worktree.path), experimentEnabled: false)
        engine.delegate = recorder
        engine.setClickRouting(enabled: routesClicks)
        window = EngineTestSupport.mount(engine.view, size: NSSize(width: width, height: 400))
        #expect(engine.kind == kind, "asked for \(kind), the factory built \(engine.kind)")
    }

    func tearDown() {
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

    /// A press and its release at the cell at `column`, `row`, ⌘ held unless `flags` says
    /// otherwise, and released with `releaseFlags` held, or `flags` if nil. An `activating` click
    /// is the one AppKit asks the view about first, the click that brings its window forward.
    func click(
        column: Int, row: Int, flags: NSEvent.ModifierFlags = .command,
        releaseFlags: NSEvent.ModifierFlags? = nil, activating: Bool = false
    ) async throws {
        let location = try point(column: column, row: row)
        let number = nextEventNumber
        nextEventNumber += 1
        let down = try mouseEvent(.leftMouseDown, at: location, flags: flags, eventNumber: number)
        if activating {
            let takesIt = engine.view.acceptsFirstMouse(for: down)
            #expect(takesIt, "the view did not take the click that activates its window")
        }
        engine.view.mouseDown(with: down)
        engine.view.mouseUp(with: try mouseEvent(
            .leftMouseUp, at: location, flags: releaseFlags ?? flags, eventNumber: number))
        await EngineTestSupport.settle()
    }

    /// A ⌘-press at the window point `from`, one drag to `to`, and the release there, ⌘ held
    /// throughout.
    func drag(from: NSPoint, to: NSPoint) async throws {
        let number = nextEventNumber
        nextEventNumber += 1
        engine.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: from, flags: .command, eventNumber: number))
        engine.view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: to, flags: .command, eventNumber: number))
        engine.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: to, flags: .command, eventNumber: number))
        await EngineTestSupport.settle()
    }

    /// The program takes the mouse with button-event tracking (1002) and SGR encoding (1006).
    /// Clears what was recorded before.
    func programTakesTheMouse() async {
        engine.feed(Array("\u{1b}[?1002h\u{1b}[?1006h".utf8)[...])
        await EngineTestSupport.settle()
        recorder.reset()
    }

    /// Whether a plain click on a blank cell reaches the program as a press and a release. After a
    /// check that a ⌘-press sent nothing, it shows the program held the mouse throughout.
    func controlClickIsReported() async throws -> Bool {
        let before = recorder.sends.count
        try await click(column: 40, row: 5, flags: [])
        return recorder.sends.count - before == 2
    }

    /// Whether the engine's view holds a selection.
    func hasSelection() throws -> Bool {
        if let view = engine.view as? GhosttyTerminalView {
            return view.terminal.copySelectionText() != nil
        }
        let view = try #require(engine.view as? TBDTerminalView, "the engine's view is a \(type(of: engine.view))")
        return view.selectionActive
    }

    private func mouseEvent(
        _ type: NSEvent.EventType, at location: NSPoint, flags: NSEvent.ModifierFlags, eventNumber: Int
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: eventNumber, clickCount: 1, pressure: 1))
    }
}
