import Foundation

/// The fleet brake: one bit, ANDed over every project's mark (design §3, §8).
public enum SupervisionBrakeState: String, Codable, Sendable {
    /// TBD's authority is paused. The shipped state.
    case engaged
    /// TBD may act, subject to each project's mark.
    case released
}

/// `~/tbd/supervision/status.json` — the out-of-band heartbeat (design §14).
///
/// Always written atomically, and `writtenAt` changes on every write, so a
/// reader can work on content as well as on mtime and never sees a torn file.
///
/// **When it is written, in full — this is the whole contract a watchdog needs:**
///
/// - at daemon start, once;
/// - at every fleet brake edge, before the timer below is armed or disarmed;
/// - and then on a fixed cadence **only while the brake is released**.
///
/// **Staleness is therefore a liveness signal only while `brake` reads
/// `released`.** Under an engaged brake the daemon runs no periodic write at
/// all, and a file that has not changed for hours means the fleet is paused,
/// not that the daemon is gone. Reading it the other way produces exactly the
/// false alarm this arrangement exists to prevent.
///
/// That costs the watchdog nothing, because its rule is *if any project claims
/// to be **effectively on** and this file has not changed in about ten minutes,
/// raise a notification* — and effectively on means a project's `on` **and** a
/// released `brake`. A file saying `engaged` claims nothing is effectively on,
/// so it cannot trip the rule however old it is. The freshness requirement
/// binds precisely when the timer runs.
///
/// The brake is the only switch over this: there is no separate flag, and
/// nothing here writes before an operator has released it.
public struct SupervisionStatusFile: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let writtenAt: SupervisionInstant
    public let brake: SupervisionBrakeState
    public let projects: [SupervisionStatusFileProject]

    public init(writtenAt: SupervisionInstant, brake: SupervisionBrakeState,
                projects: [SupervisionStatusFileProject],
                schemaVersion: Int = SupervisionStatusFile.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.writtenAt = writtenAt
        self.brake = brake
        self.projects = projects
    }
}

/// One project's line in the heartbeat.
public struct SupervisionStatusFileProject: Codable, Sendable, Equatable {
    public let name: String
    /// The project's mark. Effectively on is this AND a released brake.
    public let on: Bool
    public let mode: String
    /// When a sweep program last made contact, or null when it never has.
    public let lastSweepContactAt: SupervisionInstant?

    public init(name: String, on: Bool, mode: String,
                lastSweepContactAt: SupervisionInstant?) {
        self.name = name
        self.on = on
        self.mode = mode
        self.lastSweepContactAt = lastSweepContactAt
    }

    private enum CodingKeys: String, CodingKey {
        case name, on, mode, lastSweepContactAt
    }

    /// Explicit null for "never contacted": the watchdog reads this file
    /// without the daemon's help, so a missing key would be one more thing for
    /// it to guess about.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(on, forKey: .on)
        try container.encode(mode, forKey: .mode)
        try container.encode(lastSweepContactAt, forKey: .lastSweepContactAt)
    }
}
