import AppKit
import Darwin
import Foundation
import SwiftTerm
import Testing
@testable import TBDApp
import TBDShared

/// A snapshot preamble is *replayed history*, but its bytes look live to the
/// emulator. This suite drives `Coordinator.feedSnapshot` on the production
/// wiring — a real `TBDTerminalView` whose `terminalDelegate` is a real
/// `Coordinator`, exactly as `makeNSView` wires one — and asserts on **what did
/// not happen**: no bytes reached the child, no interrupt was raised, no
/// pasteboard write, no `TIOCSWINSZ`, no notification.
///
/// Every one of those is an assertion about an absence, so every test carries a
/// positive control on the same path: the same bytes fed **live** must produce
/// the effect the ingest arm requires to be missing. Without that control a
/// broken fixture — an escape sequence this emulator ignores, a probe wired to
/// nothing — reads as a pass.
///
/// **The child is real.** `send`'s only observable effect on the local-PTY
/// route is a write to `localProcess`'s descriptor, and `LocalProcess.send`
/// drops everything unless a process is actually running — so a coordinator
/// with no child would report "no bytes escaped" for the wrong reason. The
/// harness therefore starts one (`/bin/sleep 120`, killed at teardown) and reads
/// the tty's own echo back through the `LocalProcessDelegate`. That descriptor
/// is also the witness for the resize guard.
///
/// **Timing is the subtle part.** SwiftTerm hops every `TerminalViewDelegate`
/// callback through `TerminalView.onMain`, an unconditional
/// `DispatchQueue.main.async` even when the parse already runs on main. So a
/// reply provoked by `feed` is not delivered inside `feed` — it is queued
/// behind it. That is why `feedSnapshot` lowers its flag from a main-queue
/// block rather than on return, and why every assertion here runs after
/// `settle()`.
///
/// Nothing here talks to a live daemon: the interrupt path's best-effort
/// `setTerminalActivity` RPC goes to `TBD_SOCKET_PATH`, which `scripts/test.sh`
/// fences onto a scratch path with no listener.
@MainActor
@Suite("Quiet snapshot ingest", .timeLimit(.minutes(3)))
struct QuietIngestTests {

    @Test("A terminal query inside a snapshot produces no outgoing bytes")
    func queriesAreNotAnswered() async {
        let harness = makeCoordinatorHarness()
        defer { harness.tearDown() }
        #expect(harness.childPID > 0, "no child means no observable outgoing path")
        // DA1, DSR cursor-position and a DECRQM — all reply-producing.
        let snapshot = Data("\u{1b}[c\u{1b}[6n\u{1b}[?7$p".utf8)
        harness.coordinator.feedSnapshot(snapshot, into: harness.terminalView)
        await harness.settle()
        #expect(harness.sentBytes.isEmpty, "replies escaped into the child's stdin")
    }

    /// The ordering guard in `send`, pinned.
    ///
    /// The bytes are handed to the delegate directly, and that is deliberate:
    /// `handleOutgoingInput` reads a lone `0x1b`, or any slice containing
    /// `0x03`, as a user interrupt, and no reply this emulator produces has
    /// that shape — replies arrive as one multi-byte slice of printable ASCII.
    /// What does have that shape is a **keystroke**, and a keystroke can land
    /// here during an ingest for the same reason a reply can: the callback
    /// arrives a main-queue turn after the feed, while the flag is still up. So
    /// this is the real arrival shape, minus the queue.
    @Test("An interrupt-shaped byte arriving during ingest is not read as a user interrupt")
    func escapeIsNotAnInterrupt() async {
        let harness = makeCoordinatorHarness()
        defer { harness.tearDown() }
        harness.coordinator.feedSnapshot(Data("\u{1b}[6n".utf8), into: harness.terminalView)
        #expect(harness.coordinator.isIngestingSnapshot,
                "the flag must still be up when a queued callback lands")
        harness.coordinator.send(source: harness.terminalView, data: ArraySlice([0x1b]))
        harness.coordinator.send(source: harness.terminalView, data: ArraySlice([0x03]))
        await harness.settle()
        #expect(harness.interruptCount == 0)

