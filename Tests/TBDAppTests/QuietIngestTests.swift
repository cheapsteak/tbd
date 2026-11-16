import AppKit
import Darwin
import Foundation
import SwiftTerm
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// A snapshot preamble is *replayed history*, but its bytes look live to the
/// emulator. This suite drives `Coordinator.feedSnapshot` on the production
/// wiring — a real `TBDTerminalView` inside a real `SwiftTermEngine` whose
/// delegate is a real `Coordinator`, exactly as `makeNSView` wires one — and
/// asserts on **what did not happen**: no bytes reached the session, no ring,
/// no pasteboard write, no `TIOCSWINSZ`, no notification.
///
/// Every one of those is an assertion about an absence, so every test carries a
/// positive control on the same path: the same bytes fed **live** must produce
/// the effect the ingest arm requires to be missing. Without that control a
/// broken fixture — an escape sequence this emulator ignores, a probe wired to
/// nothing — reads as a pass.
///
/// **The pty is real.** `send`'s only observable effect is a write to the
/// panel's own duplicate of the session's pty, and a panel that never attached
/// has nowhere to write — so a coordinator with no pty would report "no bytes
/// escaped" for the wrong reason. The harness therefore attaches the
/// coordinator through the production attach path (`startHolderClient`, with a
/// stub standing in for the daemon's two attach RPCs) to a real pty pair
/// (`RawPTYPair`), and reads what the panel wrote off the session's end. The
/// pty's window size is also the witness for the resize guard. No child
/// process is started.
///
/// **Timing is the subtle part.** SwiftTerm hops every `TerminalViewDelegate`
/// callback through `TerminalView.onMain`, an unconditional
/// `DispatchQueue.main.async` even when the parse already runs on main. So a
/// reply provoked by `feed` is not delivered inside `feed` — it is queued
/// behind it. That is why `feedSnapshot` lowers its flag from a main-queue
/// block rather than on return, and why every assertion here runs after
/// `settle()`.
///
/// Nothing here talks to a live daemon: any RPC the wiring under test makes
/// goes to `TBD_SOCKET_PATH`, which `scripts/test.sh` fences onto a scratch
/// path with no listener.
///
/// The suite limit is a hang guard — every wait here is bounded on its own, and
/// the limit exists so a `settle()` that never settles is a named red rather
/// than a silent stall. It takes the shared dial rather than a number of its
/// own: see `.fastPassBounded` in `Tests/TestSupport/ClockTestSupport.swift`.
@MainActor
@Suite("Quiet snapshot ingest", .fastPassBounded)
struct QuietIngestTests {

    @Test("A terminal query inside a snapshot produces no outgoing bytes")
    func queriesAreNotAnswered() async throws {
        let harness = try await makeCoordinatorHarness()
        defer { harness.tearDown() }
        // DA1, DSR cursor-position and a DECRQM — all reply-producing.
        let snapshot = Data("\u{1b}[c\u{1b}[6n\u{1b}[?7$p".utf8)
        harness.coordinator.feedSnapshot(snapshot, into: harness.engine)
        await harness.settle()
        #expect(harness.sentBytes.isEmpty, "replies escaped into the session's pty")

        // Positive control: the same queries fed live are answered on the same
        // pty, so the write path is real and the fixture bytes provoke replies.
        harness.terminalView.feed(byteArray: [UInt8](snapshot)[...])
        let answered = await harness.waitUntil { !harness.sentBytes.isEmpty }
        #expect(answered, "live queries must reach the session's pty")
    }

