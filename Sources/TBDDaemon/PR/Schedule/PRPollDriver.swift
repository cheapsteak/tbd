import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "PRPollDriver")

/// Which periodic PR driver runs: today's fixed-interval `PRPoller`, or the
/// budgeted `PRPollScheduler`. Exactly one of them, never both — the merged-PR
/// transition is edge-triggered on a cache change, and a second periodic
/// driver would swallow edges the first one's consumers are waiting for.
///
/// Chosen at daemon start from `pr_poll_schedule_enabled`, and switched live
/// when the flag changes (`PRPollDriverSwitch`). Spec:
/// docs/specs/2026-10-01-pr-polling-schedule-design.md, "The flag".
public enum PRPollDriver {
    public enum Kind: Equatable, Sendable { case legacyPoller, schedule }

    public static func kind(for config: Config) -> Kind {
        config.prPollScheduleEnabled ? .schedule : .legacyPoller
    }

    public static func kind(enabled: Bool) -> Kind {
        enabled ? .schedule : .legacyPoller
    }

    /// Start the one driver `kind` names. The closures are the daemon's start
    /// steps for each, so a test can observe which one ran.
    public static func start(_ kind: Kind,
                             legacy: @Sendable () async -> Void,
                             schedule: @Sendable () async -> Void) async {
        switch kind {
        case .legacyPoller: await legacy()
        case .schedule: await schedule()
        }
    }
}

/// The one place that starts, stops and swaps the periodic PR driver, so
/// daemon start-up, a live flag change and shutdown cannot drift apart.
///
/// - `start(_:)` is the daemon's start-up step: it starts the driver `kind`
///   names and nothing else, and arms the switch. Called again with the other
///   kind it swaps; with the same kind it does nothing.
/// - `apply(_:persist:)` is the live switch the
///   `config.setPRPollScheduleEnabled` handler calls. It writes the column
///   (`persist`) and then stops the running driver and starts the other, both
///   inside one serialized section, so concurrent writes cannot leave the
///   column saying one thing while the other driver runs. The switch half does
///   nothing until `start(_:)` has armed it — so a daemon in mock mode, and
///   every router a test builds, never starts a driver because a flag was
///   written — and nothing when `kind` already runs.
/// - `stopAll()` is shutdown: it stops both drivers and disarms the switch, so
///   a toggle landing while the socket is still up cannot restart a loop that
///   would outlive the daemon.
///
/// Transitions are serialized: each waits for the previous one to finish, so
/// two quick toggles can never leave both drivers running. (An actor alone
/// does not give that — its methods interleave at every `await`.) The stop
/// steps must wait for an in-flight pass to finish (`stopAndWait`), or a
/// quick off→on would overlap the old pass with the new driver's first one.
///
/// A disable leaves the scheduler's in-memory state behind — its due times,
/// its budget reading, a pending kick — and the ledger's recency stamps. All
/// of it ages harmlessly: stale due times make items due sooner, never later;
/// stamps older than the recency window read as idle; and a kept budget means
/// a quick off→on does not forget a rate-limit brake. The disabled ledger
/// records nothing new, so none of it grows while the poller runs.
public actor PRPollDriverSwitch {
    /// The start and stop steps of each driver. The stops must not return
    /// while a pass of that driver is still running.
    public struct Steps: Sendable {
        let startLegacy: @Sendable () async -> Void
        let stopLegacy: @Sendable () async -> Void
        let startSchedule: @Sendable () async -> Void
        let stopSchedule: @Sendable () async -> Void

        public init(startLegacy: @escaping @Sendable () async -> Void,
                    stopLegacy: @escaping @Sendable () async -> Void,
                    startSchedule: @escaping @Sendable () async -> Void,
                    stopSchedule: @escaping @Sendable () async -> Void) {
            self.startLegacy = startLegacy
            self.stopLegacy = stopLegacy
            self.startSchedule = startSchedule
            self.stopSchedule = stopSchedule
        }
    }

    private let steps: Steps
    /// The driver running now; nil until `start(_:)` arms the switch, and
    /// again after `stopAll()` disarms it.
    public private(set) var active: PRPollDriver.Kind?
    private var tail: Task<Void, Never>?

    public init(steps: Steps) {
        self.steps = steps
    }

    /// Start-up: start the driver `kind` names, and arm live switching. The
    /// other driver is left untouched — it was never started.
    public func start(_ kind: PRPollDriver.Kind) async {
        await serialized { await $0.arm(kind) }
    }

    /// Live switch: run `persist` (the column write), then stop the running
    /// driver and start the one `kind` names. A failed write throws and
    /// switches nothing. The switch is a no-op before `start(_:)`, after
    /// `stopAll()`, and when `kind` already runs; the write happens regardless.
    public func apply(_ kind: PRPollDriver.Kind,
                      persist: @escaping @Sendable () async throws -> Void = {}) async throws {
        let outcome = await serialized { (sw: PRPollDriverSwitch) async -> Result<Void, any Error> in
            do {
                try await persist()
            } catch {
                return .failure(error)
            }
            await sw.switchIfArmed(to: kind)
            return .success(())
        }
        try outcome.get()
    }

    /// Shutdown: stop both drivers, waiting for any pass in flight, and disarm,
    /// so a later `apply` writes its column and starts nothing.
    public func stopAll() async {
        await serialized { await $0.disarmAndStop() }
    }

    private func serialized<T: Sendable>(
        _ body: @escaping @Sendable (PRPollDriverSwitch) async -> T
    ) async -> T {
        let previous = tail
        let task = Task { [self] in
            await previous?.value
            return await body(self)
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func arm(_ kind: PRPollDriver.Kind) async {
        guard let current = active else {
            active = kind
            await PRPollDriver.start(kind, legacy: steps.startLegacy, schedule: steps.startSchedule)
            return
        }
        if current != kind { await swap(to: kind) }
    }

    private func switchIfArmed(to kind: PRPollDriver.Kind) async {
        guard let current = active else {
            logger.debug("PR driver switch not armed; ignoring a switch to \(String(describing: kind), privacy: .public)")
            return
        }
        guard current != kind else { return }
        await swap(to: kind)
    }

    private func swap(to kind: PRPollDriver.Kind) async {
        switch kind {
        case .schedule: await steps.stopLegacy()
        case .legacyPoller: await steps.stopSchedule()
        }
        active = kind
        await PRPollDriver.start(kind, legacy: steps.startLegacy, schedule: steps.startSchedule)
        logger.info("PR driver switched to \(String(describing: kind), privacy: .public)")
    }

    private func disarmAndStop() async {
        active = nil
        await steps.stopLegacy()
        await steps.stopSchedule()
    }
}