        // Positive control: the very same bytes, once the flag is down, DO
        // raise the interrupt — so the assertion above is about the guard, not
        // about an interrupt path that never fires in this fixture.
        #expect(!harness.coordinator.isIngestingSnapshot)
        harness.coordinator.send(source: harness.terminalView, data: ArraySlice([0x03]))
        let raised = await harness.waitUntil { harness.interruptCount == 1 }
        #expect(raised, "a live Ctrl-C must still reach handleTerminalInterrupt")
    }

    /// The bell guard's *premise*, pinned — the ring itself cannot be observed.
    ///
    /// `bell(source:)` calls `NSSound.beep()` and nothing else, and that call
    /// is unobservable from a test: `NSSound.beep()` is a pure Swift shim in
    /// the AppKit overlay, with no `+[NSSound beep]` in the Objective-C runtime
    /// to swizzle (checked at runtime, not assumed). So this asserts the fact
    /// the guard depends on and that a plausible refactor would break: a BEL
    /// inside a snapshot reaches the delegate a main-queue turn *after* the
    /// feed returned, with the flag still raised. Lower the flag on return —
    /// the obvious way to write `feedSnapshot` — and this goes red while the
    /// guard in `bell` stays untouched. Suppression of the ring itself is not
    /// covered by any test; see the task report.
    @Test("A BEL in a snapshot reaches the delegate while the ingest flag is still raised")
    func bellArrivesDuringIngest() async {
        let harness = makeCoordinatorHarness()
        defer { harness.tearDown() }
        let spy = RecordingTerminalViewDelegate()
        let coordinator = harness.coordinator
        spy.onBell = { spy.flagWhenBellArrived = coordinator.isIngestingSnapshot }
        harness.terminalView.terminalDelegate = spy
        harness.coordinator.feedSnapshot(Data("hello\u{07}".utf8), into: harness.terminalView)
        let rang = await harness.waitUntil { spy.bells == 1 }
        harness.terminalView.terminalDelegate = harness.coordinator
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
    func clipboardUntouched() async {
        let harness = makeCoordinatorHarness()
        defer { harness.tearDown() }
        let marker = "tbd-quiet-ingest-\(UUID().uuidString)"
        let osc52 = Data(
            "\u{1b}]52;c;\(Data(marker.utf8).base64EncodedString())\u{07}".utf8)
        harness.coordinator.feedSnapshot(osc52, into: harness.terminalView)
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
        harness.terminalView.terminalDelegate = harness.coordinator
        #expect(copied, "the OSC 52 fixture must reach clipboardCopy at all")
        #expect(NSPasteboard.general.string(forType: .string) != marker,
                "the spy arm must not write either")
    }

    /// A replayed DECCOLM must not resize the child's pty.
    ///
    /// `CSI ? 40 h` is what enables DECCOLM in this emulator (xterm's
    /// `allowC132`); `CSI ? 3 h` then resizes the buffer to 132 columns and
    /// notifies the delegate — which is where the `TIOCSWINSZ` lives. The
    /// child's pty is the witness.
    @Test("A resize sequence in a snapshot does not resize the child's pty")
    func resizeIsNotPropagated() async {
        let harness = makeCoordinatorHarness()
        defer { harness.tearDown() }
        // The baseline is whatever the view's own geometry already pushed down
        // to the pty — a real `sizeChanged` fires on layout, before any of
        // this — so it is read, not assumed.
        await harness.settle()
        let baseline = harness.ptyColumns()
        #expect(baseline > 0)
        #expect(baseline != 80, "the control below needs a column count to move to")

        harness.coordinator.feedSnapshot(
            Data("\u{1b}[?40h\u{1b}[?3h".utf8), into: harness.terminalView)
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
    func notificationsAreSuppressed() async {
        let harness = makeCoordinatorHarness()
        defer { harness.tearDown() }
        let osc777 = Data("\u{1b}]777;notify;Title;Body\u{07}".utf8)
        harness.coordinator.feedSnapshot(osc777, into: harness.terminalView)
        await harness.settle()
        #expect(harness.notificationCount == 0)

        // Positive control: the observation is reinstalled afterwards, so the
        // same bytes fed live do notify.
        harness.terminalView.feed(byteArray: [UInt8](osc777)[...])
        let notified = await harness.waitUntil { harness.notificationCount == 1 }
        #expect(notified, "the OSC 777 observation must be restored after ingest")
    }

    @Test("The flag is lowered afterwards, so live output behaves normally")
    func flagIsRestored() async {
        let harness = makeCoordinatorHarness()
        defer { harness.tearDown() }
        harness.coordinator.feedSnapshot(Data("x".utf8), into: harness.terminalView)
        await harness.settle()
        #expect(!harness.coordinator.isIngestingSnapshot)
        harness.terminalView.feed(text: "\u{1b}[6n")
        let answered = await harness.waitUntil { !harness.sentBytes.isEmpty }
        #expect(answered, "live queries must still be answered")
    }
}

