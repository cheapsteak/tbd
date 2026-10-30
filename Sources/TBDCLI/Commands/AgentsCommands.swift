import ArgumentParser
import Foundation
import TBDShared

struct AgentsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agents",
        abstract: "Control the agent sessions TBD runs",
        subcommands: [AgentsBackground.self]
    )
}

/// Parses `90s`, `10m` or `1h` into seconds. Nil for anything else, for zero, and
/// for a value above the daemon's two-hour limit.
func parseBackgroundLease(_ text: String) -> Int? {
    guard let unit = text.last, text.count >= 2,
          let count = Int(text.dropLast()), count > 0
    else { return nil }
    let multiplier: Int
    switch unit {
    case "s": multiplier = 1
    case "m": multiplier = 60
    case "h": multiplier = 3600
    default: return nil
    }
    let (seconds, overflow) = count.multipliedReportingOverflow(by: multiplier)
    guard !overflow, seconds <= AgentBackgroundLimits.maximumLeaseSeconds else { return nil }
    return seconds
}

/// The one line `tbd agents background` prints.
func backgroundSummary(_ result: AgentsBackgroundResult, now: Date = Date()) -> String {
    guard result.active, let ends = result.leaseEndsAt else {
        guard result.loweredCount > 0 else { return "Agent background priority: off" }
        return "Agent background priority: off, \(result.loweredCount) processes not yet restored "
            + "(retried every minute)"
    }
    let remaining = max(0, Int(ends.timeIntervalSince(now)))
    return "Agent background priority: on for \(remaining / 60)m \(remaining % 60)s more, "
        + "\(result.loweredCount) processes lowered"
}

struct AgentsBackground: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "background",
        abstract: "Hold agent processes at background priority for a lease",
        discussion: """
            `on --for <duration>` lowers every agent process tree TBD owns and keeps \
            lowering new ones until the lease ends; calling it again renews. `off` \
            restores now. Needs `tbd config set agent-background on`.
            """,
        subcommands: [On.self, Off.self, Status.self]
    )

    struct On: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "on", abstract: "Lower agent priority for a lease (renews if already on)")

        @Option(name: .customLong("for"), help: "Lease length: 90s, 10m or 1h (at most 2h)")
        var duration: String

        mutating func run() throws {
            guard let seconds = parseBackgroundLease(duration) else {
                throw ValidationError(
                    "Expected a duration like 90s, 10m or 1h, at most 2h, got: \(duration)")
            }
            let result = try SocketClient().call(
                method: RPCMethod.agentsBackground,
                params: AgentsBackgroundParams(action: .on, durationSeconds: seconds),
                resultType: AgentsBackgroundResult.self)
            print(backgroundSummary(result))
        }
    }

    struct Off: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "off", abstract: "Restore agent priority now")

        mutating func run() throws {
            let result = try SocketClient().call(
                method: RPCMethod.agentsBackground,
                params: AgentsBackgroundParams(action: .off),
                resultType: AgentsBackgroundResult.self)
            print(backgroundSummary(result))
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status", abstract: "Show whether a lease is active")

        @Flag(name: .long, help: "Output JSON")
        var json = false

        mutating func run() throws {
            let result = try SocketClient().call(
                method: RPCMethod.agentsBackground,
                params: AgentsBackgroundParams(action: .status),
                resultType: AgentsBackgroundResult.self)
            if json {
                printJSON(result)
            } else {
                print(backgroundSummary(result))
            }
        }
    }
}
