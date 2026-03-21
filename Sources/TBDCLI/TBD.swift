import ArgumentParser
import TBDShared

@main
struct TBDCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tbd",
        abstract: "TBD workspace manager CLI",
        version: TBDConstants.version
    )
}
