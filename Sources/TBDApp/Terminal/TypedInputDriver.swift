import AppKit
import Foundation
import SwiftTerm
import TBDShared
import os

/// TEMPORARY diagnostic instrumentation — see `RenderLatencySignposts`. Not a
/// feature, no flag, meant to be reverted once the measurement is taken.
///
/// Drives `TerminalView.send(txt:)` on the first responder, which is the one
/// thing a script cannot do from outside the process: macOS refuses synthetic
/// keystrokes to a process without an Accessibility grant, and `osascript` does
/// not have one on this machine (`keystroke "a"` fails with TCC error 1002 —
/// note that `keystroke ""` *succeeds*, because an empty string sends nothing
/// and never reaches the permission check).
///
/// That matters because `send(data:)` is what calls `recordUserInput()`, which
/// opens SwiftTerm's 150 ms immediate-display window, and every keystroke
/// measurement taken so far has been injected at the tmux layer instead —
/// reaching the pty directly and never touching the view. The throttled path
/// and the typed path are different code, and only this reaches the second one.
///
/// **What it reproduces, and what it does not.** It targets
/// `NSApp.keyWindow?.firstResponder`, which is literally the view a real
/// keystroke would be delivered to, and calls the same `send(txt:)` that
/// `keyDown` ends in. It does not reproduce the `NSEvent` dispatch above that
/// call — so it measures everything from `recordUserInput()` onward and nothing
/// before it. That is the segment in question; TBD's own keydown handling
/// remains unmeasured.
///
/// Triggered by writing a JSON file to `~/tbd/runtime/typed-drive.json`:
///
///     {"count": 120, "minGap": 0.12, "maxGap": 0.26, "seed": 741}
///
/// The driver consumes and deletes the file, then sends `count` characters with
/// randomised gaps. It is self-gating: with no file present it does one
/// `fileExists` check per poll and nothing else, so no launch flag is needed.
enum TypedInputDriver {
    private static let log = Logger(subsystem: "com.tbd.app", category: "typedinputdriver")
    @MainActor private static var started = false
    @MainActor private static var timer: Timer?

    /// Idempotent; called from `TBDTerminalView.viewWillDraw()` so the driver
    /// bootstraps itself without touching app lifecycle code.
    @MainActor
    static func ensureStarted() {
        guard !started else { return }
        started = true
        let t = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        installKeyLatencyMonitor()
    }

