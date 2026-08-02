import ArgumentParser
import Foundation
import TBDShared

struct NightwatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nightwatch",
        abstract: "Manage nightwatch mode",
        subcommands: [NightwatchSet.self, NightwatchStatus.self, NightwatchLease.self]
    )
}

struct NightwatchLease: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lease",
        abstract: "Inspect and manage exclusive Watch Desk judge ownership",
        subcommands: [
            NightwatchLeaseStatus.self, NightwatchLeaseAcquire.self,
            NightwatchLeaseValidate.self,
            NightwatchLeaseRenew.self, NightwatchLeaseTransfer.self,
            NightwatchLeaseRelease.self,
        ])
}

struct NightwatchLeaseAcquire: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "acquire",
        abstract: "Choose the judge explicitly when an unowned desk has multiple candidates")
    @Option(name: .long) var worktree: String
    @Option(name: .long) var terminal: String
    mutating func run() async throws {
        let result: NightwatchLeaseAcquisitionResult = try SocketClient().call(
            method: RPCMethod.nightwatchLeaseAcquire,
            params: NightwatchLeaseAcquireParams(
                worktreeID: try parseLeaseUUID(worktree, option: "--worktree"),
                terminalID: try parseLeaseUUID(terminal, option: "--terminal")),
            resultType: NightwatchLeaseAcquisitionResult.self)
        printJSON(result)
    }
}

struct LeaseCredentials: ParsableArguments {
    @Option(name: .long, help: "Mode-0600 capability file issued by the daemon")
    var credentialFile: String

    func params() throws -> NightwatchLeaseCredentialsParams {
        let credential: WatchDeskLeaseCredential
        do {
            credential = try WatchDeskLeaseCredentialFile.read(path: credentialFile)
        } catch {
            throw CLIError.invalidArgument(
                "Cannot read --credential-file: \(error.localizedDescription)")
        }
        return NightwatchLeaseCredentialsParams(
            worktreeID: credential.worktreeID,
            terminalID: credential.terminalID,
            token: credential.token,
            generation: credential.generation)
    }
}

private func parseLeaseUUID(_ value: String, option: String) throws -> UUID {
    guard let id = UUID(uuidString: value) else {
        throw CLIError.invalidArgument("Invalid UUID for \(option): \(value)")
    }
    return id
}

struct NightwatchLeaseStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status")
    @Option(name: .long) var worktree: String
    mutating func run() async throws {
        let result: NightwatchLeaseStatusResult = try SocketClient().call(
            method: RPCMethod.nightwatchLeaseStatus,
            params: NightwatchLeaseStatusParams(
                worktreeID: try parseLeaseUUID(worktree, option: "--worktree")),
            resultType: NightwatchLeaseStatusResult.self)
        printJSON(result)
    }
}

struct NightwatchLeaseValidate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "validate")
    @OptionGroup var credentials: LeaseCredentials
    mutating func run() async throws {
        let result: WatchDeskLeaseSnapshot = try SocketClient().call(
            method: RPCMethod.nightwatchLeaseValidate, params: try credentials.params(),
            resultType: WatchDeskLeaseSnapshot.self)
        printJSON(result)
    }
}

struct NightwatchLeaseRenew: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "renew")
    @OptionGroup var credentials: LeaseCredentials
    mutating func run() async throws {
        let result: WatchDeskLeaseSnapshot = try SocketClient().call(
            method: RPCMethod.nightwatchLeaseRenew, params: try credentials.params(),
            resultType: WatchDeskLeaseSnapshot.self)
        printJSON(result)
    }
}

struct NightwatchLeaseTransfer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "transfer")
    @OptionGroup var credentials: LeaseCredentials
    @Option(name: .long) var toTerminal: String
    mutating func run() async throws {
        let source = try credentials.params()
        let result: NightwatchLeaseAcquisitionResult = try SocketClient().call(
            method: RPCMethod.nightwatchLeaseTransfer,
            params: NightwatchLeaseTransferParams(
                worktreeID: source.worktreeID,
                fromTerminalID: source.terminalID,
                toTerminalID: try parseLeaseUUID(toTerminal, option: "--to-terminal"),
                token: source.token, generation: source.generation),
            resultType: NightwatchLeaseAcquisitionResult.self)
        printJSON(result)
    }
}

struct NightwatchLeaseRelease: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "release")
    @OptionGroup var credentials: LeaseCredentials
    mutating func run() async throws {
        try SocketClient().callVoid(
            method: RPCMethod.nightwatchLeaseRelease, params: try credentials.params())
        print("Nightwatch judge lease released")
    }
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
