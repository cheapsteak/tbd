import ArgumentParser
import Foundation
import TBDShared

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Get or set global TBD settings",
        subcommands: [ConfigGet.self, ConfigSet.self]
    )
}

struct ConfigGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Show global settings")

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let config = try client.call(method: RPCMethod.configGet, resultType: Config.self)
        if json {
            printJSON(config)
        } else {
            print("auto-archive-on-merge: \(config.autoArchiveOnMergeDefault ? "on" : "off")")
        }
    }
}

struct ConfigSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set a global setting")

    @Argument(help: "Setting key (currently: auto-archive-on-merge)")
    var key: String

    @Argument(help: "on or off")
    var value: OnOffArgument

    mutating func run() async throws {
        let client = SocketClient()
        switch key {
        case "auto-archive-on-merge":
            try client.callVoid(
                method: RPCMethod.configSetAutoArchiveOnMergeDefault,
                params: ConfigSetAutoArchiveDefaultParams(enabled: value.boolValue))
            print("Set auto-archive-on-merge default to \(value.rawValue).")
        default:
            throw CLIError.invalidArgument("Unknown config key '\(key)'. Known keys: auto-archive-on-merge")
        }
    }
}
