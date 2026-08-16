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
            print("auto-hibernate-on-merge: \(config.autoHibernateOnMergeDefault ? "on" : "off")")
        }
    }
}

struct ConfigSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set a global setting")

    @Argument(help: "Setting key (currently: auto-archive-on-merge, auto-hibernate-on-merge)")
    var key: String

    @Argument(help: "on or off")
    var value: OnOffArgument

    /// What the command says it did.
    ///
    /// Pure, and separated from the call so it can be read — and tested —
    /// against the branch actually taken. A key that explains what it changed
    /// owes two sentences, one per state: a single sentence describing both is
    /// false in one of them, and the user who just turned something off is the
    /// one least able to catch it. Keys that only name the value they were
    /// given fall through to the generic form, which satisfies that rule by
    /// construction.
    static func confirmation(key: String, value: OnOffArgument) -> String {
        "Set \(key) default to \(value.rawValue)."
    }

    mutating func run() async throws {
        let client = SocketClient()
        switch key {
        case "auto-archive-on-merge":
            try client.callVoid(
                method: RPCMethod.configSetAutoArchiveOnMergeDefault,
                params: ConfigSetAutoArchiveDefaultParams(enabled: value.boolValue))
            print(Self.confirmation(key: key, value: value))
        case "auto-hibernate-on-merge":
            try client.callVoid(
                method: RPCMethod.configSetAutoHibernateOnMergeDefault,
                params: ConfigSetAutoHibernateDefaultParams(enabled: value.boolValue))
            print(Self.confirmation(key: key, value: value))
        default:
            throw CLIError.invalidArgument("Unknown config key '\(key)'. Known keys: auto-archive-on-merge, auto-hibernate-on-merge")
        }
    }
}
