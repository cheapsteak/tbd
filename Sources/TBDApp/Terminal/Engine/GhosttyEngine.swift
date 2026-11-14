import AppKit
import Combine
import Foundation
import os
import SwiftTerm
import TBDGhosttyCore
import TBDGhosttyTerminal
import TBDShared

private let ghosttyEngineLog = Logger(subsystem: "com.tbd.app", category: "terminalEngine")

/// The libghostty terminal engine: one `TBDGhosttyCore.GhosttyTerminal`, the
/// `GhosttyTerminalView` that draws it, and the adapter between them and the
/// coordinators' `TerminalEngine` seam.
///
/// `TBDGhosttyCore` and `TBDGhosttyTerminal` know nothing of the seam. This class
/// is where their API meets TBD's rules, and four of those rules are facts about
/// this emulator:
///
/// - **Callbacks fire inside the parse.** libghostty runs every effect callback
///   on the feeding thread, before `feed` returns, so the snapshot mute is a
///   plain `isMuted` around the feed, lowered on return. Every callback is
///   still hopped to main before it reaches the delegate, the timing the seam
///   promises: a reply reaches `send` one main-queue turn after its `feed`.
/// - **The OSC 7501 probe is answered with TBD's reply, not libghostty's.**
///   libghostty answers `OSC 7501 ; ?` itself whenever it has a program status
///   callback, with `?:states=…:kinds=…`, a reply TBD's own parser and Claude
///   Code's handshake were never written against. `ProgramStatusProbeAnswer`
///   swaps that answer, inside the reply bytes and so in parse order, for
///   `ProgramStatusProtocol.probeReply` while reporting is on, and removes it
///   while reporting is off, when SwiftTerm gives no answer at all.
/// - **Reports arrive parsed.** The engine writes each one back into the wire
///   form TBD forwards (`ProgramStatusPayloadBuilder`), so the daemon parses
///   both engines' reports with the one `ProgramStatusParser`.
/// - **Device attributes are TBD's.** DA1, DA2 and XTVERSION are answered
///   with the frozen bytes in `TerminalDeviceIdentity`, the ones SwiftTerm
///   answers with, so a program sees one terminal whichever engine draws it.
///
/// Only `feed(_:)` runs off main; see `TerminalEngine` for the threading rule.
/// Design: `docs/specs/2026-11-07-libghostty-terminal-engine-design.md`.
@MainActor
final class GhosttyEngine: TerminalEngine {
    let kind: TerminalEngineKind = .ghostty

    /// The emulator. `Sendable`, and called from the IO thread through `feed`.
    nonisolated let terminal: TBDGhosttyCore.GhosttyTerminal
    /// The view this engine owns, typed for tests.
    let terminalView: GhosttyTerminalView

    var view: NSView { terminalView }

    weak var delegate: (any TerminalEngineDelegate)?

    /// Held for the engine's life. The view keeps no copy: none of these
    /// settings change what libghostty does. Mouse reporting is always the
    /// program's own on this engine, which is why only the transports that
    /// allow it (holder panels and local PTYs) build one.
    var configuration: TerminalEngineConfiguration

    /// What the C callbacks, which run on the feeding thread, reach the engine
    /// through.
    nonisolated private let relay: GhosttyEngineRelay

    private var appearanceSubscription: AnyCancellable?

    /// The scrollback a new terminal keeps: SwiftTerm's own default, so the two
    /// engines hand back the same history.
    nonisolated static let scrollbackLines = SwiftTerm.TerminalOptions.default.scrollback

