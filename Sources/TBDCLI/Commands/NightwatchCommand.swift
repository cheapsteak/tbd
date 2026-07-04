import ArgumentParser
import Foundation
import TBDShared

struct NightwatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nightwatch",
        abstract: "Manage nightwatch mode",
        subcommands: [NightwatchSet.self, NightwatchStatus.self]
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
