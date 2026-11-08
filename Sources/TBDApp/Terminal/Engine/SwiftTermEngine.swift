import AppKit
import Foundation
import SwiftTerm
import TBDTerminalSerialization

/// The SwiftTerm terminal engine: one `TBDTerminalView`, and everything the
/// coordinators used to do to it directly.
///
/// The engine owns the view. It is the view's `TerminalViewDelegate` and the
/// target of every closure hook the view has, and it passes each one on to its
/// `TerminalEngineDelegate`. Three things that used to live in the panel
/// coordinator live here instead, because each is a fact about this emulator
/// rather than about the panel:
///
/// - **The snapshot ingest mute** (`ingestSnapshot(_:)`), which drops the
///   callbacks a replayed preamble provokes.
/// - **The handback** (`handbackPreamble(maxScrollbackLines:)`), with its
///   `DECRQM` probe and the reply collector that catches the answers.
/// - **The locked reader** (`withScreen(_:)`), a value over the
///   `SwiftTerm.Terminal` for the length of one `withTerminal` hold.
///
/// Only `feed(_:)` runs off main; see `TerminalEngine` for the threading rule.
@MainActor
final class SwiftTermEngine: TerminalEngine, TerminalViewDelegate {
    let kind: TerminalEngineKind = .swiftTerm

    /// The view this engine owns, typed for the callers that still need
    /// `TBDTerminalView` itself: tests, and the remote focus registry.
    let terminalView: TBDTerminalView

    var view: NSView { terminalView }

    weak var delegate: (any TerminalEngineDelegate)?

    /// Read once, at creation; the view used it to name itself in the Program
    /// Status Protocol handshake records.
    private let terminalID: UUID?

    /// The view, reachable from the IO thread without crossing into the main
    /// actor. `TerminalView.feed(byteArray:)` is `nonisolated` and runs the
    /// parse under SwiftTerm's terminal lock; this box only carries the
    /// reference, because an `NSView` is not `Sendable`.
    nonisolated private let feedTarget: FeedTarget

