import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// Who gets a click or a drag over a panel terminal: TBD's own selection, or
/// the program running in it.
///
/// Two forwarders can send a click to the program — SwiftTerm's native mouse
/// reporting, gated by `allowMouseReporting`, and TBD's own click passthrough
/// (`TBDTerminalView.handleClickPassthrough`), which stands down whenever
/// reporting is on. A holder panel uses the first and a tmux panel the
/// second, so the property worth pinning is that exactly one of them is live
/// on either transport: a click
/// that reached the program twice, or not at all, would be a silent
/// regression in every mouse-aware program.
///
/// Tier 1: a real `TBDTerminalView` in a real but offscreen, never-key
/// `NSWindow`, with a recording delegate in place of the panel's coordinator —
/// no daemon, no pty. Mouse events are handed straight to the view's
/// overrides, the way AppKit would call them, because nothing dispatches
/// events to a window that is never key. SwiftTerm delivers what the view
/// sends on a later main-queue turn, so each test waits one turn before
/// reading the recorder.
@MainActor
@Suite("Mouse routing: a holder panel hands its clicks to the program")
struct TerminalMouseRoutingTests {

    /// Records everything the view sends toward the session, and every link
    /// SwiftTerm asks the host to open.
    private final class SendRecorder: TerminalViewDelegate {
        var sent: [[UInt8]] = []
        var openedLinks: [String] = []
        func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append([UInt8](data)) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            openedLinks.append(link)
        }
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func bell(source: TerminalView) {}

