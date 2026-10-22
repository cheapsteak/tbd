import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import TBDApp
import TBDShared

/// Who gets a click or a drag over a panel terminal: TBD's own selection, or
/// the program running in it.
///
/// Two forwarders can send a click to the program — SwiftTerm's native mouse
/// reporting, gated by `allowMouseReporting`, and TBD's own click passthrough
/// (`TBDTerminalView.handleClickPassthrough`), which stands down whenever
/// reporting is on. "Send clicks and drags to apps that use the mouse" moves a
/// holder panel from the second to the first, so the property worth pinning is
/// that exactly one of them is live in either state of the toggle: a click
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
@Suite("Mouse routing: the toggle hands a holder panel's clicks to the program")
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
        private let suiteName: String
        private var scratchDirectories: [URL] = []

        init() {
            // Enough of an application for AppKit to have an app object;
            // `NSWindow` reaches for one.
            _ = NSApplication.shared

            // AppearanceSettings must never read or write the developer's real
            // TBDApp.plist.
            suiteName = "TBDAppTests.TerminalMouseRouting.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            view = TBDTerminalView(
                frame: CGRect(x: 0, y: 0, width: 600, height: 300),
                font: TBDTerminalView.defaultMonospaceFont,
                appearance: AppearanceSettings(defaults: defaults))

            // Borderless, far off every plausible display, never ordered front
            // and never made key: the window exists so the view has one.
            window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: 600, height: 300),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let ground = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
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

        /// An OSC 8 hyperlink over "open me" at the start of the first row.
        func showOSC8Link() {
            show("\u{1b}]8;;\(Self.linkURL)\u{1b}\\open me\u{1b}]8;;\u{1b}\\")
        }

        /// Routing on for a holder panel, a program holding the mouse, and a
        /// clean recorder — the state every Cmd test starts from.
        func takeTheMouse(forwardMouseToApps: Bool = true, reportingDrags: Bool = false) async {
            TerminalPanelRepresentable.applyMouseRouting(
                to: view, forwardMouseToApps: forwardMouseToApps, transport: .holder)
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
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    @Test("reporting turns on only for a holder panel with the toggle on")
    func reportsOnlyForHolderWithFlagOn() {
        #expect(TerminalPanelRepresentable.reportsMouseToApps(forwardMouseToApps: true, transport: .holder))
        #expect(!TerminalPanelRepresentable.reportsMouseToApps(forwardMouseToApps: true, transport: .tmux))
        #expect(!TerminalPanelRepresentable.reportsMouseToApps(forwardMouseToApps: false, transport: .holder))
        #expect(!TerminalPanelRepresentable.reportsMouseToApps(forwardMouseToApps: false, transport: .tmux))
    }

    /// Re-application is what carries both inputs to a live view: the toggle
    /// changing in Settings, and a panel made before its terminal row loaded,
    /// whose transport read `.tmux` at `makeNSView` and `.holder` afterwards.
    /// A fresh `TerminalView` starts with reporting on, so the first step
    /// proves the apply writes it.
    @Test("re-applying the routing follows the transport and the toggle")
    func reapplyFollowsTransportAndFlag() {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let view = fixture.view

        TerminalPanelRepresentable.applyMouseRouting(
            to: view, forwardMouseToApps: true, transport: .tmux)
        #expect(!view.allowMouseReporting, "a tmux panel took the mouse; tmux holds a mouse mode permanently")
        #expect(view.optionBypassesMouseReporting)

        TerminalPanelRepresentable.applyMouseRouting(
            to: view, forwardMouseToApps: true, transport: .holder)
        #expect(view.allowMouseReporting, "the panel's row loaded as holder and reporting stayed off")
        #expect(view.optionBypassesMouseReporting)

        TerminalPanelRepresentable.applyMouseRouting(
            to: view, forwardMouseToApps: false, transport: .holder)
        #expect(!view.allowMouseReporting, "turning the toggle off left an open holder panel reporting")
        #expect(!view.optionBypassesMouseReporting)
    }

    /// With the toggle on SwiftTerm forwards the click and TBD's passthrough
    /// stands down; with it off the passthrough forwards and SwiftTerm only
    /// selects. Either way the program sees one press and one release.
    @Test("a plain click reaches a mouse-mode program exactly once", arguments: [true, false])
    func plainClickReachesProgramOnce(forwardMouseToApps: Bool) async {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        TerminalPanelRepresentable.applyMouseRouting(
            to: fixture.view, forwardMouseToApps: forwardMouseToApps, transport: .holder)
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
        TerminalPanelRepresentable.applyMouseRouting(
            to: fixture.view, forwardMouseToApps: true, transport: .holder)
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
    /// With the toggle off reporting is off, nothing is withheld, and the link
    /// opens through SwiftTerm's ordinary press and release.
    @Test("a Cmd+click on an OSC 8 link opens it once and sends the program nothing", arguments: [true, false])
    func commandClickOnOSC8LinkOpensItAndReportsNothing(forwardMouseToApps: Bool) async {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        fixture.showOSC8Link()
        await fixture.takeTheMouse(forwardMouseToApps: forwardMouseToApps)

        let point = fixture.point(col: 2, row: 0)
        fixture.view.mouseDown(with: fixture.mouseEvent(.leftMouseDown, at: point, [.command]))
        #expect(fixture.view.commandPressWithheld == forwardMouseToApps)
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
    /// pressed. The release is consumed instead.
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

    /// The release goes to SwiftTerm only when its mouse-up will open a link,
    /// and that prediction holds for the default `.hoverWithModifier`
    /// highlight mode alone. Under `.always` SwiftTerm opens no printed URL,
    /// so handing it the release would report it; it is consumed instead.
    @Test("under another link highlight mode the release is consumed, never reported")
    func commandReleaseUnderAnotherHighlightModeIsConsumed() async {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        fixture.view.linkHighlightMode = .always
        fixture.show("see \(Fixture.linkURL) now")
        await fixture.takeTheMouse()

        fixture.click(at: fixture.point(col: 8, row: 0), [.command])
        await fixture.mainQueueTurn()

        #expect(
            fixture.recorder.reports.isEmpty,
            "a release reached the program without its press: \(Self.readable(fixture.recorder.reports))")
        let controlClickReported = await fixture.controlClickIsReported()
        #expect(controlClickReported, "the control click was not reported, so the program never held the mouse")
    }
}
