import ArgumentParser
import TBDShared

@main
struct TBDCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tbd",
        abstract: "TBD workspace manager CLI",
        version: TBDConstants.version,
        subcommands: [
            RepoCommand.self,
            WorktreeCommand.self,
            TerminalCommand.self,
            NotifyCommand.self,
            DaemonCommand.self,
            SetupHooksCommand.self,
        ]
    )
}