        /// Every mouse report sent, as text. With SGR encoding (mode 1006) a
        /// report starts `ESC [ <` and arrives in one send.
        var reports: [String] {
            sent.filter { $0.starts(with: [0x1b, 0x5b, 0x3c]) }
                .compactMap { String(bytes: $0, encoding: .utf8) }
        }
    }

    /// A left-button press report, `ESC [ < 0 ; col ; row M`.
    nonisolated private static func isLeftPress(_ report: String) -> Bool {
        report.hasPrefix("\u{1b}[<0;") && report.hasSuffix("M")
    }

    /// A button release report, `ESC [ < 0 ; col ; row m`.
    nonisolated private static func isLeftRelease(_ report: String) -> Bool {
        report.hasPrefix("\u{1b}[<0;") && report.hasSuffix("m")
    }

    /// Reports with ESC spelled out, for failure messages.
    nonisolated private static func readable(_ reports: [String]) -> String {
        reports.map { $0.replacingOccurrences(of: "\u{1b}", with: "ESC") }.description
    }

    /// A terminal view mounted the way a panel mounts one, with the panel's
    /// click routing reduced to "claim the click" — which is what lets a
    /// Cmd+click reach TBD's path handling.
    @MainActor
    private final class Fixture {
        let view: TBDTerminalView
        let window: NSWindow
        let recorder = SendRecorder()
        private let defaults: UserDefaults
        private let suite: TestDefaultsSuite
        private var scratchDirectories: [URL] = []

        init(width: CGFloat = 600) {
            // Enough of an application for AppKit to have an app object;
            // `NSWindow` reaches for one.
            _ = NSApplication.shared

            // AppearanceSettings must never read or write the developer's real
            // TBDApp.plist.
            suite = TestDefaultsSuite("TBDAppTests.TerminalMouseRouting")
            defaults = suite.defaults
            view = TBDTerminalView(
                frame: CGRect(x: 0, y: 0, width: width, height: 300),
                font: TBDTerminalView.defaultMonospaceFont,
                appearance: AppearanceSettings(defaults: defaults))

            // Borderless, far off every plausible display, never ordered front
            // and never made key: the window exists so the view has one.
            window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 300),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let ground = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 300))
            ground.addSubview(view)
            window.contentView = ground

            // `terminalDelegate` is weak; the fixture holds the recorder.
            view.terminalDelegate = recorder
            view.onMouseDownClaimFocus = { true }
        }

        /// What a program sends to take the mouse: normal tracking (1000),
        /// or button-event tracking (1002), which also reports drag motion;
        /// SGR encoding (1006) either way.
        func programTakesTheMouse(reportingDrags: Bool = false) {
            view.feed(text: reportingDrags ? "\u{1b}[?1002h\u{1b}[?1006h" : "\u{1b}[?1000h\u{1b}[?1006h")
        }

        /// Clears the screen and writes `text` on the first row.
        func show(_ text: String) {
            view.feed(text: "\u{1b}[H\u{1b}[2J\(text)")
        }

        /// The URL every link fixture points at.
        static let linkURL = "https://example.com/acme"

        /// The text an OSC 8 link fixture shows.
        static let linkText = "open me"

        /// `linkText` as an OSC 8 hyperlink to `linkURL`.
        static var osc8Link: String {
            "\u{1b}]8;;\(linkURL)\u{1b}\\\(linkText)\u{1b}]8;;\u{1b}\\"
        }

        /// The OSC 8 link alone on the first row, starting at `column`.
        func showOSC8Link(atColumn column: Int = 0) {
            show("\u{1b}[1;\(column + 1)H\(Self.osc8Link)")
        }

        /// SwiftTerm's own cell width, the one its mouse-up hit-tests a
        /// release against. SwiftTerm snaps the font's advance to device
        /// pixels — `(advance * scale).rounded() / scale` in
        /// `computeFontDimensions` — and TBD's `cellDimensions()` mirror does
        /// not, so the two drift apart by a fraction of a cell per column.
        /// SwiftTerm measured while the view had no window; setting the font
        /// again has it measure against this window's scale, which is the
        /// scale this snaps with.
        func swiftTermCellWidth() -> CGFloat {
            let font = view.font
            view.font = font
            let advance = font.advancement(forGlyph: font.glyph(withName: "W")).width
            let scale = window.backingScaleFactor
            return max(1, (advance * scale).rounded() / scale)
        }

        /// Routing for a panel on `transport`, a program holding the mouse, and
        /// a clean recorder — the state every Cmd test starts from.
        func takeTheMouse(transport: TerminalTransport = .holder, reportingDrags: Bool = false) async {
            TerminalPanelRepresentable.applyMouseRouting(to: view, transport: transport)
            programTakesTheMouse(reportingDrags: reportingDrags)
            await mainQueueTurn()
            recorder.sent.removeAll()
        }

        /// A plain click at a blank cell must reach the program as one press
        /// and one release. Run after a zero-report assertion, it shows the
        /// program held the mouse throughout, so "nothing reported" meant
        /// "withheld" rather than "nothing could be".
        func controlClickIsReported() async -> Bool {
            let before = recorder.reports.count
            click(at: point(col: 30, row: 3))
            await mainQueueTurn()
            return recorder.reports.count - before == 2
        }

        /// The center of a grid cell, in view coordinates.
        func point(col: Int, row: Int) -> CGPoint {
            let cell = view.cellDimensions()
            return CGPoint(
                x: cell.width * (CGFloat(col) + 0.5),
                y: view.bounds.height - cell.height * (CGFloat(row) + 0.5))
        }

        /// A mouse event addressed to the fixture's window.
        func mouseEvent(
            _ type: NSEvent.EventType, at point: CGPoint, _ modifiers: NSEvent.ModifierFlags = []
        ) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: view.convert(point, to: nil), modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        func click(at point: CGPoint, _ modifiers: NSEvent.ModifierFlags = []) {
            view.mouseDown(with: mouseEvent(.leftMouseDown, at: point, modifiers))
            view.mouseUp(with: mouseEvent(.leftMouseUp, at: point, modifiers))
        }

        /// One main-queue turn. SwiftTerm hands each send to the delegate with
        /// `DispatchQueue.main.async`, enqueued before this is, and the queue
        /// is serial and FIFO, so every send already made has arrived by the
        /// time this returns.
        func mainQueueTurn() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }

        /// Puts a real file's path on the grid's first row, relative to the
        /// worktree so it fits on one row.
        func showClickablePath() throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("tbd-mouse-routing-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            scratchDirectories.append(directory)
            try Data("x".utf8).write(to: directory.appendingPathComponent("notes.txt"))
            view.worktreePath = directory.path
            view.feed(text: "\u{1b}[H\u{1b}[2J./notes.txt")
        }

        func tearDown() {
            for directory in scratchDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
            window.contentView = nil
            window.close()
            suite.tearDown()
        }
    }

    @Test("reporting turns on only for a holder panel")
    func reportsOnlyForHolder() {
        #expect(TerminalPanelRepresentable.reportsMouseToApps(transport: .holder))
        #expect(!TerminalPanelRepresentable.reportsMouseToApps(transport: .tmux))
    }

    /// Re-application is what carries the transport to a live view: a panel
    /// made before its terminal row loaded read `.tmux` at `makeNSView` and
    /// `.holder` afterwards, and one that reads `.tmux` again must go back
    /// off. A fresh `TerminalView` starts with reporting on, so the first
    /// step proves the apply writes it. The Option bypass is on throughout.
    @Test("re-applying the routing follows the transport")
    func reapplyFollowsTransport() {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let view = fixture.view

        TerminalPanelRepresentable.applyMouseRouting(to: view, transport: .tmux)
        #expect(!view.allowMouseReporting, "a tmux panel took the mouse; tmux holds a mouse mode permanently")
        #expect(view.optionBypassesMouseReporting)

        TerminalPanelRepresentable.applyMouseRouting(to: view, transport: .holder)
        #expect(view.allowMouseReporting, "the panel's row loaded as holder and reporting stayed off")
        #expect(view.optionBypassesMouseReporting)

        TerminalPanelRepresentable.applyMouseRouting(to: view, transport: .tmux)
        #expect(!view.allowMouseReporting, "re-applying a tmux transport left an open panel reporting")
        #expect(view.optionBypassesMouseReporting)
    }

    /// On a holder panel SwiftTerm forwards the click and TBD's passthrough
    /// stands down; on a tmux panel the passthrough forwards and SwiftTerm
    /// only selects. Either way the program sees one press and one release.
    @Test(
        "a plain click reaches a mouse-mode program exactly once",
        arguments: [TerminalTransport.holder, TerminalTransport.tmux])
    func plainClickReachesProgramOnce(transport: TerminalTransport) async {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        TerminalPanelRepresentable.applyMouseRouting(to: fixture.view, transport: transport)
        // Which forwarder is live, so the holder case cannot pass through
        // the passthrough instead of SwiftTerm.
        #expect(fixture.view.allowMouseReporting == (transport == .holder))
        fixture.programTakesTheMouse()
        await fixture.mainQueueTurn()
        fixture.recorder.sent.removeAll()

        fixture.click(at: fixture.point(col: 4, row: 2))
        await fixture.mainQueueTurn()

        let reports = fixture.recorder.reports
        let shown = Self.readable(reports)
        #expect(reports.filter(Self.isLeftPress).count == 1, "presses sent: \(shown)")
        #expect(reports.filter(Self.isLeftRelease).count == 1, "releases sent: \(shown)")
        #expect(reports.count == 2, "reports sent: \(shown)")
    }

    /// TBD consumes a Cmd+click on a path in `mouseDown`, before SwiftTerm
    /// consults `allowMouseReporting`, so handing the program the mouse must
    /// not also hand it this click. The plain click afterwards is the control:
    /// it proves the program holds the mouse and reporting is on, so the empty
    /// recorder above it means "consumed", not "nothing could be reported".
    @Test("a Cmd+click on a path opens it and sends the program nothing")
    func commandClickOpensPathAndReportsNothing() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        var opened: [String] = []
        fixture.view.onFilePathClicked = { opened.append($0) }
        try fixture.showClickablePath()
        TerminalPanelRepresentable.applyMouseRouting(to: fixture.view, transport: .holder)
        fixture.programTakesTheMouse()
        await fixture.mainQueueTurn()
        fixture.recorder.sent.removeAll()

        fixture.click(at: fixture.point(col: 2, row: 0), [.command])
        await fixture.mainQueueTurn()

        #expect(opened.count == 1, "the Cmd+click on a path opened \(opened)")
        #expect(
            fixture.recorder.reports.isEmpty,
            "a Cmd+click TBD handled also reached the program: \(Self.readable(fixture.recorder.reports))")

        fixture.click(at: fixture.point(col: 30, row: 3))
        await fixture.mainQueueTurn()
        let controlReports = Self.readable(fixture.recorder.reports)
        #expect(
            fixture.recorder.reports.count == 2,
            "the control click was not reported, so the program never held the mouse: \(controlReports)")
        #expect(opened.count == 1)
    }

    // MARK: - Cmd belongs to TBD
    //
    // Cmd is TBD's modifier for opening paths and links, and SGR mouse
    // encoding has no bit for it, so a Cmd press SwiftTerm reported would
    // reach the program as a plain click. While a program holds the mouse, no
    // part of a Cmd press — press, drag motion, release — is reported; a link
    // under it still opens, on release.

    /// SwiftTerm opens an OSC 8 link on mouse-up and returns before it would
    /// report the release, so a press it had reported would be left without
    /// one — a program can sit in a held-button state after the link opens.
    /// On a tmux panel reporting is off, nothing is withheld, and the link
    /// opens through SwiftTerm's ordinary press and release.
    @Test(
        "a Cmd+click on an OSC 8 link opens it once and sends the program nothing",
        arguments: [TerminalTransport.holder, TerminalTransport.tmux])
    func commandClickOnOSC8LinkOpensItAndReportsNothing(transport: TerminalTransport) async {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        fixture.showOSC8Link()
        await fixture.takeTheMouse(transport: transport)

        let point = fixture.point(col: 2, row: 0)
        fixture.view.mouseDown(with: fixture.mouseEvent(.leftMouseDown, at: point, [.command]))
        #expect(fixture.view.commandPressWithheld == (transport == .holder))
        fixture.view.mouseUp(with: fixture.mouseEvent(.leftMouseUp, at: point, [.command]))
        await fixture.mainQueueTurn()

        #expect(fixture.recorder.openedLinks == [Fixture.linkURL])
        #expect(
            fixture.recorder.reports.isEmpty,
            "the Cmd+click on an OSC 8 link reached the program: \(Self.readable(fixture.recorder.reports))")
        let controlClickReported = await fixture.controlClickIsReported()
        #expect(controlClickReported, "the control click was not reported, so the program never held the mouse")
    }

    /// The same open-on-release path covers a URL printed as plain text, which
    /// SwiftTerm detects itself.
    @Test("a Cmd+click on a printed URL opens it once and sends the program nothing")
    func commandClickOnPrintedURLOpensItAndReportsNothing() async {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        fixture.show("see \(Fixture.linkURL) now")
        await fixture.takeTheMouse()

        fixture.click(at: fixture.point(col: 8, row: 0), [.command])
        await fixture.mainQueueTurn()

        #expect(fixture.recorder.openedLinks == [Fixture.linkURL])
        #expect(
            fixture.recorder.reports.isEmpty,
            "the Cmd+click on a printed URL reached the program: \(Self.readable(fixture.recorder.reports))")
        let controlClickReported = await fixture.controlClickIsReported()
        #expect(controlClickReported, "the control click was not reported, so the program never held the mouse")
    }

    @Test("a Cmd+click on plain text opens nothing and sends the program nothing")
    func commandClickOnPlainTextReportsNothing() async {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        fixture.show("just some words")
        await fixture.takeTheMouse()

        fixture.click(at: fixture.point(col: 2, row: 0), [.command])
        await fixture.mainQueueTurn()

        #expect(fixture.recorder.openedLinks.isEmpty)
        #expect(
            fixture.recorder.reports.isEmpty,
            "the Cmd+click on plain text reached the program: \(Self.readable(fixture.recorder.reports))")
        let controlClickReported = await fixture.controlClickIsReported()
        #expect(controlClickReported, "the control click was not reported, so the program never held the mouse")
    }

    /// Letting Cmd go before the button means SwiftTerm opens nothing, so its
    /// mouse-up would go on to report a release the program never saw
    /// pressed. Reporting is suppressed for that call, so it reports nothing.
    @Test("Cmd let go before the button on a link: no link, and no orphan release")
    func commandLetGoBeforeReleaseReportsNothing() async {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        fixture.showOSC8Link()
        await fixture.takeTheMouse()

        let point = fixture.point(col: 2, row: 0)
        fixture.view.mouseDown(with: fixture.mouseEvent(.leftMouseDown, at: point, [.command]))
        fixture.view.mouseUp(with: fixture.mouseEvent(.leftMouseUp, at: point))
        await fixture.mainQueueTurn()

        #expect(fixture.recorder.openedLinks.isEmpty)
        #expect(
            fixture.recorder.reports.isEmpty,
            "a release reached the program without its press: \(Self.readable(fixture.recorder.reports))")
        let controlClickReported = await fixture.controlClickIsReported()
        #expect(controlClickReported, "the control click was not reported, so the program never held the mouse")
    }

    /// Button-event tracking (1002) reports drag motion, so this is the case
    /// where a reported Cmd press would also stream motion to the program.
    @Test("a Cmd-drag sends the program no press, no motion and no release")
    func commandDragReportsNothing() async {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        fixture.show("just some words")
        await fixture.takeTheMouse(reportingDrags: true)

        let start = fixture.point(col: 2, row: 0)
        let end = fixture.point(col: 12, row: 0)
        fixture.view.mouseDown(with: fixture.mouseEvent(.leftMouseDown, at: start, [.command]))
        fixture.view.mouseDragged(with: fixture.mouseEvent(.leftMouseDragged, at: end, [.command]))
        fixture.view.mouseUp(with: fixture.mouseEvent(.leftMouseUp, at: end, [.command]))
        await fixture.mainQueueTurn()

        #expect(
            fixture.recorder.reports.isEmpty,
            "the Cmd-drag reached the program: \(Self.readable(fixture.recorder.reports))")
        let controlClickReported = await fixture.controlClickIsReported()
        #expect(controlClickReported, "the control click was not reported, so the program never held the mouse")
    }

    /// SwiftTerm, not TBD, decides whether a withheld release opens a link,
    /// so its highlight mode applies as it does with reporting off. Under
    /// `.always` its `linkVisibleForClick` accepts explicit links only: an
    /// OSC 8 link opens and a URL detected in the text does not. Either way
    /// the release is never reported.
    @Test("under the .always highlight mode a Cmd+click opens an OSC 8 link but not a printed URL, and reports nothing")
    func highlightModeIsSwiftTermsToApply() async {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        fixture.view.linkHighlightMode = .always
        // "open me" on columns 0-6, the printed URL from column 12.
        fixture.show("\(Fixture.osc8Link) see https://example.com/printed now")
        await fixture.takeTheMouse()

        fixture.click(at: fixture.point(col: 2, row: 0), [.command])
        await fixture.mainQueueTurn()
        #expect(fixture.recorder.openedLinks == [Fixture.linkURL], "the OSC 8 link under .always")

        fixture.click(at: fixture.point(col: 16, row: 0), [.command])
        await fixture.mainQueueTurn()
        #expect(fixture.recorder.openedLinks == [Fixture.linkURL], "the printed URL under .always")

        #expect(
            fixture.recorder.reports.isEmpty,
            "a release reached the program without its press: \(Self.readable(fixture.recorder.reports))")
        let controlClickReported = await fixture.controlClickIsReported()
        #expect(controlClickReported, "the control click was not reported, so the program never held the mouse")
    }

    /// SwiftTerm hit-tests a release against its own cells, snapped to device
    /// pixels, and TBD's `cellDimensions()` mirror is not snapped: at the
    /// default Monaco 12 on a 1x or 2x display a cell is 7 points to SwiftTerm
    /// and about 7.2 to the mirror, so by column 100 the two disagree by close
    /// to three cells. Each click lands at the center of a cell as SwiftTerm
    /// counts them — the link's first and last characters, and one cell
    /// beyond each end — so a decision made with TBD's cell math would leave
    /// a highlighted link unopened, or hand SwiftTerm a release with no link
    /// under it to report.
    @Test("past column 100 a Cmd+click opens exactly the link SwiftTerm hit-tests, and reports nothing")
    func commandClickFollowsSwiftTermsCellsAtHighColumns() async {
        let fixture = Fixture(width: 1_000)
        defer { fixture.tearDown() }
        let cellWidth = fixture.swiftTermCellWidth()
        let first = 100
        let last = first + Fixture.linkText.count - 1
        fixture.showOSC8Link(atColumn: first)
        await fixture.takeTheMouse()
        let firstRow = fixture.point(col: 0, row: 0).y

        let clicks: [(col: Int, opens: Bool)] = [
            (first, true), (last, true), (first - 1, false), (last + 1, false),
        ]
        for click in clicks {
            let openedBefore = fixture.recorder.openedLinks.count
            let point = CGPoint(x: cellWidth * (CGFloat(click.col) + 0.5), y: firstRow)
            fixture.click(at: point, [.command])
            await fixture.mainQueueTurn()
            let opened = fixture.recorder.openedLinks.count - openedBefore
            #expect(opened == (click.opens ? 1 : 0), "a Cmd+click at column \(click.col) opened \(opened) links")
        }

        #expect(fixture.recorder.openedLinks == [Fixture.linkURL, Fixture.linkURL])
        #expect(
            fixture.recorder.reports.isEmpty,
            "a Cmd+click past column 100 reached the program: \(Self.readable(fixture.recorder.reports))")
        let controlClickReported = await fixture.controlClickIsReported()
        #expect(controlClickReported, "the control click was not reported, so the program never held the mouse")
    }

    /// The Cmd rule keys on reporting, not on the panel kind, so it holds in a
    /// remote-attach terminal, which always reports the mouse. Mounted the way
    /// `LocalPTYTerminalRepresentable` mounts one: reporting set on directly,
    /// the Option bypass on, and no panel click routing.
    @Test("in a remote-attach terminal, a Cmd+click sends the program nothing")
    func remoteAttachCommandClickReportsNothing() async {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        fixture.view.onMouseDownClaimFocus = nil
        fixture.view.allowMouseReporting = true
        fixture.view.optionBypassesMouseReporting = true
        fixture.show("just some words")
        fixture.programTakesTheMouse()
        await fixture.mainQueueTurn()
        fixture.recorder.sent.removeAll()

        fixture.click(at: fixture.point(col: 2, row: 0), [.command])
        await fixture.mainQueueTurn()
        #expect(
            fixture.recorder.reports.isEmpty,
            "a Cmd+click in a remote-attach terminal reached the program: \(Self.readable(fixture.recorder.reports))")

        fixture.click(at: fixture.point(col: 30, row: 3))
        await fixture.mainQueueTurn()
        let reports = fixture.recorder.reports
        let shown = Self.readable(reports)
        #expect(reports.filter(Self.isLeftPress).count == 1, "control presses sent: \(shown)")
        #expect(reports.filter(Self.isLeftRelease).count == 1, "control releases sent: \(shown)")
        #expect(reports.count == 2, "control reports sent: \(shown)")
    }
}
