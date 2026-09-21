import AppKit
import Foundation
import Network

/// What one `NWPath` update is reduced to before it is compared — the three
/// facts that actually decide whether an already-open transport survived.
///
/// Status says whether there is a usable path at all. The ORDERED interface
/// list captures both a VPN appearing (`utun*` joins the list) and a
/// primary-route change (the same names in a different order). The gateways
/// capture a new default router on the same interface — a DHCP move, or a
/// VPN installing its own — which nothing else here would see.
///
/// `isExpensive`/`isConstrained` are deliberately EXCLUDED: they flap on
/// their own (a personal-hotspot toggle, Low Data Mode) without disturbing
/// any transport, and every flap would cost every attached pane a repaint.
struct RemoteAttachNetworkFingerprint: Equatable, Sendable, CustomStringConvertible {
    let status: NWPath.Status
    /// `path.availableInterfaces.map(\.name)`, in the order the path reports
    /// them — the order is the signal, so it is never sorted.
    let interfaceNames: [String]
    /// `path.gateways` rendered as text. Compared as strings because
    /// `NWEndpoint`'s identity is what matters here, not its structure.
    let gateways: [String]

    /// Test seam: build a fingerprint without an `NWPath`, which cannot be
    /// constructed outside the Network framework.
    init(status: NWPath.Status, interfaceNames: [String], gateways: [String]) {
        self.status = status
        self.interfaceNames = interfaceNames
        self.gateways = gateways
    }

    /// The production reduction, applied to every monitor update.
    init(path: NWPath) {
        self.status = path.status
        self.interfaceNames = path.availableInterfaces.map(\.name)
        self.gateways = path.gateways.map { "\($0)" }
    }

    /// Compact single-line form for the handler's log line, e.g.
    /// `satisfied [en0,utun4] via [192.0.2.1]`.
    var description: String {
        let statusLabel: String
        switch status {
        case .satisfied: statusLabel = "satisfied"
        case .unsatisfied: statusLabel = "unsatisfied"
        case .requiresConnection: statusLabel = "requiresConnection"
        @unknown default: statusLabel = "unknown"
        }
        return "\(statusLabel) [\(interfaceNames.joined(separator: ","))] via [\(gateways.joined(separator: ","))]"
    }
}

/// Pure reducer deciding whether one path update is a change worth acting on.
/// Holds no clock, no monitor, and no AppKit — so every rule below is
/// exercised by constructing fingerprints directly.
struct RemoteAttachNetworkChangeDetector: Sendable {
    /// The most recent fingerprint observed, whatever its status. Read by the
    /// watcher BEFORE `observe` to recover the fingerprint a change replaced.
    private(set) var last: RemoteAttachNetworkFingerprint?

    /// Records `fingerprint` as the last seen and reports whether this update
    /// should emit an event.
    ///
    /// Emits when all three hold: a previous fingerprint exists, this one is
    /// `.satisfied`, and it differs from the previous one. So:
    ///
    /// - the SEED update (the one `NWPathMonitor` delivers immediately on
    ///   `start`) emits nothing — there is no "before" to have been killed;
    /// - an UNSATISFIED update emits nothing — re-attaching onto no network
    ///   only burns a spawn; the satisfied update that follows it is the one
    ///   worth acting on;
    /// - an UNCHANGED path emits nothing.
    ///
    /// **Every update becomes `last`, including an unsatisfied one.** That is
    /// what makes `satisfied A → unsatisfied → satisfied A` emit on the third
    /// update even though the path came back identical: status is part of the
    /// fingerprint, so the third update differs from the second, and the
    /// transport died while the path was down regardless of where it landed.
    mutating func observe(_ fingerprint: RemoteAttachNetworkFingerprint) -> Bool {
        let previous = last
        last = fingerprint
        guard let previous else { return false }
        guard fingerprint.status == .satisfied else { return false }
        return fingerprint != previous
    }
}

/// What raised a network change. Both sources are treated identically by the
/// handler — the distinction exists only so a log line can say which one it
/// was when an unnecessary restart has to be explained after the fact.
enum RemoteAttachNetworkTrigger: String, Sendable {
    case path
    case wake
}

/// One debounced network change, as handed to `AppState.handleNetworkChange`.
struct RemoteAttachNetworkChange: Sendable {
    /// Every trigger seen during the debounced burst, in first-seen order,
    /// deduplicated — a wake that brings a VPN back reads as `path, wake`
    /// rather than as four separate events.
    let triggers: [RemoteAttachNetworkTrigger]
    /// The fingerprint in force before the burst opened (`nil` when none had
    /// been seen yet), and the latest one seen during it.
    let previous: RemoteAttachNetworkFingerprint?
    let current: RemoteAttachNetworkFingerprint?
    /// The LATEST raw event's time — the instant the handler compares attach
    /// children's start times against. Taking the latest rather than the
    /// first is what makes a child spawned mid-burst count as "already on the
    /// new path" only if it started after the last disturbance.
    let at: Date
}

