import Foundation
import TBDShared

/// Which periodic PR driver runs: today's fixed-interval `PRPoller`, or the
/// budgeted `PRPollScheduler`. Exactly one of them, never both — the merged-PR
/// transition is edge-triggered on a cache change, and a second periodic
/// driver would swallow edges the first one's consumers are waiting for.
///
/// Read once at daemon start from `pr_poll_schedule_enabled`; changing the
/// flag takes a daemon restart. Spec:
/// docs/specs/2026-10-01-pr-polling-schedule-design.md, "The flag".
public enum PRPollDriver {
    public enum Kind: Equatable, Sendable { case legacyPoller, schedule }

    public static func kind(for config: Config) -> Kind {
        config.prPollScheduleEnabled ? .schedule : .legacyPoller
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