    @Test("A BEL in a snapshot does not ring")
    func bellIsSilent() async throws {
        let harness = try await makeCoordinatorHarness()
        defer { harness.tearDown() }
        harness.coordinator.feedSnapshot(Data("hello\u{07}".utf8), into: harness.engine)
        await harness.settle()
        #expect(harness.beepCount == 0)

        // Positive control: the same BEL fed live rings, so both the seam and
        // the fixture bytes are real. Re-fed on a loop because SwiftTerm
        // coalesces bells 100 ms apart — and the suppressed one above still
        // consumed that window, since `BellPolicy` runs before the delegate.
        // Re-fed until the coalescing window has passed, and bounded as a
        // whole by the shared saturated-pass budget rather than by an iteration
        // count: 0.3 s is one re-feed interval, not a hang guard, and twenty of
        // them is a 6 s ceiling on a positive assertion in a pass whose median
        // per-test latency is an order of magnitude larger.
        var rang = false
        let end = ContinuousClock.now + TestDeadlines.saturatedPass
        while !rang, ContinuousClock.now < end {
            harness.terminalView.feed(text: "\u{07}")
            rang = await harness.waitUntil({ harness.beepCount >= 1 }, deadline: 0.3)
        }
        #expect(rang, "a live BEL must still ring")
    }

    /// The bell guard's *premise*, pinned separately from the guard itself.
    ///
    /// `bellIsSilent` above shows the ring is suppressed; this shows why it can
    /// be. A BEL inside a snapshot reaches the delegate a main-queue turn
    /// *after* the feed returned, with the flag still raised. Lower the flag on
    /// return — the obvious way to write `feedSnapshot`, and the way it was
    /// first drafted — and this goes red while the guard in `bell` stays
    /// untouched. The two tests fail to different mutations on purpose.
    @Test("A BEL in a snapshot reaches the delegate while the ingest flag is still raised")
    func bellArrivesDuringIngest() async throws {
        let harness = try await makeCoordinatorHarness()
        defer { harness.tearDown() }
        let spy = RecordingTerminalViewDelegate()
        let coordinator = harness.coordinator
        spy.onBell = { spy.flagWhenBellArrived = coordinator.isIngestingSnapshot }
        harness.terminalView.terminalDelegate = spy
        harness.coordinator.feedSnapshot(Data("hello\u{07}".utf8), into: harness.engine)
        let rang = await harness.waitUntil { spy.bells == 1 }
        harness.terminalView.terminalDelegate = harness.engine
        #expect(rang, "the BEL fixture must reach the delegate at all")
        #expect(spy.flagWhenBellArrived == true,
                "the flag was already down when the bell landed")
    }

    /// The payload is a per-run marker rather than a counter comparison:
    /// `NSPasteboard.general.changeCount` is machine-global and moves whenever
    /// anything on the box copies, which reddened this test on a shared machine
    /// with the guard perfectly intact. What the marker asks is narrower and
    /// unspoofable — did *this* OSC 52 land on the pasteboard.
    @Test("An OSC 52 in a snapshot does not touch the pasteboard")
    func clipboardUntouched() async throws {
        let harness = try await makeCoordinatorHarness()
        defer { harness.tearDown() }
        let marker = "tbd-quiet-ingest-\(UUID().uuidString)"
        let osc52 = Data(
            "\u{1b}]52;c;\(Data(marker.utf8).base64EncodedString())\u{07}".utf8)
        harness.coordinator.feedSnapshot(osc52, into: harness.engine)
        await harness.settle()
        #expect(NSPasteboard.general.string(forType: .string) != marker,
                "a replayed OSC 52 overwrote the user's pasteboard")

        // Positive control: prove the fixture bytes really do provoke
        // `clipboardCopy`. It listens with a spy delegate rather than the
        // coordinator, because the production callback would clobber the
        // developer's real pasteboard — the one side effect a test may not
        // reproduce in order to prove it can be suppressed.
        let spy = RecordingTerminalViewDelegate()
        harness.terminalView.terminalDelegate = spy
        harness.terminalView.feed(byteArray: [UInt8](osc52)[...])
        let copied = await harness.waitUntil { spy.clipboardCopies == 1 }
        harness.terminalView.terminalDelegate = harness.engine
        #expect(copied, "the OSC 52 fixture must reach clipboardCopy at all")
        #expect(NSPasteboard.general.string(forType: .string) != marker,
                "the spy arm must not write either")
    }

    /// A replayed DECCOLM must not resize the session's pty.
    ///
    /// `CSI ? 40 h` is what enables DECCOLM in this emulator (xterm's
    /// `allowC132`); `CSI ? 3 h` then resizes the buffer to 132 columns and
    /// notifies the delegate — which is where the `TIOCSWINSZ` lives. The
    /// session's pty is the witness.
    @Test("A resize sequence in a snapshot does not resize the session's pty")
    func resizeIsNotPropagated() async throws {
        let harness = try await makeCoordinatorHarness()
        defer { harness.tearDown() }
        // The baseline is the width the harness started the session at, read
        // rather than assumed, so a layout pass that moved it is caught here.
        await harness.settle()
        let baseline = harness.ptyColumns()
        #expect(baseline > 0)
        #expect(baseline != 132, "a replayed DECCOLM needs a column count to move from")
        #expect(baseline != 80, "the control below needs a column count to move to")

        harness.coordinator.feedSnapshot(
            Data("\u{1b}[?40h\u{1b}[?3h".utf8), into: harness.engine)
        await harness.settle()
        #expect(harness.ptyColumns() == baseline,
                "a replayed DECCOLM issued a real TIOCSWINSZ")

        // Positive control: live, the same mechanism does resize the pty. (The
        // DECCOLM above reset `allowC132`, so re-enable it.)
        harness.terminalView.feed(text: "\u{1b}[?40h\u{1b}[?3l")
        let resized = await harness.waitUntil { harness.ptyColumns() == 80 }
        #expect(resized, "a live DECCOLM must still reach TIOCSWINSZ")
    }

    @Test("An OSC 777 in a snapshot raises no notification")
    func notificationsAreSuppressed() async throws {
        let harness = try await makeCoordinatorHarness()
        defer { harness.tearDown() }
        let osc777 = Data("\u{1b}]777;notify;Title;Body\u{07}".utf8)
        harness.coordinator.feedSnapshot(osc777, into: harness.engine)
        await harness.settle()
        #expect(harness.notificationCount == 0)

        // Positive control: the observation is reinstalled afterwards, so the
        // same bytes fed live do notify.
        harness.terminalView.feed(byteArray: [UInt8](osc777)[...])
        let notified = await harness.waitUntil { harness.notificationCount == 1 }
        #expect(notified, "the OSC 777 observation must be restored after ingest")
    }

    @Test("The flag is lowered afterwards, so live output behaves normally")
    func flagIsRestored() async throws {
        let harness = try await makeCoordinatorHarness()
        defer { harness.tearDown() }
        harness.coordinator.feedSnapshot(Data("x".utf8), into: harness.engine)
        await harness.settle()
        #expect(!harness.coordinator.isIngestingSnapshot)
        harness.terminalView.feed(text: "\u{1b}[6n")
        let answered = await harness.waitUntil { !harness.sentBytes.isEmpty }
        #expect(answered, "live queries must still be answered")
    }
}