// MARK: - Harness

/// The column count the harness's pty starts at.
private let quietIngestInitialColumns: UInt16 = 200

/// A panel wired the way `TerminalPanelRepresentable.makeNSView` wires one,
/// plus the probes that make each suppressed side effect observable.
@MainActor
final class QuietIngestHarness {
    /// Deliberately neither 80 nor 132, so a DECCOLM in either direction shows
    /// up in the pty's window size. File-scope-backed so the `LocalProcess`
    /// delegate, which answers off the main actor, can read it too.
    static var initialPtyColumns: UInt16 { quietIngestInitialColumns }

    let appState: AppState
    let coordinator: TerminalPanelRepresentable.Coordinator
    let terminalView: TBDTerminalView
    let worktreeID: UUID
    let terminalID: UUID
    let childPID: pid_t

    private let process: LocalProcess
    private let outgoing: OutgoingRecorder
    private let defaults: UserDefaults
    private let defaultsSuiteName: String
    private let notifications = MainCounter()

    init(
        appState: AppState,
        coordinator: TerminalPanelRepresentable.Coordinator,
        terminalView: TBDTerminalView,
        process: LocalProcess,
        outgoing: OutgoingRecorder,
        worktreeID: UUID,
        terminalID: UUID,
        defaults: UserDefaults,
        defaultsSuiteName: String
    ) {
        self.appState = appState
        self.coordinator = coordinator
        self.terminalView = terminalView
        self.process = process
        self.outgoing = outgoing
        self.worktreeID = worktreeID
        self.terminalID = terminalID
        self.defaults = defaults
        self.defaultsSuiteName = defaultsSuiteName
        self.childPID = process.shellPid
        let counter = notifications
        terminalView.onNotification = { _, _ in counter.increment() }
    }

    /// What came back off the child's tty. The line discipline echoes whatever
    /// the coordinator wrote, so a non-empty buffer means bytes escaped.
    var sentBytes: [UInt8] { outgoing.recorded }

    /// `handleTerminalInterrupt` idles the seeded agent terminal, so the seeded
    /// row's activity state is the interrupt's own record of itself.
    var interruptCount: Int {
        appState.terminals[worktreeID]?.first?.activityState == .idle ? 1 : 0
    }

    var notificationCount: Int { notifications.value }

    /// The child pty's current column count: what `sizeChanged`'s `TIOCSWINSZ`
    /// would have changed.
    func ptyColumns() -> UInt16 {
        var size = winsize()
        guard process.childfd >= 0, ioctl(process.childfd, TIOCGWINSZ, &size) == 0 else { return 0 }
        return size.ws_col
    }

