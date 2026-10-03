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
/// daemon start-up and a live flag change cannot drift apart.
///
/// - `start(_:)` is the daemon's start-up step: it starts the driver `kind`
///   names and nothing else, and arms the switch.
/// - `apply(_:)` is the live switch the `config.setPRPollScheduleEnabled`
///   handler calls: it stops the running driver and starts the other. It does
///   nothing until `start(_:)` has armed the switch, so a daemon in mock mode —
///   and every router a test builds — never starts a driver because a flag
///   was written; and nothing when `kind` already runs.
///
/// Transitions are serialized: each waits for the previous one to finish, so
/// two quick toggles can never leave both drivers running. (An actor alone
/// does not give that — its methods interleave at every `await`.)
public actor PRPollDriverSwitch {
    /// The start and stop steps of each driver.
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
    /// The driver running now; nil until `start(_:)` arms the switch.
    public private(set) var active: PRPollDriver.Kind?
    private var tail: Task<Void, Never>?

    public init(steps: Steps) {
        self.steps = steps
    }

    /// Start-up: start the driver `kind` names, and arm live switching. The
    /// other driver is left untouched — it was never started.
    public func start(_ kind: PRPollDriver.Kind) async {
        await serialized { await $0.transition(to: kind, arming: true) }
    }

    /// Live switch: stop the running driver and start the one `kind` names.
    /// A no-op before `start(_:)` and when `kind` already runs.
    public func apply(_ kind: PRPollDriver.Kind) async {
        await serialized { await $0.transition(to: kind, arming: false) }
    }

    private func serialized(
        _ body: @escaping @Sendable (PRPollDriverSwitch) async -> Void
    ) async {
        let previous = tail
        let task = Task { [self] in
            await previous?.value
            await body(self)
        }
        tail = task
        await task.value
    }

    private func transition(to kind: PRPollDriver.Kind, arming: Bool) async {
        if arming {
            guard active == nil else {
                if active != kind { await swap(to: kind) }
                return
            }
            active = kind
            await PRPollDriver.start(kind, legacy: steps.startLegacy, schedule: steps.startSchedule)
            return
        }
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
}
