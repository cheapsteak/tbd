import Foundation
import TBDShared

/// Environment carried by TBD-managed replacement agent processes. The
/// incarnation identifies a process lifetime to SessionStart's transactional
/// CAS; the CLI path keeps hooks on the daemon's matching wire version.
enum AgentProcessEnvironment {
    static let cliPath: String? = {
        guard let argv0 = CommandLine.arguments.first, !argv0.isEmpty else { return nil }
        let executable: URL
        if argv0.hasPrefix("/") {
            executable = URL(fileURLWithPath: argv0)
        } else {
            executable = URL(
                fileURLWithPath: argv0,
                relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        }
        let daemonPath = executable.resolvingSymlinksInPath().standardizedFileURL.path
        return CLIInstaller.cliPath(forDaemonExecutable: daemonPath)
    }()

    static func replacement(
        base: [String: String],
        incarnationID: UUID
    ) -> [String: String] {
        var environment = base
        environment["TBD_TERMINAL_INCARNATION_ID"] = incarnationID.uuidString
        if let cliPath {
            environment["TBD_CLI_PATH"] = cliPath
        }
        return environment
    }
}