    /// Lets every deferred callback land: five main-queue turns with a short
    /// real pause between them. The main-queue turns are what the delegate hops
    /// need (they are FIFO behind the feed); the pauses cover the two paths
    /// that leave the main queue — the OSC observation's private serial queue,
    /// and the tty round trip behind `sentBytes`.
    func settle() async {
        for _ in 0..<5 { await hop() }
    }

    /// Polls `condition` until it holds or the deadline passes. Used only by
    /// positive controls, where `false` is a real failure and not a wait.
    /// The default deadline is generous because it is only ever *spent* by a
    /// failing control: this suite runs in the fast parallel pass, where a test
    /// doing 1.5 s of work has been measured taking 106 s of wall time.
    func waitUntil(_ condition: () -> Bool, deadline: TimeInterval = 30.0) async -> Bool {
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
        terminalView.onNotification = nil
        terminalView.terminalDelegate = nil
        coordinator.localProcess = nil
        // The child is a `sleep` that would exit on its own; end it now so a
        // failing run leaves nothing behind. `LocalProcess`'s own exit monitor
        // does the `waitpid`.
        if childPID > 0 { kill(childPID, SIGKILL) }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }
}

/// Builds a coordinator on the production wiring, with a probe for each side
/// effect a snapshot must not fire.
@MainActor
func makeCoordinatorHarness() -> QuietIngestHarness {
    // Isolated defaults: `UserDefaults.standard` on this unbundled executable is
    // the developer's real TBDApp.plist.
    let suiteName = "TBDAppTests.QuietIngest.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let appState = AppState(userDefaults: defaults)

    let worktreeID = UUID()
    let terminalID = UUID()
    // A Claude terminal in `.working`: `handleTerminalInterrupt` records
    // nothing unless it can find an agent terminal, and Esc is Claude's
    // interrupt key.
    appState.terminals[worktreeID] = [Terminal(
        id: terminalID,
        worktreeID: worktreeID,
        tmuxWindowID: "@1",
        tmuxPaneID: "%1",
        label: "Claude",
        kind: .claude,
        activityState: .working
    )]

    let view = TBDTerminalView(
        frame: CGRect(x: 0, y: 0, width: 600, height: 300),
        font: TBDTerminalView.defaultMonospaceFont,
        appearance: AppearanceSettings(defaults: defaults)
    )

    let coordinator = TerminalPanelRepresentable.Coordinator()
    coordinator.appState = appState
    coordinator.panelID = terminalID
    coordinator.terminalView = view

    // A real PTY child, for the reason the suite comment gives. The delegate is
    // the recorder rather than the coordinator: the coordinator would feed the
    // echo straight back into the view under test.
    let outgoing = OutgoingRecorder()
    let process = LocalProcess(delegate: outgoing, dispatchQueue: .main)
    // Long enough to outlive a test that is merely starved for scheduling on a
    // loaded box — a child that exits mid-test closes the pty and turns every
    // probe on it into a zero. Killed in `tearDown`.
    process.startProcess(executable: "/bin/sleep", args: ["120"], environment: nil, execName: nil)
    coordinator.localProcess = process

    view.terminalDelegate = coordinator

    return QuietIngestHarness(
        appState: appState,
        coordinator: coordinator,
        terminalView: view,
        process: process,
        outgoing: outgoing,
        worktreeID: worktreeID,
        terminalID: terminalID,
        defaults: defaults,
        defaultsSuiteName: suiteName
    )
}

// MARK: - Probes

/// Records what comes back off the child's tty, and reports the window size the
/// pty is created with.
final class OutgoingRecorder: LocalProcessDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var recorded: [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {}

    func dataReceived(slice: ArraySlice<UInt8>) {
        lock.lock()
        bytes.append(contentsOf: slice)
        lock.unlock()
    }

    func getWindowSize() -> winsize {
        winsize(
            ws_row: 24, ws_col: quietIngestInitialColumns, ws_xpixel: 0, ws_ypixel: 0)
    }
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
