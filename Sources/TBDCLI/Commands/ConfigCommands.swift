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

    /// The text form, composed away from the RPC so every key's rendering is
    /// assertable against a `Config` value rather than a running daemon.
    static func render(_ config: Config) -> String {
        [
            "auto-archive-on-merge: \(config.autoArchiveOnMergeDefault ? "on" : "off")",
            "auto-hibernate-on-merge: \(config.autoHibernateOnMergeDefault ? "on" : "off")",
            "update-mode: \(config.updateMode.rawValue)",
        ].joined(separator: "\n")
    }

    mutating func run() async throws {
        let client = SocketClient()
        let config = try client.call(method: RPCMethod.configGet, resultType: Config.self)
        if json {
            printJSON(config)
        } else {
            print(ConfigGet.render(config))
        }
    }
}

struct ConfigSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set a global setting")

    /// Every key this command accepts, in the order `--help` lists them.
    ///
    /// Not every key takes the same values — `update-mode` is a three-way
    /// choice, the merge defaults are on/off — so the KEY decides what the
    /// value argument is allowed to be. The value therefore arrives as a raw
    /// string and is parsed per key, rather than as a type that could only ever
    /// express one key's vocabulary.
    static let onOffKeys = ["auto-archive-on-merge", "auto-hibernate-on-merge"]
    static let modeKeys = ["update-mode"]
    static var allKeys: [String] { onOffKeys + modeKeys }

    @Argument(help: "Setting key (auto-archive-on-merge, auto-hibernate-on-merge, update-mode)")
    var key: String

    @Argument(help: "on|off for the merge defaults; off|check|auto for update-mode")
    var value: String

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

    /// The update mode's confirmation. Three states, and each one changes what
    /// the daemon will do on its own, so each says what that is rather than
    /// only naming the value.
    static func confirmation(mode: UpdateMode) -> String {
        switch mode {
        case .off:
            return "Set update-mode to off. The daemon will not check for updates or install them."
        case .check:
            return "Set update-mode to check. The daemon will notice a newer main and say so; it will not install anything. Takes effect at the next check."
        case .auto:
            return "Set update-mode to auto. The daemon will build and install a newer main on its own, restarting the daemon and app. Takes effect at the next check."
        }
    }

    /// Parse an on/off value, naming the key in the rejection so a user who
    /// passed `auto` to a two-state key learns which key was wrong.
    static func parseOnOff(_ raw: String, key: String) throws -> OnOffArgument {
        guard let parsed = OnOffArgument(rawValue: raw) else {
            throw CLIError.invalidArgument(
                "'\(raw)' is not a value for \(key). Expected: on, off")
        }
        return parsed
    }

    /// Parse an update mode. Its rejection lists all three values, because the
    /// likeliest mistake here is reaching for `on`.
    static func parseUpdateMode(_ raw: String) throws -> UpdateMode {
        guard let parsed = UpdateMode(rawValue: raw) else {
            throw CLIError.invalidArgument(
                "'\(raw)' is not a value for update-mode. Expected: off, check, auto")
        }
        return parsed
    }

    static func unknownKeyMessage(_ key: String) -> String {
        "Unknown config key '\(key)'. Known keys: \(allKeys.joined(separator: ", "))"
    }

    mutating func run() async throws {
        let client = SocketClient()
        switch key {
        case "auto-archive-on-merge":
            let parsed = try Self.parseOnOff(value, key: key)
            try client.callVoid(
                method: RPCMethod.configSetAutoArchiveOnMergeDefault,
                params: ConfigSetAutoArchiveDefaultParams(enabled: parsed.boolValue))
            print(Self.confirmation(key: key, value: parsed))
        case "auto-hibernate-on-merge":
            let parsed = try Self.parseOnOff(value, key: key)
            try client.callVoid(
                method: RPCMethod.configSetAutoHibernateOnMergeDefault,
                params: ConfigSetAutoHibernateDefaultParams(enabled: parsed.boolValue))
            print(Self.confirmation(key: key, value: parsed))
        case "update-mode":
            let mode = try Self.parseUpdateMode(value)
            try client.callVoid(
                method: RPCMethod.configSetUpdateMode,
                params: ConfigSetUpdateModeParams(mode: mode))
            print(Self.confirmation(mode: mode))
        default:
            throw CLIError.invalidArgument(Self.unknownKeyMessage(key))
        }
    }
}
