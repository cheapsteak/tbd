import Foundation
import Testing
import ArgumentParser

@testable import TBDCLI

@Suite("DoctorCommand")
struct DoctorCommandTests {
    @Test func registeredAsSubcommand() {
        let names = TBDCommand.configuration.subcommands.map { String(describing: $0) }
        #expect(names.contains("DoctorCommand"))
    }

    @Test func parsesWithoutArgs() throws {
        let cmd = try DoctorCommand.parse([])
        #expect(cmd.dryRun == false)
    }

    @Test func parsesDryRunFlag() throws {
        let cmd = try DoctorCommand.parse(["--dry-run"])
        #expect(cmd.dryRun == true)
    }

    @Test func helpMentionsRepair() {
        let help = DoctorCommand.helpMessage()
        #expect(help.contains("doctor"))
        #expect(help.contains("--dry-run"))
    }
}
