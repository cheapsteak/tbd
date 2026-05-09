import Foundation
import Darwin
import os

// MARK: - Public types (internal to TBDApp; @testable visible in tests)

/// Edge transition for the watchdog state machine.
enum HangWatchdogTransition: Equatable {
    case toHung
    case toHealthy
}

/// Decision returned by `HangWatchdog.evaluate(...)`. The pure helper produces
/// either a transition that should be logged once, or `.noop` when the current
/// tick neither crosses the healthy↔hung threshold nor needs to log again
/// during a sustained stall.
enum HangWatchdogAction: Equatable {
    case noop
    case log(HangWatchdogTransition)
}

/// MainActor-populated snapshot of app context, captured on every successful
/// main-thread heartbeat. When a hang fires, the most recent snapshot reflects
/// the state at the last moment the main thread was responsive — i.e. right
/// before the stall began.
struct HangWatchdogSnapshot: Equatable {
    /// Wall-clock timestamp the snapshot was recorded.
    var capturedAt: Date
    /// Suffix-4 hex of the focused terminal UUID (matches
    /// `TranscriptItemsView.shortID`). `nil` when no terminal is focused or
    /// the snapshot has never been populated by a view.
    var focusedTerminalIDShort: String?
    /// Set by `LiveTranscriptPaneView` on appear and on `messages.count`
    /// change; cleared on disappear. `nil` when the live transcript pane is
    /// not the active view — including before it has ever been visited and
    /// after the user has navigated to a different pane. Other panes
    /// (terminal, file viewer, code viewer, web view) don't yet feed the
    /// snapshot — hangs in those panes log with `itemCount=-1 pane=-`.
    var transcriptItemCount: Int?
    var paneLabel: String?

    static let empty = HangWatchdogSnapshot(
        capturedAt: .distantPast,
        focusedTerminalIDShort: nil,
        transcriptItemCount: nil,
        paneLabel: nil
    )
}

// MARK: - HangWatchdog

/// Detects unresponsive periods on the main thread and emits a single
/// structured log line per hang event.
///
/// Edge-triggered: the watchdog logs once on the healthy→hung transition and
/// once on hung→healthy. It does NOT spam during a sustained stall.
///
/// Mechanism — a background `DispatchSourceTimer` at `.utility` QoS fires
/// every 250 ms. Each tick it computes how long ago the main thread last
/// successfully ran a heartbeat block (`recordTick`). If that age exceeds the
/// configured threshold and we were previously healthy, we log the hang. If
/// we were previously hung and the age has shrunk back below the threshold,
/// we log the recovery.
///
/// The heartbeat block runs on `DispatchQueue.main.async` so it only completes
/// when the main thread actually drains its queue — i.e. SwiftUI layout,
/// AppKit event handling, etc. all yield. That same block also captures the
/// app-state snapshot (see `HangWatchdogSnapshot`).
///
/// `mach_absolute_time` + `DispatchSourceTimer` only — no APIs that require
/// `Bundle.main.bundleIdentifier` (TBDApp is unbundled — see CLAUDE.md).
final class HangWatchdog: @unchecked Sendable {
    static let shared = HangWatchdog()

    // MARK: Configuration

    /// Threshold in milliseconds beyond which a stall is reported as a hang.
    /// 1500 ms is comfortably above the worst non-hang transcript layout pause
    /// we've measured but well below the 17 s hangs in `crash.log`.
    static let defaultThresholdMs: UInt64 = 1500

    /// Background tick interval. 250 ms gives sub-half-second detection of
    /// onset and recovery without meaningful battery cost — the timer just
    /// reads two locks and returns.
    private static let tickInterval: DispatchTimeInterval = .milliseconds(250)

    // MARK: State

    private static let logger = Logger(subsystem: "com.tbd.app", category: "hang-watchdog")

    /// Mach timestamp of the most recent successful main-thread heartbeat.
    /// Read from the background timer, written from the main queue. Guarded
    /// by `OSAllocatedUnfairLock` to match the project pattern in
    /// `TranscriptItemsView` (and avoid relying on Atomic/UnsafeAtomic
    /// availability in the current toolchain).
    private let lastTickLock = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    /// Most recent snapshot captured on the main thread. Read by the timer
    /// when emitting a hang log; written by the heartbeat block and by view
    /// callers via `recordContext`.
    private let snapshotLock = OSAllocatedUnfairLock<HangWatchdogSnapshot>(initialState: .empty)

    /// Owned by the timer fire closure — always touched on the watchdog
    /// queue. Tracks whether the most recent decision was "hung" so we can
    /// detect transitions.
    private var wasHung: Bool = false

    /// Mach timestamp at which the current hang began. Used to report total
    /// stall duration on recovery.
    private var hangStartedAtMach: UInt64 = 0

    private let thresholdMs: UInt64
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.tbd.app.hang-watchdog", qos: .utility)

    // MARK: Init

    init(thresholdMs: UInt64 = HangWatchdog.defaultThresholdMs) {
        self.thresholdMs = thresholdMs
    }

    // MARK: - Lifecycle

