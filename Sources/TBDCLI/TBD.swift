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
            ConfigCommand.self,
            TerminalCommand.self,
            NotifyCommand.self,
            SessionEventCommand.self,
            TerminalActivityEventCommand.self,
            AskUserQuestionEventCommand.self,
            DaemonCommand.self,
            HooksCommand.self,
            SetupHooksCommand.self,
            CleanupCommand.self,
            LinkCommand.self,
            DoctorCommand.self,
        ]
    )
}
