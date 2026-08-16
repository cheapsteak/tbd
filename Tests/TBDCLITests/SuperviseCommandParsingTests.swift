import ArgumentParser
import Foundation
import Testing
import TBDShared

@testable import TBDCLI

@Suite("tbd supervise command registration and parsing")
struct SuperviseCommandParsingTests {
    // MARK: registration

    @Test func groupIsRegisteredOnTheRootCommandUnderItsNormativeName() {
        let names = TBDCommand.configuration.subcommands.map { $0._commandName }
        #expect(names.contains("supervise"))
        // The name is `supervise`, not `supervision` (design §10 is normative).
        #expect(!names.contains("supervision"))
        #expect(SuperviseCommand.configuration.commandName == "supervise")
    }

    @Test func groupRegistersEverySubcommand() {
        let names = SuperviseCommand.configuration.subcommands.map { $0._commandName }
        #expect(names.sorted() == ["mode", "off", "on", "project", "status"])
    }

    @Test func projectGroupRegistersOnlyTheRestrictedVocabulary() {
        let names = SuperviseProject.configuration.subcommands.map { $0._commandName }
        #expect(names.sorted() == ["create", "delete", "list", "move"])
        // There is deliberately no add/remove pair: "every repo belongs to
        // exactly one project" is enforced by having no verb for anything else.
        #expect(!names.contains("add"))
        #expect(!names.contains("remove"))
    }

    // MARK: on / off

    @Test func bareOnAndOffParseWithNoProject() throws {
        #expect(try SuperviseOn.parse([]).project == nil)
        #expect(try SuperviseOff.parse([]).project == nil)
    }

    @Test func onAndOffParseAProjectArgument() throws {
        #expect(try SuperviseOn.parse(["acme-checkout"]).project == "acme-checkout")
        #expect(try SuperviseOff.parse(["acme-checkout"]).project == "acme-checkout")
    }

    @Test func rootRoutesBareOnAndProjectOnToTheSameCommand() throws {
        let bare = try TBDCommand.parseAsRoot(["supervise", "on"])
        #expect((bare as? SuperviseOn)?.project == nil)
        let named = try TBDCommand.parseAsRoot(["supervise", "on", "acme-checkout"])
        #expect((named as? SuperviseOn)?.project == "acme-checkout")
        let off = try TBDCommand.parseAsRoot(["supervise", "off", "acme-checkout"])
        #expect((off as? SuperviseOff)?.project == "acme-checkout")
    }

    // MARK: status

    @Test func statusParsesBareAndWithJSONFlag() throws {
        #expect(try SuperviseStatusCommand.parse([]).json == false)
        #expect(try SuperviseStatusCommand.parse(["--json"]).json == true)
        let root = try TBDCommand.parseAsRoot(["supervise", "status", "--json"])
        #expect((root as? SuperviseStatusCommand)?.json == true)
    }

    // MARK: mode

    @Test func modeParsesShowAndSelectForms() throws {
        let show = try SuperviseMode.parse(["acme-checkout"])
        #expect(show.project == "acme-checkout")
        #expect(show.mode == nil)

        let select = try SuperviseMode.parse(["acme-checkout", "autonomous"])
        #expect(select.project == "acme-checkout")
        #expect(select.mode == "autonomous")
    }

    @Test func modeRequiresAProject() {
        #expect(throws: (any Error).self) { _ = try SuperviseMode.parse([]) }
    }

    // MARK: project

    @Test func projectListParses() throws {
        let root = try TBDCommand.parseAsRoot(["supervise", "project", "list"])
        #expect(root is SuperviseProjectList)
    }

    @Test func projectCreateParsesReposAndPolicyFlags() throws {
        let cmd = try SuperviseProjectCreate.parse([
            "acme-platform", "--repos", "acme-web,acme-api", "--policy", "repo:acme-web",
        ])
        #expect(cmd.name == "acme-platform")
        #expect(cmd.repos == "acme-web,acme-api")
        #expect(cmd.policy == "repo:acme-web")
    }

    @Test func projectCreateRequiresBothFlags() {
        #expect(throws: (any Error).self) {
            _ = try SuperviseProjectCreate.parse(["acme-platform", "--repos", "acme-web"])
        }
        #expect(throws: (any Error).self) {
            _ = try SuperviseProjectCreate.parse(["acme-platform", "--policy", "operator"])
        }
    }

    @Test func projectDeleteParsesAName() throws {
        #expect(try SuperviseProjectDelete.parse(["acme-platform"]).name == "acme-platform")
    }

    @Test func projectMoveParsesRepoAndDestination() throws {
        let cmd = try SuperviseProjectMove.parse(["acme-web", "--to", "acme-platform"])
        #expect(cmd.repo == "acme-web")
        #expect(cmd.to == "acme-platform")

        let root = try TBDCommand.parseAsRoot([
            "supervise", "project", "move", "acme-web", "--to", "singleton",
        ])
        #expect((root as? SuperviseProjectMove)?.to == "singleton")
    }

    @Test func projectMoveRequiresADestination() {
        #expect(throws: (any Error).self) { _ = try SuperviseProjectMove.parse(["acme-web"]) }
    }
}

@Suite("tbd supervise argument value parsing")
struct SuperviseArgumentValueTests {
    // MARK: policy flag

    @Test func policyOperatorParses() throws {
        #expect(try parseSupervisionPolicy("operator") == .operator)
    }