// MARK: - Harness

/// A panel wired the way `TerminalPanelRepresentable.makeNSView` wires one and
/// attached the way `startHolderClient` attaches one, plus the probes that make
/// each suppressed side effect observable.
@MainActor
final class QuietIngestHarness {
    /// The width the harness starts the session at. Deliberately neither 80
    /// nor 132, so a DECCOLM in either direction shows up in the pty's window
    /// size.
    static let initialPtyColumns: UInt16 = 200

    let appState: AppState
    let coordinator: TerminalPanelRepresentable.Coordinator
    let engine: SwiftTermEngine
    let terminalView: TBDTerminalView
    let terminalID: UUID

    /// The session's pty. The panel writes through its own duplicate of the
    /// master; the session's end is where those writes arrive.
    private let pty: RawPTYPair
    private let defaultsSuite: TestDefaultsSuite
    private let notifications = MainCounter()
    private let beeps = MainCounter()
    private var received: [UInt8] = []

    init(
        appState: AppState,
        coordinator: TerminalPanelRepresentable.Coordinator,
        engine: SwiftTermEngine,
        pty: RawPTYPair,
        terminalID: UUID,
        defaultsSuite: TestDefaultsSuite
    ) {
        self.appState = appState
        self.coordinator = coordinator
        self.engine = engine
        self.terminalView = engine.terminalView
        self.pty = pty
        self.terminalID = terminalID
        self.defaultsSuite = defaultsSuite
        // Counted where production delivers a notification, the coordinator's
        // own hook, so the count rides view -> engine -> coordinator.
        let counter = notifications
        coordinator.onTerminalNotification = { _, _ in counter.increment() }
        let bells = beeps
        coordinator.ringBell = { bells.increment() }
    }