/// Watches for the two events that most often kill a live transport whose
/// `attach` child never notices — a network path change and a wake from
/// sleep — and emits one debounced `RemoteAttachNetworkChange` per burst.
///
/// Deliberately knows nothing about remote sessions: it reduces, debounces,
/// and calls `onChange`. `AppState.handleNetworkChange` owns every decision
/// about what to do with the event, and owns the logging too — so this type
/// stays a pure event source that a test can drive through `observePath` /
/// `observeWake` without a network, an `NWPath`, or a sleeping laptop.
///
/// Sleep needs its own source: it kills TCP connections without necessarily
/// changing the path at all, so `NWPathMonitor` alone would miss the single
/// most common way a laptop's panes go dead.
@MainActor
final class RemoteAttachNetworkWatcher {
    /// Called once per debounced burst, on the main actor. Set before
    /// `start()`.
    var onChange: (@MainActor (RemoteAttachNetworkChange) -> Void)?

    private let debounce: Duration
    private let now: @Sendable () -> Date
    private let clock: any Clock<Duration>

    private var detector = RemoteAttachNetworkChangeDetector()
    private var monitor: NWPathMonitor?
    private var wakeObserver: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    /// The burst currently accumulating. `previous` is pinned at the first
    /// event of the burst; `current`, `at`, and `triggers` move with each
    /// later one.
    private var burst: RemoteAttachNetworkChange?

    /// - Parameter debounce: quiet window before a burst is acted on. Two
    ///   seconds covers the usual shape — a wake, then a Wi-Fi association,
    ///   then a VPN reconnecting — collapsing them into one restart instead
    ///   of three.
    /// - Parameter now: the wall clock stamped onto each raw event. Separate
    ///   from `clock` on purpose: this is DATA (compared against recorded
    ///   child start times), while the debounce is BEHAVIOR.
    /// - Parameter clock: last parameter, existential, defaulted — the shared
    ///   seam contract for anything that sleeps.
    init(debounce: Duration = .seconds(2),
         now: @escaping @Sendable () -> Date = { Date() },
         clock: any Clock<Duration> = ContinuousClock()) {
        self.debounce = debounce
        self.now = now
        self.clock = clock
    }

    /// Installs both event sources. Idempotent — a second call while already
    /// running does nothing.
    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let fingerprint = RemoteAttachNetworkFingerprint(path: path)
            // The handler is delivered on `.main` by `start(queue:)` below,
            // but its type is `@Sendable` and carries no static isolation —
            // the same hop `AppState.registerFocusObservers` makes.
            MainActor.assumeIsolated { self.observePath(fingerprint) }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.observeWake() }
        }
    }

    /// Tears both sources down and abandons any burst still accumulating.
    /// Idempotent.
    func stop() {
        monitor?.cancel()
        monitor = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        pending?.cancel()
        pending = nil
        burst = nil
    }

    /// Feeds one reduced path update through the detector, scheduling a fire
    /// only when it says this update is a change worth acting on. The seam
    /// tests drive instead of an `NWPath`.
    func observePath(_ fingerprint: RemoteAttachNetworkFingerprint) {
        let previous = detector.last
        guard detector.observe(fingerprint) else { return }
        schedule(trigger: .path, previous: previous, current: fingerprint)
    }

    /// Records a wake from sleep. Always schedules: a wake implies nothing
    /// about the path, so the detector's latest fingerprint stands as both
    /// `previous` and `current`.
    func observeWake() {
        schedule(trigger: .wake, previous: detector.last, current: detector.last)
    }

    private func schedule(trigger: RemoteAttachNetworkTrigger,
                          previous: RemoteAttachNetworkFingerprint?,
                          current: RemoteAttachNetworkFingerprint?) {
        let at = now()
        if let open = burst {
            var triggers = open.triggers
            if !triggers.contains(trigger) { triggers.append(trigger) }
            burst = RemoteAttachNetworkChange(
                triggers: triggers, previous: open.previous, current: current, at: at)
        } else {
            burst = RemoteAttachNetworkChange(
                triggers: [trigger], previous: previous, current: current, at: at)
        }
        // Trailing edge, cancel-and-replace — the shape `SearchQueryDebouncer`
        // documents at length.
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            guard let self else { return }
            // Cancellation while still asleep surfaces as a thrown error —
            // the "a newer raw event superseded me" path.
            guard (try? await self.clock.sleep(for: self.debounce)) != nil else { return }
            // Both checks are load-bearing; the throw alone is not enough.
            // Cancellation that arrives *after* the sleep has already resumed
            // cannot retroactively make that `await` throw, and the
            // resumption is enqueued on the MainActor — so a raw event (or a
            // `stop()`) that runs first would otherwise be followed by this
            // superseded fire anyway.
            guard !Task.isCancelled else { return }
            self.fire()
        }
    }

    private func fire() {
        guard let change = burst else { return }
        burst = nil
        pending = nil
        onChange?(change)
    }
}
