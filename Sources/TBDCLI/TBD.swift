import ArgumentParser
import TBDShared

@main
struct TBDCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tbd",
        abstract: "TBD workspace manager CLI",
        // Carries the build's short commit when this binary has a sidecar
        // beside it. Sidecar-only by design — `--version` and `--help` must not
        // spawn a subprocess, and hooks invoke this CLI many times a minute.
        version: CLIBuildIdentity.versionString,
        subcommands: [
            RepoCommand.self,
            WorktreeCommand.self,
            ScratchCommand.self,
            ConfigCommand.self,
            ProfileCommand.self,
            TerminalCommand.self,
            PeerCommand.self,
            RemoteCommand.self,
            PanelCommand.self,
            NotifyCommand.self,
            SessionEventCommand.self,
            TerminalActivityEventCommand.self,
            SessionEndCommand.self,
            AskUserQuestionEventCommand.self,
            DaemonCommand.self,
            VersionCommand.self,
            UpdateCommand.self,
            HooksCommand.self,
            SetupHooksCommand.self,
            CleanupCommand.self,
            LinkCommand.self,
            DoctorCommand.self,
            NightwatchCommand.self,
            SuperviseCommand.self,
            GCCommand.self,
            PRCommand.self,
        ]
    )
}
