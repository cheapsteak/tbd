import ArgumentParser
import Foundation
import TBDShared

struct SkillCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skill",
        abstract: "Manage the TBD agent skill installed in your harness",
        subcommands: [SkillStatusCommand.self, SkillInstallCommand.self]
    )
}

struct SkillStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show whether the TBD skill is installed and up to date"
    )

    mutating func run() async throws {
        let client = SocketClient()
        guard client.isDaemonRunning else {
            FileHandle.standardError.write(Data("TBD daemon is not running.\n".utf8))
            throw ExitCode(2)
        }

        let req = try RPCRequest(method: RPCMethod.skillStatus, params: SkillStatusParams())
        let resp = try client.send(req)
        guard resp.success, let resultJSON = resp.result else {
            FileHandle.standardError.write(Data("Error: \(resp.error ?? "unknown")\n".utf8))
            throw ExitCode(1)
        }
        let result = try JSONDecoder().decode(SkillStatusResult.self, from: Data(resultJSON.utf8))

        // Stdout: the path. Stderr: the human-readable status.
        print(result.harnessPath)
        let label: String
        switch result.status {
        case .upToDate: label = "installed (up to date)"
        case .outdated: label = "installed (outdated)"
        case .notInstalled: label = "not installed"
        case .harnessNotDetected: label = "harness not detected"
        }
        FileHandle.standardError.write(Data("status: \(label)\n".utf8))

        // Exit code: 0 only when fully current.
        if result.status != .upToDate {
            throw ExitCode(1)
        }
    }
}

struct SkillInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install or update the TBD skill in your harness"
    )

    mutating func run() async throws {
        let client = SocketClient()
        guard client.isDaemonRunning else {
            FileHandle.standardError.write(Data("TBD daemon is not running.\n".utf8))
            throw ExitCode(2)
        }

        let req = try RPCRequest(method: RPCMethod.skillInstall, params: SkillInstallParams())
        let resp = try client.send(req)
        guard resp.success, let resultJSON = resp.result else {
            FileHandle.standardError.write(Data("Error: \(resp.error ?? "unknown")\n".utf8))
            throw ExitCode(1)
        }
        let result = try JSONDecoder().decode(SkillInstallResultRPC.self, from: Data(resultJSON.utf8))

        print(result.path)
        let label: String
        switch result.action {
        case .installed: label = "installed"
        case .updated: label = "updated"
        case .noop: label = "already up to date"
        }
        FileHandle.standardError.write(Data("\(label)\n".utf8))
    }
}