    /// Start the watchdog. Idempotent — calling more than once is a no-op.
    /// Safe to invoke from any thread.
    func start() {
        queue.async { [self] in
            guard timer == nil else { return }

            // Seed lastTick to "now" so we don't immediately register a hang
            // before the first heartbeat lands.
            let now = mach_absolute_time()
            lastTickLock.withLock { $0 = now }

            // Schedule the first heartbeat so the snapshot is populated even
            // if no view ever calls `recordContext`.
            DispatchQueue.main.async { @MainActor [weak self] in
                self?.recordTick()
            }

            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval, leeway: .milliseconds(50))
            t.setEventHandler { [weak self] in
                self?.tick()
            }
            t.resume()
            timer = t
            Self.logger.info("watchdog started thresholdMs=\(self.thresholdMs, privacy: .public)")
        }
    }

    /// Stop the watchdog and tear down its timer. Idempotent.
    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            // Reset transition state so a subsequent start() doesn't fire a
            // spurious "hang recovered" on the first fresh tick (the re-seeded
            // lastTick would read tiny, but `wasHung == true` would still
            // match the .toHealthy edge in evaluate()).
            wasHung = false
            hangStartedAtMach = 0
        }
    }

    // MARK: - Heartbeat / snapshot

    /// Called on the main queue (via the heartbeat dispatch and by `start`).
    /// Updates `lastTickAt` to "now" and refreshes the snapshot timestamp so
    /// the captured state reflects the last responsive moment.
    @MainActor
    func recordTick() {
        let now = mach_absolute_time()
        lastTickLock.withLock { $0 = now }
        snapshotLock.withLock { snap in
            snap.capturedAt = Date()
        }
    }

    /// Mutate the snapshot from the main thread. Call from views or
    /// coordinators when focused state changes — e.g. when a transcript pane
    /// becomes the active tab, or the focused terminal changes.
    func recordContext(_ mutate: @Sendable (inout HangWatchdogSnapshot) -> Void) {
        snapshotLock.withLock { snap in
            mutate(&snap)
            snap.capturedAt = Date()
        }
    }

    // MARK: - Tick (background)

    private func tick() {
        let now = mach_absolute_time()
        let lastTick = lastTickLock.withLock { $0 }
        let stallNs = Self.machDeltaToNanos(now: now, then: lastTick)
        let action = Self.evaluate(
            stallNs: stallNs,
            wasHung: wasHung,
            thresholdMs: thresholdMs
        )

        switch action {
        case .noop:
            break
        case .log(.toHung):
            wasHung = true
            hangStartedAtMach = lastTick
            let stallMs = stallNs / 1_000_000
            let snap = snapshotLock.withLock { $0 }
            Self.logger.warning(
                "hang detected stallMs=\(stallMs, privacy: .public) terminalID=\(snap.focusedTerminalIDShort ?? "-", privacy: .public) itemCount=\(snap.transcriptItemCount ?? -1, privacy: .public) pane=\(snap.paneLabel ?? "-", privacy: .public)"
            )
        case .log(.toHealthy):
            let totalStallNs = Self.machDeltaToNanos(now: now, then: hangStartedAtMach)
            let totalStallMs = totalStallNs / 1_000_000
            wasHung = false
            hangStartedAtMach = 0
            Self.logger.info("hang recovered after stallMs=\(totalStallMs, privacy: .public)")
        }

        // Schedule the next heartbeat. Always schedule — even during a hang
        // — so the same dispatch that completes when the main thread drains
        // is what trips the recovery edge on the next tick.
        DispatchQueue.main.async { @MainActor [weak self] in
            self?.recordTick()
        }
    }

    // MARK: - Pure helpers (testable)

    /// Decide whether this tick should log a transition. Pure — depends only
    /// on its arguments, not on `self` or any global state. Tests call this
    /// directly with synthetic inputs to cover all four branches without
    /// spinning up a timer.
    static func evaluate(stallNs: UInt64, wasHung: Bool, thresholdMs: UInt64) -> HangWatchdogAction {
        let thresholdNs = thresholdMs * 1_000_000
        let isHungNow = stallNs >= thresholdNs
        switch (wasHung, isHungNow) {
        case (false, false), (true, true):
            return .noop
        case (false, true):
            return .log(.toHung)
        case (true, false):
            return .log(.toHealthy)
        }
    }

    /// Convert a (now - then) mach-time delta to nanoseconds using
    /// `mach_timebase_info`. Cached on first call. Returns 0 if `then > now`
    /// (clock went backwards) or if then is 0 (uninitialized).
    static func machDeltaToNanos(now: UInt64, then: UInt64) -> UInt64 {
        guard then != 0, now >= then else { return 0 }
        let delta = now - then
        let info = Self.timebase
        // (delta * numer) / denom in plain UInt64. Overflow is impractical
        // here because numer is tiny (1 on Intel, 125 on Apple Silicon) and
        // delta is at most uptime-since-last-tick — bounded by the timer
        // interval in steady state. Wraparound would require deltas
        // measured in years.
        return delta * UInt64(info.numer) / UInt64(info.denom)
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
}
