import ArgumentParser
import Foundation
import TBDShared

struct NightwatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nightwatch",
        abstract: "Manage nightwatch mode",
        subcommands: [NightwatchSet.self, NightwatchStatus.self, NightwatchReport.self]
    )
}

// MARK: - nightwatch set

struct NightwatchSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set the nightwatch mode"
    )

    @Argument(help: "Mode: off, daywatch, or nightwatch")
    var mode: String

    mutating func run() async throws {
        guard let nightwatchMode = NightwatchMode(rawValue: mode) else {
            throw CLIError.invalidArgument("Invalid mode: \(mode). Must be 'off', 'daywatch', or 'nightwatch'.")
        }

        let client = SocketClient()
        try client.callVoid(
            method: RPCMethod.nightwatchSetMode,
            params: NightwatchSetModeParams(mode: nightwatchMode)
        )

        print("Nightwatch mode set to: \(mode)")
    }
}

// MARK: - nightwatch status

struct NightwatchStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Get the current nightwatch mode"
    )

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        // Ride the existing config.get RPC — Config carries nightwatchMode.
        let config: Config = try client.call(
            method: RPCMethod.configGet,
            resultType: Config.self
        )

        if json {
            printJSON(["mode": config.nightwatchMode.rawValue])
        } else {
            print("Nightwatch mode: \(config.nightwatchMode.rawValue)")
        }
    }
}

// MARK: - nightwatch report

struct NightwatchReport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Get the nightwatch audit log report"
    )

    @Option(name: .long, help: "Start time (ISO8601 format)")
    var since: String?

    @Option(name: .long, help: "Filter by action: wouldMerge, hold, escalate, or clearanceVoided")
    var action: String?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()

        // Parse since date if provided
        var sinceDate: Date?
        if let sinceStr = since {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: sinceStr) {
                sinceDate = date
            } else {
                throw CLIError.invalidArgument("Invalid ISO8601 date: \(sinceStr)")
            }
        }

        // Parse action if provided
        var auditAction: AuditAction?
        if let actionStr = action {
            auditAction = AuditAction(rawValue: actionStr)
            if auditAction == nil {
                throw CLIError.invalidArgument(
                    "Invalid action: \(actionStr). Must be: wouldMerge, hold, escalate, or clearanceVoided"
                )
            }
        }

        let entries: [AuditLogEntry] = try client.call(
            method: RPCMethod.nightwatchReport,
            params: NightwatchReportParams(since: sinceDate, action: auditAction),
            resultType: [AuditLogEntry].self
        )

        if json {
            printJSON(entries)
        } else {
            // Human-readable output: one line per entry
            if entries.isEmpty {
                print("No audit entries found.")
            } else {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

                for entry in entries {
                    let ts = dateFormatter.string(from: entry.timestamp)
                    let prStr = entry.prNumber.map { "#\($0)" } ?? "—"
                    let repo = entry.repo ?? "—"
                    let sha = entry.headSHA.map { String($0.prefix(8)) } ?? "—"
                    print("\(ts) [\(entry.action.rawValue)] PR \(prStr) (\(repo) \(sha))")
                    if let details = entry.details {
                        print("  Details: \(details)")
                    }
                }
            }
        }
    }
}