    /// Builds a view of its own, at the size both coordinators always built
    /// theirs, and applies `configuration` to it.
    convenience init(font: NSFont, appearance: AppearanceSettings, configuration: TerminalEngineConfiguration) {
        let view = TBDTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            font: font,
            appearance: appearance,
            terminalID: configuration.terminalID
        )
        self.init(view: view, terminalID: configuration.terminalID)
        self.configuration = configuration
    }

    /// Adopts a view somebody else built, and leaves its settings as they are.
    ///
    /// - Parameter terminalID: what the view was built with, reported back in
    ///   `configuration`. The view itself has already used it.
    init(view: TBDTerminalView, terminalID: UUID? = nil) {
        self.terminalView = view
        self.terminalID = terminalID
        self.feedTarget = FeedTarget(view: view)
        view.terminalDelegate = self
        installForwarders()
    }

    var configuration: TerminalEngineConfiguration {
        get {
            TerminalEngineConfiguration(
                terminalID: terminalID,
                worktreePath: terminalView.worktreePath,
                remoteURL: terminalView.remoteURL,
                isCodexTerminal: terminalView.isCodexTerminal,
                allowMouseReporting: terminalView.allowMouseReporting,
                optionBypassesMouseReporting: terminalView.optionBypassesMouseReporting)
        }
        set {
            // `terminalID` is not written: the view read it once, at init.
            terminalView.worktreePath = newValue.worktreePath
            terminalView.remoteURL = newValue.remoteURL
            terminalView.isCodexTerminal = newValue.isCodexTerminal
            terminalView.allowMouseReporting = newValue.allowMouseReporting
            terminalView.optionBypassesMouseReporting = newValue.optionBypassesMouseReporting
        }
    }

    // MARK: - The view's closure hooks

    /// The hooks that are always on. Click routing and paste interception are
    /// not among them, because whether they are installed at all is what the
    /// view acts on: see `setClickRouting(enabled:)` and
    /// `setControlModePasteInterception(enabled:)`.
    private func installForwarders() {
        terminalView.onFilePathClicked = { [weak self] path in
            guard let self else { return }
            self.delegate?.engine(self, filePathClicked: path)
        }
        terminalView.onNotification = { [weak self] title, body in
            guard let self else { return }
            self.delegate?.engine(self, notification: title, body: body)
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
        terminalView.onProgramStatusReport = { [weak self] payload, observedAt in
            guard let self else { return }
            self.delegate?.engine(self, programStatusPayload: payload, observedAt: observedAt)
        }
    }

    func setClickRouting(enabled: Bool) {
        guard enabled else {
            terminalView.onMouseDownClaimFocus = nil
            terminalView.onFocusChange = nil
            return
        }
        terminalView.onMouseDownClaimFocus = { [weak self] in
            guard let self, let delegate = self.delegate else { return false }
            return delegate.engineMouseDownClaimsFocus(self)
        }
        terminalView.onFocusChange = { [weak self] focused in
            guard let self else { return }
            self.delegate?.engine(self, focusChanged: focused)
        }
    }

    func setControlModePasteInterception(enabled: Bool) {
        guard enabled else {
            terminalView.onControlModePaste = nil
            return
        }
        terminalView.onControlModePaste = { [weak self] data in
            guard let self, let delegate = self.delegate else { return false }
            return delegate.engine(self, controlModePaste: data)
        }
    }

    func deliverDroppedText(_ text: String) {
        terminalView.deliverDroppedText(text)
    }

    // MARK: - Input

    nonisolated func feed(_ bytes: ArraySlice<UInt8>) {
        feedTarget.view.feed(byteArray: bytes)
    }

    /// Nothing, on purpose. SwiftTerm's RIS does not give a used terminal a
    /// fresh screen: its reset activates the normal buffer with
    /// `clearAlt: false`, so stale alternate-screen content survives it, and the
    /// preamble's own `?1049h` shows it again. Measured: a preamble into a used
    /// SwiftTerm view reproduced 213 of 213 checks with no reset, and 135 of
    /// 213 with RIS first. The writer's own reset prelude is what makes a
    /// reused SwiftTerm view correct.
    func prepareForPreamble() {}

    /// Depth of the snapshot-preamble feeds currently in flight; > 0 while
    /// `isIngestingSnapshot` is raised. A counter rather than a Bool so two
    /// overlapping feeds cannot have the first one's restore lower the flag
    /// out from under the second. MainActor-confined.
    private var snapshotIngestDepth = 0

    /// True only while a snapshot preamble is being fed.
    ///
    /// A preamble is replayed history, not live output. Its bytes still
    /// *look* live to the emulator, so every query in it produces a reply
    /// and every BEL rings — and the reply path here does not merely echo,
    /// it types into the child's stdin. Feeding a snapshot without this
    /// raised is how a cursor-report ends up as input to somebody's agent.
    var isIngestingSnapshot: Bool { snapshotIngestDepth > 0 }

    /// Feeds a snapshot preamble into the view with every side effect its
    /// bytes imply suppressed: the delegate callbacks TBD owns return early
    /// while `isIngestingSnapshot` is up, and the OSC 777 observer — which is
    /// not a delegate callback and so is not covered by the flag — is
    /// suspended for the duration.
    ///
    /// The flag is lowered a main-queue turn later, not on return, and that
    /// is load-bearing. SwiftTerm hops every delegate callback through
    /// `TerminalView.onMain`, an **unconditional** `DispatchQueue.main.async`
    /// even when the parse already runs on main, so the replies this feed
    /// provokes are queued behind us rather than delivered yet; lowering on
    /// return would leave every one of them unguarded. The parse itself is
    /// synchronous, so everything it enqueued is already on the main queue
    /// by the time this block is appended, and a serial FIFO queue runs all
    /// of it first.
    ///
    /// **Precondition: feed the preamble BEFORE live output is wired to
    /// this view.** The mute is a property of the window, not of the bytes:
    /// nothing here can tell a preamble-provoked callback from a live one,
    /// so *everything* delivered while the flag is up is dropped regardless
    /// of origin — including a batch already parsing on the IO thread when
    /// the flag went up. `dataReceived` feeds synchronously off main, and
    /// SwiftTerm's terminal lock serialises the two parses but not the
    /// order their `onMain` blocks land in, so a live batch's callbacks can
    /// be queued ahead of the restore and swallowed with the rest.
    ///
    /// What that costs if a caller ignores it: a live DA1, DSR or DECRQM
    /// the agent is waiting on is answered by nobody, and the agent waits
    /// forever for a reply that was silently dropped. A live OSC 777 in the
    /// same window is worse than deferred — the observation is nil for the
    /// whole ingest, so the notification is lost outright. Live keystrokes
    /// land in the same hole.
    ///
    /// The window is **not** negligible: it is the preamble parse plus one
    /// main-queue turn, and it is largest exactly when the preamble is a
    /// full scrollback replay, which is the normal case. Order the attach
    /// so the preamble goes in first and the live feed is connected after.
    func ingestSnapshot(_ data: Data) {
        snapshotIngestDepth += 1
        let observation = terminalView.suspendOscObservation()
        terminalView.feed(byteArray: [UInt8](data)[...])
        // NOT a `defer`, however much more obviously correct that reads:
        // the parse returns before SwiftTerm has delivered a single one of
        // the callbacks it queued, so a synchronous restore lowers the flag
        // while every reply is still in flight. Measured against the
        // `defer` shape, most of the tests in `QuietIngestTests` go red —
        // including the replies escaping into the child's stdin, which is
        // the hazard this whole method exists to prevent.
        DispatchQueue.main.async { [weak self] in
            observation.resume()
            self?.snapshotIngestDepth -= 1
        }
    }

    func writeLocalText(_ text: String) {
        terminalView.feed(text: text)
    }

    // MARK: - Locked reads

    func withScreen<T>(_ body: (any TerminalScreenReader) throws -> T) rethrows -> T {
        try terminalView.withTerminal { terminal in
            try body(SwiftTermScreenReader(terminal: terminal))
        }
    }

    // MARK: - Handback

    /// While non-nil, terminal replies are collected here instead of being
    /// routed to the delegate.
    ///
    /// Raised only around the handback's `DECRQM` probe, which is the one
    /// place this app has to *read* what its terminal says rather than
    /// forward it. It is checked before the ingest guard in `send` because the
    /// two mean opposite things: the ingest guard drops replies, and this
    /// one is here to keep them.
    private var modeReplyCollector: [UInt8]?

    var isCollectingHandbackReplies: Bool { modeReplyCollector != nil }

    /// Test seam: raise and lower the handback's reply collector exactly as
    /// `handbackPreamble` does with its own two assignments.
    ///
    /// That method is `async`, and the window it opens is closed by a
    /// main-queue hop inside it, so a test cannot drive it and still observe
    /// the latency probe's `handbackinflight` refusal — which is the refusal
    /// this seam exists to make reachable through the real registered closure.
    var isCollectingModeRepliesForTesting: Bool {
        get { modeReplyCollector != nil }
        set { modeReplyCollector = newValue ? [] : nil }
    }

    /// Serialize this terminal as the byte stream that reconstructs it —
    /// `HolderReader.snapshotPreamble` in the other direction, through the
    /// same `TerminalSnapshotWriter`.
    ///
    /// Two phases, and the hop between them is what makes the first one
    /// work at all:
    ///
    /// 1. **Ask.** `TerminalModeCapture` needs a `DECRQM` answer for every
    ///    mode SwiftTerm keeps private. A view delivers those answers
    ///    through `onMain`, an unconditional `DispatchQueue.main.async`, so
    ///    they have not arrived when `feed` returns. The whole batch goes
    ///    out at once and the answers are read one main-queue turn later:
    ///    main is serial FIFO, the parse enqueued every reply during the
    ///    feed, and a block appended afterwards runs behind all of them.
    ///    This is R16's shape, in the direction R16 said it would also be
    ///    needed. Without the hop every mode reads "reset" — and wraparound
    ///    and cursor-visible are *on* by default, so the daemon would be
    ///    handed a screen with autowrap off and the cursor hidden.
    /// 2. **Walk.** The serialization itself is synchronous inside the
    ///    terminal's own lock, and it must be: the caller has already closed
    ///    the descriptor, so nothing else is feeding this terminal.
    ///
    /// The ingest flag is raised for the second phase because the writer
    /// **feeds this terminal** — the alt-screen toggle, and the queries the
    /// capture would have made — and those callbacks are replies to
    /// questions nobody asked. On a panel being torn down the toggle itself
    /// is harmless (nobody paints it again) and the writer restores what it
    /// can behind a `defer`; the residue it cannot restore — the selected
    /// character set, kitty graphics on the alt buffer, two spurious
    /// `bufferActivated` rounds — is the loss this snapshot path accepted on
    /// the way in as well.
    func handbackPreamble(maxScrollbackLines: Int) async -> Data {
        modeReplyCollector = []
        terminalView.withTerminal { $0.feed(text: HolderHandback.modeProbe) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        let replies = RecordedModeReplies(bytes: modeReplyCollector ?? [])
        modeReplyCollector = nil

        snapshotIngestDepth += 1
        let preamble = terminalView.withTerminal { terminal in
            TerminalSnapshotWriter.snapshot(
                of: terminal, reply: replies,
                maxScrollbackLines: maxScrollbackLines)
        }
        // Lowered a turn later, never on return, for `ingestSnapshot`'s
        // reason: the callbacks the walk provoked are queued behind us and
        // a synchronous restore would leave every one of them unguarded.
        DispatchQueue.main.async { [weak self] in
            self?.snapshotIngestDepth -= 1
        }
        return preamble
    }

    // MARK: - Geometry

    var gridSize: (cols: Int, rows: Int) {
        let dimensions = terminalView.terminalDimensions
        return (dimensions.cols, dimensions.rows)
    }

    var cellSize: CGSize {
        let cell = terminalView.cellDimensions()
        return CGSize(width: cell.width, height: cell.height)
    }

    func gridPosition(atWindowLocation point: CGPoint) -> (col: Int, row: Int)? {
        terminalView.gridPosition(atWindowLocation: point)
    }

    // MARK: - Appearance and rendering

    func apply(appearance: AppearanceSettings) {
        terminalView.applyAppearance(appearance)
    }

    @discardableResult
    func applyRendererPreference(metalEnabled: Bool) -> Bool {
        terminalView.applyMetalRendererPreference(enabled: metalEnabled)
    }

    func setProgramStatusReporting(enabled: Bool) {
        terminalView.programStatusGate.set(enabled)
    }

    // MARK: - Instruments

    var latencyTap: TerminalLatencyTap? {
        get { terminalView.latencyTap }
        set { terminalView.latencyTap = newValue }
    }

    var onDrawStart: (@MainActor () -> Void)? {
        get { terminalView.onDrawStart }
        set { terminalView.onDrawStart = newValue }
    }

    /// Fired when SwiftTerm's Core Graphics `draw` returns for a frame this
    /// view began, through `SwiftTermFramePresentedFanOut`, which shares
    /// SwiftTerm's one process-wide hook with the commit probe.
    var onFramePresented: (@MainActor () -> Void)? {
        get { terminalView.onFramePresented }
        set { terminalView.onFramePresented = newValue }
    }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // The handback's mode probe, and it comes first because it is the
        // one window where a reply is wanted rather than suppressed: these
        // bytes are the terminal answering questions this panel asked about
        // itself, on their way to `RecordedModeReplies`. They are never
        // input for the child — the same rule the ingest guard below
        // enforces for replayed history — so they stop here either way.
        if modeReplyCollector != nil {
            modeReplyCollector?.append(contentsOf: data)
            return
        }
        // This guard precedes all routing: anything arriving while a
        // snapshot preamble is in flight is replayed history or a keystroke
        // aimed at history — neither is input for the live child.
        guard !isIngestingSnapshot else { return }
        delegate?.engine(self, send: data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // A replayed DECCOLM (or any other size-changing sequence in a
        // preamble) must not reach the child's `TIOCSWINSZ` or the daemon's
        // `pane.resize`: the pane's real size is whatever the live view
        // already has.
        guard !isIngestingSnapshot else { return }
        delegate?.engine(self, sizeChanged: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        delegate?.engine(self, openLink: link, params: params)
    }

    func bell(source: TerminalView) {
        // A BEL in replayed history rang minutes ago; ringing it again on
        // restore is noise the user cannot act on.
        guard !isIngestingSnapshot else { return }
        delegate?.engineBell(self)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        // An OSC 52 in replayed history would silently overwrite whatever
        // the user has on the pasteboard right now.
        guard !isIngestingSnapshot else { return }
        delegate?.engine(self, clipboardCopy: content)
    }

    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Carries the engine's view to the IO thread. `@unchecked Sendable` because an
/// `NSView` is not `Sendable`; the only thing called through it off main is
/// `TerminalView.feed(byteArray:)`, which is `nonisolated` and takes SwiftTerm's
/// terminal lock itself.
private final class FeedTarget: @unchecked Sendable {
    let view: TBDTerminalView

    init(view: TBDTerminalView) {
        self.view = view
    }
}

/// `TerminalScreenReader` over a locked `SwiftTerm.Terminal`. Exists only
/// inside one `withTerminal` closure; see `TerminalScreenReader`.
private struct SwiftTermScreenReader: TerminalScreenReader {
    let terminal: SwiftTerm.Terminal

    var mouseReporting: Bool { terminal.mouseMode != .off }

    var isAlternateScreen: Bool { terminal.isCurrentBufferAlternate }

    func lineText(row: Int) -> String? {
        terminal.getLine(row: row)?.translateToString(trimRight: true)
    }

    /// The URI half of the cell's OSC 8 payload. SwiftTerm stores a hyperlink
    /// as `params;uri`, and its own link handling splits it the same way.
    /// `getPayload()` is `Any?` because SwiftTerm also keeps image data there,
    /// so anything that is not a `String` is not a hyperlink.
    func hyperlink(column: Int, row: Int) -> String? {
        guard let line = terminal.getLine(row: row), column >= 0, column < line.count,
              let payload = line[column].getPayload() as? String
        else { return nil }
        let split = payload.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard split.count > 1 else { return nil }
        return String(split[1])
    }

    func projection(maxLines: Int) -> ProjectedScreen {
        TerminalScreenProjection.project(terminal, maxLines: maxLines)
    }

    func styledCapture(maxScrollbackLines: Int) -> String {
        TerminalCellWalk.styledCapture(of: terminal, maxScrollbackLines: maxScrollbackLines)
    }

    /// Exactly the scroll monitor's reports: button 4 for up, 5 for down, one
    /// event per line.
    func sendWheelReports(lines: Int, column: Int, row: Int) {
        guard lines != 0 else { return }
        let buttonFlags = terminal.encodeButton(
            button: lines > 0 ? 4 : 5, release: false, shift: false, meta: false, control: false)
        for _ in 0..<abs(lines) {
            terminal.sendEvent(buttonFlags: buttonFlags, x: column, y: row)
        }
    }
}