    /// - Throws: `.metalUnavailable` with no Metal device, `.renderInit` when
    ///   the renderer cannot be built, `.terminalInit` when libghostty cannot
    ///   make a terminal. The factory falls back to SwiftTerm on any of them.
    init(
        font: NSFont,
        appearance: AppearanceSettings,
        configuration: TerminalEngineConfiguration
    ) throws(GhosttyError) {
        let relay = GhosttyEngineRelay()
        let terminal = try TBDGhosttyCore.GhosttyTerminal(
            cols: 80, rows: 24, scrollbackLines: Self.scrollbackLines,
            callbacks: Self.callbacks(relay: relay))
        var settings = GhosttyAppearance(settings: appearance)
        settings.font = font
        let view: GhosttyTerminalView
        do {
            view = try GhosttyTerminalView(terminal: terminal, appearance: settings)
        } catch {
            terminal.close()
            throw error
        }
        self.terminal = terminal
        self.terminalView = view
        self.relay = relay
        self.configuration = configuration
        relay.engine = self
        // The grid the terminal starts with is known, not news: without this the
        // first feed would report the 80x24 a terminal is made with as though
        // the program had chosen it, before the view's first layout sizes it.
        rebaselineGrid()
        // Clicks stay the view's own, and it does not take the click that
        // activates its window, until the panel turns routing on.
        view.acceptsActivatingClick = false
        installForwarders()
        appearanceSubscription = appearance.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak appearance] _ in
                guard let self, let appearance else { return }
                self.apply(appearance: appearance)
            }
    }

    // MARK: - Callbacks from the terminal

    /// The terminal's callbacks. Each runs on the feeding thread, inside
    /// `feed`, after libghostty's lock has dropped; each hops to main before
    /// anything reaches the delegate. Static, so no callback can capture the
    /// engine before it exists.
    nonisolated private static func callbacks(relay: GhosttyEngineRelay) -> GhosttyTerminalCallbacks {
        let probeReply = Array(ProgramStatusProtocol.probeReply.utf8)
        return GhosttyTerminalCallbacks(
            writePty: { bytes in
                // Decided here, in parse order, as SwiftTerm decides inside its
                // OSC handler; the reply rides with the replies around it.
                let replacement = relay.gate.isEnabled ? probeReply : nil
                let reply = ProgramStatusProbeAnswer.replacingLibghosttyAnswers(in: bytes, with: replacement)
                guard !reply.isEmpty else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { relay.engine?.deliverReply(reply) }
                }
            },
            bell: {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { relay.engine?.deliverBell() }
                }
            },
            clipboardWrite: { text in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { relay.engine?.deliverClipboardCopy(Data(text.utf8)) }
                }
            },
            desktopNotification: { title, body in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { relay.engine?.deliverNotification(title: title, body: body) }
                }
            },
            programStatus: { status in
                let payload = ProgramStatusPayloadBuilder.payload(for: status)
                let observedAt = Date()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        relay.engine?.deliverProgramStatus(payload, observedAt: observedAt)
                    }
                }
            },
            deviceAttributes: { TerminalDeviceIdentity.deviceAttributes },
            xtversion: { TerminalDeviceIdentity.xtversion })
    }

    private func deliverReply(_ bytes: [UInt8]) {
        // The ingest mute already dropped a preamble's replies in the parser;
        // this guard covers a reply queued by a live feed just before it.
        guard !isIngestingSnapshot else { return }
        delegate?.engine(self, send: bytes[...])
    }

    private func deliverBell() {
        guard !isIngestingSnapshot else { return }
        delegate?.engineBell(self)
    }

    private func deliverClipboardCopy(_ content: Data) {
        guard !isIngestingSnapshot else { return }
        delegate?.engine(self, clipboardCopy: content)
    }

    /// Delivered only while the terminal's window is not key, as
    /// `TBDTerminalView` delivers OSC 777: a notification about a terminal the
    /// user is looking at says nothing they cannot see.
    private func deliverNotification(title: String, body: String) {
        guard !isIngestingSnapshot, terminalView.window?.isKeyWindow != true else { return }
        delegate?.engine(self, notification: title, body: body)
    }

    private func deliverProgramStatus(_ payload: [UInt8], observedAt: Date) {
        guard !isIngestingSnapshot, relay.gate.isEnabled else { return }
        delegate?.engine(self, programStatusPayload: payload, observedAt: observedAt)
    }

    // MARK: - The view's hooks

    /// SwiftTerm's link detection for the ⌘-hover underline, which keeps the screen it last read.
    private let hoverLinks = SwiftTermLinkDetector.HoverLinks()

    private func installForwarders() {
        terminalView.onSend = { [weak self] bytes in
            self?.sendUserInput(bytes)
        }
        terminalView.onSizeChanged = { [weak self] cols, rows in
            guard let self else { return }
            let grid = GhosttyEngineGrid(cols: cols, rows: rows)
            self.relay.grid.record(grid)
            self.reportGrid(grid)
        }
        terminalView.onOpenLink = { [weak self] link in
            guard let self else { return }
            self.delegate?.engine(self, openLink: link, params: [:])
        }
        terminalView.onCommandClickText = { [weak self] clicked in
            self?.commandClickOutcome(on: clicked) ?? .nothing
        }
        // A ⌘-hover underlines what SwiftTerm's link detection finds, as the SwiftTerm view
        // underlines its own matches. TBD's matcher, which a ⌘-click runs first, underlines
        // nothing on either engine.
        terminalView.onCommandHoverText = { [weak self] hovered in
            self?.hoverLinks.textLink(in: hovered)
        }
        terminalView.onCloseTab = { [weak self] in
            guard let self else { return }
            self.delegate?.engineRequestsCloseTab(self)
        }
        terminalView.onReady = { [weak self] in
            guard let self else { return }
            self.delegate?.engineReady(self)
        }
        terminalView.onMovedToWindow = { [weak self] in
            guard let self else { return }
            self.delegate?.engineMovedToWindow(self)
        }
        // The instruments stamp the same points of a draw as SwiftTerm's
        // `viewWillDraw` and draw end, in the same order: the engine's hook,
        // then the latency tap, then the commit probe.
        terminalView.onDrawStart = { [weak self] in
            guard let self else { return }
            self.onDrawStart?()
            if let tap = self.latencyTap {
                // The screen check walks the view hierarchy, so it is taken
                // before the tap stamps the draw under its lock.
                let isOnScreen = TerminalCommitLatencyProbe.isOnScreen(self.terminalView)
                tap.noteDrawWillBegin(isOnScreen: isOnScreen)
            }
            TerminalCommitLatencyProbe.recordEngineDrawWillBegin(view: self.terminalView)
        }
        terminalView.onFrameEncoded = {
            TerminalCommitLatencyProbe.recordEngineFrameDrawn()
        }
    }

    /// What the user typed, clicked, scrolled or pasted, on its way to the
    /// session.
    private func sendUserInput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, !isIngestingSnapshot else { return }
        delegate?.engine(self, send: bytes[...])
    }

    /// The grid last reported to the delegate, so a size the view and a feed
    /// both noticed is reported once.
    private var reportedGrid: GhosttyEngineGrid?

    private func reportGrid(_ grid: GhosttyEngineGrid) {
        guard !isIngestingSnapshot, grid != reportedGrid else { return }
        reportedGrid = grid
        delegate?.engine(self, sizeChanged: grid.cols, rows: grid.rows)
    }

    /// The program changed the grid itself, with DECCOLM (`CSI ? 3 h` once
    /// `CSI ? 40 h` allows it). SwiftTerm reports that as a size change, and so
    /// does this engine, so the pty follows in both.
    ///
    /// The feed posts this a main-queue turn after it read the grid, and the
    /// grid can change again in between: a resize of the view applies its own
    /// grid at once and reports it. So the grid is read again here and the
    /// one reported is the grid as it is now, never the one the feed saw. A
    /// grid the view has already reported is then not reported a second time.
    private func programChangedGrid() {
        let current = terminal.withLocked { GhosttyEngineGrid(cols: $0.cols, rows: $0.rows) }
        guard current.cols > 0, current.rows > 0 else { return }
        relay.grid.record(current)
        reportGrid(current)
    }

    /// Whether click routing is on (`setClickRouting(enabled:)`), which is what makes this a
    /// panel's terminal, one whose ⌘-clicks TBD's own matcher reads.
    private var routesClicks = false

    /// What a ⌘-click on plain text opens, as the SwiftTerm engine finds it, in the same order and
    /// at the same time: TBD's own matcher on the pressed row first, while click routing is on,
    /// which opens at the press (`.opened`); then SwiftTerm's link detection, which opens at the
    /// release (`.opensOnRelease`), as the SwiftTerm view's mouse-up opens it, so a ⌘-drag that
    /// starts on it selects instead. A file goes to `filePathClicked` and the rest to `openLink`,
    /// the calls the SwiftTerm engine makes; its view opens a pull request link itself, where this
    /// engine hands it to the delegate, which opens it the same way.
    ///
    /// The SwiftTerm view consumes the click that activates its window unless TBD's matcher opened
    /// something or an OSC 8 link is under it, so SwiftTerm's detection never sees that click, and
    /// it is not run here either.
    private func commandClickOutcome(on clicked: GhosttyClickedText) -> GhosttyCommandClickOutcome {
        guard let delegate, clicked.rows.indices.contains(clicked.row) else { return .nothing }
        if routesClicks, let target = TerminalCommandClick.target(
            row: clicked.rows[clicked.row].text, column: clicked.column,
            worktreePath: configuration.worktreePath, remoteURL: configuration.remoteURL) {
            switch target {
            case .file(let path):
                ghosttyEngineLog.debug("file-click[mouseDown/path]: \(path, privacy: .public)")
                delegate.engine(self, filePathClicked: path)
            case .url(let url):
                delegate.engine(self, openLink: url.absoluteString, params: [:])
            }
            return .opened
        }
        guard !clicked.activatesWindow, let link = SwiftTermLinkDetector.link(in: clicked) else { return .nothing }
        return .opensOnRelease(open: { [weak self] in
            guard let self else { return }
            ghosttyEngineLog.debug("file-click[mouseUp/detected]: \(link, privacy: .public)")
            self.delegate?.engine(self, openLink: link, params: [:])
        })
    }

    func setClickRouting(enabled: Bool) {
        routesClicks = enabled
        terminalView.acceptsActivatingClick = enabled
        guard enabled else {
            terminalView.onMouseDownClaimFocus = nil
            terminalView.onFirstResponderChanged = nil
            return
        }
        terminalView.onMouseDownClaimFocus = { [weak self] in
            guard let self, let delegate = self.delegate else { return false }
            return delegate.engineMouseDownClaimsFocus(self)
        }
        terminalView.onFirstResponderChanged = { [weak self] focused in
            guard let self else { return }
            self.delegate?.engine(self, focusChanged: focused)
        }
    }

    func setControlModePasteInterception(enabled: Bool) {
        guard enabled else {
            terminalView.onPaste = nil
            return
        }
        terminalView.onPaste = { [weak self] text in
            guard let self, let delegate = self.delegate else { return false }
            return delegate.engine(self, controlModePaste: Data(text.utf8))
        }
    }

    func deliverDroppedText(_ text: String) {
        terminalView.deliverDroppedText(text)
    }

    // MARK: - Input

    nonisolated func feed(_ bytes: ArraySlice<UInt8>) {
        terminal.feed(bytes)
        // DECCOLM changes the grid inside the parse and tells nobody, so the
        // grid is read back after each feed. One lock hold, two reads.
        let grid = terminal.withLocked { GhosttyEngineGrid(cols: $0.cols, rows: $0.rows) }
        guard grid.cols > 0, grid.rows > 0, relay.grid.record(grid) else { return }
        let relay = self.relay
        DispatchQueue.main.async {
            MainActor.assumeIsolated { relay.engine?.programChangedGrid() }
        }
    }

    /// Whether libghostty's parser is between sequences: no escape sequence
    /// and no partial UTF-8 character open (`GhosttyTerminalState`'s
    /// continuation). The holder reader asks before the handback, whose
    /// writer carries an open sequence of up to 64 KiB itself; past that
    /// cap the sequence reads open, and the reader's wait still matters.
    nonisolated var isAtSequenceBoundary: Bool {
        terminal.withLocked { $0.isAtSequenceBoundary }
    }

    /// A CAN, then a full reset (RIS), both muted, so the preamble lands as it
    /// would in a new terminal. Unlike SwiftTerm's, libghostty's reset gives a
    /// used terminal a fresh screen, alternate screen included.
    ///
    /// The reset clears the screen model but leaves libghostty's stream parser
    /// where it was, so a terminal whose output stopped inside a sequence
    /// would let the preamble's first ESC end that sequence on the fresh
    /// screen: a cut OSC 8 would put its link on every cell the preamble
    /// writes. The CAN first returns the parser to ground from any state. It
    /// ends an unfinished OSC or DCS as it stands (a cut DECRQSS answers),
    /// runs a cut kitty graphics APC, drops a cut CSI, and ends a partial
    /// UTF-8 character as U+FFFD at the old cursor. The reset then clears
    /// what those changed on the screen: the link on the pen, the title, the
    /// images, the stray character. Colours a cut OSC 4, 10, 11 or 12 sets
    /// survive the reset, as they would if the preamble's ESC had ended it.
    ///
    /// The mute keeps what the two provoke from the delegate: a reply to a
    /// sequence the CAN ended, and the program status clear libghostty
    /// reports for RIS.
    ///
    /// Two calls rather than one lock hold, because no feed can land between
    /// them: like `ingestSnapshot(_:)`, this runs before live output is wired
    /// to this engine.
    func prepareForPreamble() {
        terminal.isMuted = true
        terminal.feed(Self.cancel[...])
        terminal.reset()
        terminal.isMuted = false
        rebaselineGrid()
    }

    /// CAN, which ends any escape sequence or UTF-8 character in progress.
    private static let cancel: [UInt8] = [0x18]

    /// Depth of the snapshot feeds in flight; see `SwiftTermEngine`.
    private var snapshotIngestDepth = 0

    var isIngestingSnapshot: Bool { snapshotIngestDepth > 0 }

    /// Feeds a preamble with the terminal muted. libghostty runs every callback
    /// inside the parse and drops them all while muted, the queries included,
    /// so the mute can come down as soon as the feed returns: nothing the
    /// preamble provoked is still on its way.
    ///
    /// The precondition is `TerminalEngine`'s: feed the preamble before live
    /// output is wired to this engine, because a live feed parsed while the
    /// mute is up is muted with it.
    func ingestSnapshot(_ data: Data) {
        snapshotIngestDepth += 1
        terminal.isMuted = true
        terminal.feed([UInt8](data)[...])
        terminal.isMuted = false
        // A replayed DECCOLM moved the grid: take the new one as known without
        // reporting it, as SwiftTerm's mute drops its size change.
        rebaselineGrid()
        snapshotIngestDepth -= 1
    }

    private func rebaselineGrid() {
        let grid = terminal.withLocked { GhosttyEngineGrid(cols: $0.cols, rows: $0.rows) }
        relay.grid.record(grid)
    }

    func writeLocalText(_ text: String) {
        terminal.feed(Array(text.utf8)[...])
    }

    // MARK: - Locked reads

    func withScreen<T>(_ body: (any TerminalScreenReader) throws -> T) rethrows -> T {
        let outbox = GhosttyWheelOutbox()
        let value = try terminal.withScreenAccess { access in
            try body(GhosttyScreenReader(access: access, outbox: outbox))
        }
        // Sent after the lock drops, as user input, like the view's own reports.
        if !outbox.bytes.isEmpty { sendUserInput(outbox.bytes) }
        return value
    }

    // MARK: - Handback

    /// Never true: libghostty's writer reads the terminal's modes directly, so
    /// the handback asks the terminal nothing.
    var isCollectingHandbackReplies: Bool { false }

    func handbackPreamble(maxScrollbackLines: Int) async -> Data {
        do {
            return try GhosttySnapshotWriter.snapshot(of: terminal, maxScrollbackLines: maxScrollbackLines)
        } catch {
            ghosttyEngineLog.error(
                "libghostty handback failed, handing back no screen: \(error.localizedDescription, privacy: .public)")
            return Data()
        }
    }

    // MARK: - Geometry

    /// The terminal's own grid, not the view's: after DECCOLM the two differ
    /// until the next layout, and `sizeChanged` promises that this reads the
    /// size it reported.
    var gridSize: (cols: Int, rows: Int) {
        terminal.withLocked { (cols: $0.cols, rows: $0.rows) }
    }

    var cellSize: CGSize { terminalView.cellSize }

    func gridPosition(atWindowLocation point: CGPoint) -> (col: Int, row: Int)? {
        terminalView.gridPosition(atWindowLocation: point)
    }

    // MARK: - Appearance and rendering

    func apply(appearance: AppearanceSettings) {
        terminalView.apply(GhosttyAppearance(settings: appearance))
    }

    /// libghostty always draws with Metal.
    @discardableResult
    func applyRendererPreference(metalEnabled: Bool) -> Bool { true }

    func setProgramStatusReporting(enabled: Bool) {
        relay.gate.set(enabled)
    }

    // MARK: - Instruments

    /// Called as each frame begins encoding, from the view's `onDrawStart`;
    /// see `installForwarders`. The chunks it reports are the ones
    /// `TerminalViewHolder` stamped, as on SwiftTerm.
    var latencyTap: TerminalLatencyTap?

    var onDrawStart: (@MainActor () -> Void)?

    /// Metal's present, from the drawable's presented handler hopped to main;
    /// see `TerminalEngine.onFramePresented` for how that differs from
    /// SwiftTerm's. Installed on the view only while set: the view hops each
    /// present to main only while its own hook is set.
    var onFramePresented: (@MainActor () -> Void)? {
        didSet {
            if onFramePresented == nil {
                terminalView.onFramePresented = nil
            } else {
                terminalView.onFramePresented = { [weak self] in
                    self?.onFramePresented?()
                }
            }
        }
    }
}