    /// Rings counted through the coordinator's injected `ringBell` seam —
    /// `NSSound.beep()` itself is unobservable (a pure Swift shim in the AppKit
    /// overlay, with no `+[NSSound beep]` in the Objective-C runtime to
    /// swizzle, checked at runtime rather than assumed).
    var beepCount: Int { beeps.value }

    /// Every byte the panel wrote to the session's pty since the harness was
    /// built, read off the session's end. The slave is in raw mode, so nothing
    /// is echoed back and nothing is held for a newline: a non-empty buffer
    /// means bytes escaped.
    var sentBytes: [UInt8] {
        while true {
            let chunk = pty.drainSession(64 * 1024)
            if chunk.isEmpty { break }
            received.append(contentsOf: chunk)
        }
        return received
    }

    /// Forgets what the attach itself wrote, so `sentBytes` covers only what a
    /// test provoked.
    func discardSentBytes() {
        _ = sentBytes
        received.removeAll()
    }

    var notificationCount: Int { notifications.value }

    /// The pty's current column count: what `sizeChanged`'s `TIOCSWINSZ` would
    /// have changed.
    func ptyColumns() -> UInt16 {
        var size = winsize()
        guard ioctl(pty.ptyFD, TIOCGWINSZ, &size) == 0 else { return 0 }
        return size.ws_col
    }

    /// Sets the session's width from the session's side of the panel, without
    /// telling the view.
    func setSessionColumns(_ columns: UInt16) {
        var size = winsize(ws_row: 24, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(pty.ptyFD, TIOCSWINSZ, &size)
    }

    /// Lets every deferred callback land: five main-queue turns with a short
    /// real pause between them. The main-queue turns are what the delegate hops
    /// need (they are FIFO behind the feed); the pauses cover the two paths
    /// that leave the main queue — the OSC observation's private serial queue,
    /// and the write that lands on the session's end behind `sentBytes`.
    func settle() async {
        for _ in 0..<5 { await hop() }
    }

    /// Polls `condition` until it holds or the deadline passes. Used only by
    /// positive controls, where `false` is a real failure and not a wait.
    /// The default deadline is only ever *spent* by a failing control, and it
    /// is the shared saturated-pass budget rather than a number chosen here:
    /// this suite runs in the fast parallel pass, where a test doing 1.5 s of
    /// work has been measured taking 106 s of wall time. A caller that passes
    /// its own, shorter window is bounding one attempt of a retry loop, not
    /// guarding a hang.
    func waitUntil(
        _ condition: () -> Bool,
        deadline: TimeInterval = TestDeadlines.saturatedPassSeconds
    ) async -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return true }
            await hop()
        }
        return condition()
    }

    private func hop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                continuation.resume()
            }
        }
    }

    func tearDown() {
        coordinator.onTerminalNotification = nil
        terminalView.terminalDelegate = nil
        // Stops the reader, closes the panel's write duplicate and hands the
        // attach back through the stub. The fixture's own ends close after.
        coordinator.cleanup()
        pty.close()
        defaultsSuite.tearDown()
    }
}

