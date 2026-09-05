import ArgumentParser
import Foundation
import TBDShared

struct DaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Daemon management",
        subcommands: [DaemonStatus.self]
    )
}

// MARK: - daemon status

struct DaemonStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show daemon status"
    )

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let status: DaemonStatusResult = try client.call(
            method: RPCMethod.daemonStatus,
            resultType: DaemonStatusResult.self
        )

        if json {
            printJSON(status)
        } else {
            print(DaemonStatusReport.render(status))
        }
    }
}

/// The text form of `tbd daemon status`.
///
/// Pure so the two conditional lines — a daemon whose build identity could not
/// be learned, and one that has never checked for an update — are assertable
/// without a running daemon.
enum DaemonStatusReport {
    static func render(_ status: DaemonStatusResult) -> String {
        var lines = [
            "TBD Daemon Status",
            "  Version:           \(status.version)",
            "  Uptime:            \(formatUptime(status.uptime))",
            "  Connected clients: \(status.connectedClients)",
        ]
        if let identity = status.buildIdentity {
            lines.append("  Build:             \(VersionReport.describe(identity))")
        }
        if let update = status.update {
            lines.append("  Update:            \(VersionReport.verdict(daemon: status.buildIdentity, update: update))")
        }
        return lines.joined(separator: "\n")
    }
}

/// Format a TimeInterval as a human-readable uptime string.
func formatUptime(_ seconds: TimeInterval) -> String {
    let totalSeconds = Int(seconds)
    let days = totalSeconds / 86400
    let hours = (totalSeconds % 86400) / 3600
    let minutes = (totalSeconds % 3600) / 60
    let secs = totalSeconds % 60

    if days > 0 {
        return "\(days)d \(hours)h \(minutes)m"
    } else if hours > 0 {
        return "\(hours)h \(minutes)m \(secs)s"
    } else if minutes > 0 {
        return "\(minutes)m \(secs)s"
    } else {
        return "\(secs)s"
    }
}