// MARK: - The relay

/// What the terminal's callbacks hold. The callbacks are fixed when the
/// terminal is made, before the engine exists, so they reach it through this.
@MainActor
private final class GhosttyEngineRelay {
    weak var engine: GhosttyEngine?
    /// Read on the feeding thread, inside the reply callback.
    nonisolated let gate = ProgramStatusGate()
    /// The grid the engine last knew, written from main and from the feeding
    /// thread.
    nonisolated let grid = GhosttyEngineGridWatch()
}

/// A grid size, as the engine compares them.
private struct GhosttyEngineGrid: Sendable, Equatable {
    let cols: Int
    let rows: Int
}

/// The last grid the engine knew, behind a lock, so the feeding thread can
/// notice a grid the program changed.
private final class GhosttyEngineGridWatch: Sendable {
    private let state = OSAllocatedUnfairLock<GhosttyEngineGrid?>(initialState: nil)

    /// Records `grid` and returns whether it differs from the one known before.
    @discardableResult
    func record(_ grid: GhosttyEngineGrid) -> Bool {
        state.withLock { known in
            guard known != grid else { return false }
            known = grid
            return true
        }
    }
}

/// Wheel reports the reader encoded inside the lock, sent once it drops.
private final class GhosttyWheelOutbox {
    var bytes: [UInt8] = []
}