    @Test func policyRepoParsesTheIdentifierAsTyped() throws {
        let id = UUID().uuidString
        #expect(try parseSupervisionPolicy("repo:\(id)") == .repo(id))
        #expect(try parseSupervisionPolicy("repo:acme-web") == .repo("acme-web"))
    }

    @Test func policyWithoutTheRepoPrefixIsRefusedNamingTheForms() {
        for bad in ["acme-web", "", "repo:", "repo", "owner"] {
            #expect(throws: CLIError.self) { _ = try parseSupervisionPolicy(bad) }
        }
        do {
            _ = try parseSupervisionPolicy("acme-web")
            Issue.record("expected a refusal")
        } catch let error as CLIError {
            #expect(error.description.contains("repo:<id>"))
            #expect(error.description.contains("operator"))
        } catch {
            Issue.record("expected CLIError, got \(error)")
        }
    }

    // MARK: repos flag

    @Test func reposSplitsOnCommasAndTrims() throws {
        #expect(try parseSupervisionRepoList("acme-web,acme-api") == ["acme-web", "acme-api"])
        #expect(try parseSupervisionRepoList(" acme-web , acme-api ") == ["acme-web", "acme-api"])
        #expect(try parseSupervisionRepoList("acme-web") == ["acme-web"])
    }

    @Test func reposRefusesAnEmptyList() {
        for bad in ["", "   ", ",", " , ", "\n", "\t \n", ",\n,"] {
            #expect(throws: CLIError.self) { _ = try parseSupervisionRepoList(bad) }
        }
    }

    /// A shell-expanded `--repos "$(…)"` arrives with a trailing newline far
    /// more often than with a trailing space.
    @Test func reposStripsTrailingNewlinesFromShellExpandedValues() throws {
        #expect(try parseSupervisionRepoList("acme-web\n") == ["acme-web"])
        #expect(try parseSupervisionRepoList("acme-web,\nacme-api\n") == ["acme-web", "acme-api"])
    }

    @Test func policyToleratesAShellExpandedTrailingNewline() throws {
        #expect(try parseSupervisionPolicy("operator\n") == .operator)
        #expect(try parseSupervisionPolicy("repo:acme-web\n") == .repo("acme-web"))
        #expect(throws: CLIError.self) { _ = try parseSupervisionPolicy("repo:\n") }
    }

    // MARK: to flag

    @Test func moveTargetReadsTheSingletonSentinel() throws {
        #expect(try parseSupervisionMoveTarget("singleton") == .singleton)
        #expect(SupervisionMoveTarget.singletonArgument == "singleton")
    }

    @Test func moveTargetReadsAProjectName() throws {
        #expect(try parseSupervisionMoveTarget("acme-platform") == .project("acme-platform"))
        // A project literally named `singleton` is unreachable by design — the
        // word is the sentinel, and the round trip proves what gets sent.
        #expect(try parseSupervisionMoveTarget("acme-platform").argument == "acme-platform")
        #expect(try parseSupervisionMoveTarget("singleton").argument == "singleton")
    }

    /// The destination is a project name, and a repo display name may carry
    /// surrounding spaces — `isSafeProjectName` permits them. Trimming here
    /// would make `" staging "` visible in `status` and unreachable by `move`.
    @Test func moveTargetKeepsSurroundingSpacesSoSuchProjectsStayAddressable() throws {
        #expect(try parseSupervisionMoveTarget(" staging ") == .project(" staging "))
        #expect(try parseSupervisionMoveTarget(" staging ").argument == " staging ")
        // Quoted spaces around the sentinel were typed deliberately, so they
        // name a project rather than the sentinel.
        #expect(try parseSupervisionMoveTarget(" singleton ") == .project(" singleton "))
    }

    /// The twin of `emptyProjectNameIsRefusedRatherThanReadAsTheBareForm`, and
    /// it covers the newline for the same reason: `CharacterSet.whitespaces`
    /// excludes newlines, so a guard written with it lets `"\t \n"` through as a
    /// name. The two guards are one input class and must be proven together.
    @Test func moveTargetRefusesAnEmptyDestinationIncludingNewlineOnlyWhitespace() {
        #expect(throws: CLIError.self) { _ = try parseSupervisionMoveTarget("") }
        #expect(throws: CLIError.self) { _ = try parseSupervisionMoveTarget("   ") }
        #expect(throws: CLIError.self) { _ = try parseSupervisionMoveTarget("\n") }
        #expect(throws: CLIError.self) { _ = try parseSupervisionMoveTarget("\t \n") }
    }

    // MARK: project names

    @Test func emptyProjectNameIsRefusedRatherThanReadAsTheBareForm() {
        #expect(throws: CLIError.self) { _ = try requireSupervisionProjectName("") }
        #expect(throws: CLIError.self) { _ = try requireSupervisionProjectName("   ") }
        #expect(throws: CLIError.self) { _ = try requireSupervisionProjectName("\t \n") }
    }

    /// A singleton's name is its repo's display name, and `isSafeProjectName`
    /// rejects only genuinely unsafe components — so `" api "` is a project the
    /// operator can see in `status`. Trimming it here would send `api` and earn
    /// an `unknownProject` refusal for a project plainly on screen.
    @Test func projectNameReachesTheDaemonVerbatimIncludingSurroundingSpaces() throws {
        #expect(try requireSupervisionProjectName(" api ") == " api ")
        #expect(try requireSupervisionProjectName("acme-checkout") == "acme-checkout")
        #expect(try requireSupervisionProjectName(" leading") == " leading")
        #expect(try requireSupervisionProjectName("trailing ") == "trailing ")
    }
}