/// Builds a coordinator on the production wiring, attached to a real pty, with
/// a probe for each side effect a snapshot must not fire.
@MainActor
func makeCoordinatorHarness() async throws -> QuietIngestHarness {
    // Isolated defaults: `UserDefaults.standard` on this unbundled executable is
    // the developer's real TBDApp.plist.
    let suite = TestDefaultsSuite("TBDAppTests.QuietIngest")
    // Until the harness owns them, a throw below must still release the suite
    // and the pty: the harness's `tearDown` is the only other place they go.
    var handedToHarness = false
    defer { if !handedToHarness { suite.tearDown() } }
    let defaults = suite.defaults
    let appState = AppState(userDefaults: defaults)

    // The attach finds its worktree through the row AppState holds. A holder
    // row carries empty tmux coordinates by construction.
    let worktreeID = UUID()
    let terminalID = UUID()
    appState.terminals[worktreeID] = [Terminal(
        id: terminalID,
        worktreeID: worktreeID,
        tmuxWindowID: "",
        tmuxPaneID: "",
        label: "Shell",
        kind: .shell,
        transport: .holder
    )]

    // The session's pty, and the descriptor the stub vends: a duplicate of its
    // master, `O_NONBLOCK` as the daemon's vend is (the flag rides the
    // duplicate). Close-on-exec from creation, because sibling suites in this
    // process spawn children, and one that inherited the vended end would hold
    // the session open past the panel.
    let pty = try RawPTYPair()
    defer { if !handedToHarness { pty.close() } }
    let vended = fcntl(pty.ptyFD, F_DUPFD_CLOEXEC, 0)
    try #require(vended >= 0, "could not duplicate the fixture pty (errno \(errno))")

    let view = TBDTerminalView(
        frame: CGRect(x: 0, y: 0, width: 600, height: 300),
        font: TBDTerminalView.defaultMonospaceFont,
        appearance: AppearanceSettings(defaults: defaults)
    )

    let coordinator = TerminalPanelRepresentable.Coordinator()
    coordinator.appState = appState
    coordinator.panelID = terminalID
    coordinator.holderAttachClient = QuietIngestStubAttach(
        attachment: HolderAttachment(ptyFD: vended, generation: 7, snapshotPreamble: Data()))
    let engine = SwiftTermEngine(view: view)
    // As `makeNSView` wires them, before the attach.
    engine.delegate = coordinator
    coordinator.engine = engine
    await coordinator.startHolderClient(engine: engine)

    let harness = QuietIngestHarness(
        appState: appState,
        coordinator: coordinator,
        engine: engine,
        pty: pty,
        terminalID: terminalID,
        defaultsSuite: suite
    )
    handedToHarness = true
    // What the attach wrote, if anything, is not what any test is about.
    await harness.settle()
    harness.discardSentBytes()
    // The attach set the session to the view's grid. Start it instead at a
    // width that is neither 80 nor 132, so a DECCOLM in either direction shows
    // up in the pty's window size, as a session another viewer sized would.
    harness.setSessionColumns(QuietIngestHarness.initialPtyColumns)
    return harness
}

// MARK: - Probes

/// Stands in for the daemon's attach RPCs, handing over a descriptor the
/// harness can read.
private struct QuietIngestStubAttach: HolderAttaching {
    let attachment: HolderAttachment

    func attach(
        worktreeID: UUID, paneID: String, terminalID: UUID, attachSeq: UInt64,
        grid: (cols: Int, rows: Int)?
    ) async throws -> HolderAttachment { attachment }

    func ready(
        worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64
    ) async throws {}

    func detach(
        worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64,
        snapshotPreamble: Data
    ) async throws {}
}

/// A `TerminalViewDelegate` that only counts, for the control arm that may not
/// run the production callback.
final class RecordingTerminalViewDelegate: TerminalViewDelegate {
    private(set) var clipboardCopies = 0
    private(set) var bells = 0
    /// Set by `onBell` at the moment the bell callback runs.
    var flagWhenBellArrived: Bool?
    var onBell: (() -> Void)?

    func clipboardCopy(source: TerminalView, content: Data) { clipboardCopies += 1 }

    func bell(source: TerminalView) {
        bells += 1
        onBell?()
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Main-thread counter for the OSC 777 observer, which delivers on main.
@MainActor
final class MainCounter {
    private(set) var value = 0

    nonisolated func increment() {
        MainActor.assumeIsolated { value += 1 }
    }
}