/// `TerminalScreenReader` over one `withScreenAccess` hold. Exists only inside
/// that call; see `TerminalScreenReader`.
private struct GhosttyScreenReader: TerminalScreenReader {
    let access: GhosttyScreenAccess
    let outbox: GhosttyWheelOutbox

    /// The encoder's answer, the one the view routes clicks and the wheel by,
    /// so the scroll monitor and the view never disagree about where the wheel
    /// goes.
    var mouseReporting: Bool { access.isMouseReporting }

    var isAlternateScreen: Bool { access.state.isAlternateScreen }

    func lineText(row: Int) -> String? {
        guard row >= 0, row < access.state.rows else { return nil }
        return access.state.lineText(row)
    }

    func hyperlink(column: Int, row: Int) -> String? {
        access.hyperlink(column: column, row: row)
    }

    func projection(maxLines: Int) -> ProjectedScreen {
        GhosttyScreenProjection.project(access.state, maxLines: maxLines)
    }

    func styledCapture(maxScrollbackLines: Int) -> String {
        GhosttyScreenProjection.styledCapture(access.state, maxScrollbackLines: maxScrollbackLines)
    }

    func sendWheelReports(lines: Int, column: Int, row: Int) {
        outbox.bytes.append(contentsOf: access.wheelReports(lines: lines, column: column, row: row))
    }
}

// MARK: - Device attributes

/// SwiftTerm's own DA1, DA2 and XTVERSION answers, read from a headless
/// SwiftTerm terminal. The libghostty engine does not answer from these: it
/// answers with `TerminalDeviceIdentity`'s frozen bytes, and the identity
/// tests hold those to these while SwiftTerm is still linked.
enum SwiftTermDeviceIdentity {
    /// SwiftTerm's raw answers, for the identity tests.
    static func rawAnswers() -> (da1: [UInt8], da2: [UInt8], xtversion: [UInt8]) {
        let collector = ReplyCollector()
        let terminal = SwiftTerm.Terminal(delegate: collector)
        func ask(_ query: String) -> [UInt8] {
            collector.bytes = []
            terminal.feed(text: query)
            return collector.bytes
        }
        return (ask("\u{1b}[c"), ask("\u{1b}[>c"), ask("\u{1b}[>0q"))
    }

    /// Holds a headless terminal's replies. `Terminal` keeps its delegate
    /// weakly, so `rawAnswers` holds this for the length of the reads.
    private final class ReplyCollector: TerminalDelegate {
        var bytes: [UInt8] = []

        func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {
            bytes.append(contentsOf: data)
        }
    }
}