    /// TEMPORARY. Main-thread queueing delay for one real keystroke.
    ///
    /// `NSEvent.timestamp` is stamped by the window server when it created the
    /// event; `systemUptime` is read on the main thread at the moment the app
    /// finally gets to it. The difference is exactly how long that keystroke
    /// waited behind whatever else the main thread was doing.
    ///
    /// Worth having because it needs **no synthetic input and no Accessibility
    /// grant** — it measures a human typing. Every keystroke figure in this
    /// investigation so far came from keys injected at the tmux layer, which
    /// reach the pty directly and never run the view's `keyDown` at all, so
    /// `send(data:)` — and with it `recordUserInput()` and SwiftTerm's 150 ms
    /// immediate-display window — was never exercised.
    ///
    /// It also **decomposes** a latency only ever measured as a total.
    /// Key-to-paint is this queueing delay, plus transit out through tmux/pty
    /// and back, plus paint scheduling. A scheduling floor and a synchronous
    /// per-chunk cost are indistinguishable in the sum and separable here: if
    /// the cost is `displayImmediately()` doing a full synchronous
    /// `updateDisplay` per chunk, this climbs while an agent streams and falls
    /// when it stops. A fixed floor does not behave that way.
    ///
    /// A local monitor is used because SwiftTerm's `keyDown` is `public`, not
    /// `open`, so it cannot be overridden from this module — the same constraint
    /// that forces the other `NSEvent` monitors in `TerminalPanelView`. The
    /// monitor never consumes the event; it always returns it unchanged.
    ///
    /// Emitted as an `info` log line rather than a signpost deliberately:
    /// signpost emission proved unreliable here — it stops entirely when no live
    /// listener is attached — and this has to survive passive collection from
    /// ordinary use. Read it back with `scripts/diag/key-queue-report.py`, or:
    ///
    ///     log show --last 30m --info --predicate \
    ///       'subsystem == "com.tbd.app" AND category == "keylatency"'
    @MainActor
    private static func installKeyLatencyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let queuedMs = (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000
            MainActor.assumeIsolated {
                // The responder class is recorded alongside the delay so a line
                // typed into a text field is not mistaken for one typed into a
                // terminal — they are different code paths and only the terminal
                // one reaches send(data:).
                let responder = NSApp.keyWindow?.firstResponder
                let cls = responder.map { String(describing: type(of: $0)) } ?? "none"
                keyLog.info(
                    "keyqueue ms=\(queuedMs, format: .fixed(precision: 2), privacy: .public) responder=\(cls, privacy: .public)")
            }
            return event
        }
    }

    @MainActor private static var keyMonitor: Any?
    private static let keyLog = Logger(subsystem: "com.tbd.app", category: "keylatency")

    @MainActor
    private static func poll() {
        let path = TBDConstants.configDir.appendingPathComponent("runtime/typed-drive.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        guard let data = try? Data(contentsOf: path) else { return }
        // Delete before sending, so a driver that throws cannot re-trigger itself
        // on the next poll and type forever into whatever is focused.
        try? FileManager.default.removeItem(at: path)
        guard let req = try? JSONDecoder().decode(Request.self, from: data) else {
            log.error("typed-drive.json did not decode; ignoring")
            return
        }
        log.info("typed-drive: sending \(req.count, privacy: .public) keys")
        send(remaining: req.count, index: 0, req: req, rng: SplitMix64(seed: req.seed))
    }

    @MainActor
    private static func send(remaining: Int, index: Int, req: Request, rng: SplitMix64) {
        guard remaining > 0 else {
            log.info("typed-drive: done")
            return
        }
        var rng = rng
        guard let view = terminalView(withID: req.terminalID) else {
            // Aborting rather than retrying: a run that silently sent half its
            // keystrokes would still produce a plausible-looking latency table.
            // The diagnosis matters more than the failure — a key window that is
            // absent and a first responder that is the wrong class are different
            // problems, and on this machine it is reliably the former: TBD is
            // activated, holds focus for under five seconds, and loses it again.
            log.error("""
                typed-drive: no terminal view with id \(req.terminalID, privacy: .public) -- \
                aborting after \(index, privacy: .public) keys. The tab must be materialised \
                in a window for the driver to address it.
                """)
            return
        }
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        view.send(txt: String(alphabet[index % alphabet.count]))
        let gap = req.minGap + (req.maxGap - req.minGap) * rng.nextUnit()
        let next = rng
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) {
            MainActor.assumeIsolated {
                send(remaining: remaining - 1, index: index + 1, req: req, rng: next)
            }
        }
    }

    /// Finds the terminal view for one specific terminal, by walking the window
    /// hierarchy. Addressing by ID rather than by first responder is deliberate
    /// and load-bearing: an earlier version targeted
    /// `NSApp.keyWindow?.firstResponder` and typed its alphabet into a live agent
    /// session that happened to hold focus, because a measurement run creates its
    /// own terminal but does not reliably own the key window. `send(txt:)` writes
    /// to the pty through the delegate and needs no focus at all, so there is no
    /// reason to involve the responder chain.
    @MainActor
    private static func terminalView(withID id: UUID) -> TerminalView? {
        func search(_ view: NSView) -> TerminalView? {
            if let tv = view as? TBDTerminalView, tv.diagTerminalID == id { return tv }
            for sub in view.subviews {
                if let found = search(sub) { return found }
            }
            return nil
        }
        for window in NSApp.windows {
            if let root = window.contentView, let found = search(root) { return found }
        }
        return nil
    }

    private struct Request: Decodable {
        let count: Int
        let minGap: Double
        let maxGap: Double
        let seed: UInt64
        /// Required. There is no "whichever terminal is focused" mode by design.
        let terminalID: UUID
    }

    /// Seeded so both sides of a comparison get an identical keystroke cadence;
    /// a fixed cadence can alias against a fixed-interval frame timer.
    private struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func nextUnit() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z = z ^ (z >> 31)
            return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }
    }
}
