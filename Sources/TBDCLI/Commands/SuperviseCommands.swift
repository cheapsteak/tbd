import ArgumentParser
import Foundation
import TBDShared

/// `tbd supervise` — the operator surface for fleet supervision
/// (`docs/cli-supervise.md`; `docs/specs/2026-07-26-fleet-supervision-design.md`
/// §10 is normative for these names).
///
/// Every command here routes through the daemon over RPC: the daemon is the
/// single writer of `~/tbd/supervision/`, so the CLI composes params, renders
/// results, and refuses what it can refuse honestly on its own.
struct SuperviseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "supervise",
        abstract: "Operate fleet supervision: the brake, per-project coverage, modes, projects",
        subcommands: [
            SuperviseOn.self,
            SuperviseOff.self,
            SuperviseStatusCommand.self,
            SuperviseMode.self,
            SuperviseProject.self,
        ]
    )
}

// MARK: - on / off

struct SuperviseOn: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "on",
        abstract: "Turn a project's supervision on; bare, release the fleet brake",
        discussion: """
            With a project, sets that project's standing mark — every project \
            starts off, and an untouched project and a turned-off one are the \
            same state.

            With no project, releases the fleet brake. The brake is one bit \
            ANDed over every mark: releasing it writes no mark and restores \
            exactly the coverage that stood.
            """
    )

    @Argument(help: "Project name. Omit to release the fleet brake.")
    var project: String?

    mutating func run() async throws {
        try applySupervisionSwitch(project: project, on: true)
    }
}

struct SuperviseOff: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "off",
        abstract: "Turn a project's supervision off; bare, engage the fleet brake",
        discussion: """
            With a project, clears that project's mark. With no project, \
            engages the fleet brake — TBD's authority to act pauses \
            everywhere, and no mark is touched.
            """
    )

    @Argument(help: "Project name. Omit to engage the fleet brake.")
    var project: String?

    mutating func run() async throws {
        try applySupervisionSwitch(project: project, on: false)
    }
}

/// The one implementation behind `on` and `off`: bare is the fleet brake, a
/// named project is that project's mark. The two never mix — the brake writes
/// no mark, and a mark never moves the brake.
private func applySupervisionSwitch(project: String?, on: Bool) throws {
    guard let raw = project else {
        try SocketClient().callVoid(
            method: RPCMethod.configSetSupervisionEnabled,
            params: ConfigSetSupervisionEnabledParams(enabled: on))
        print(renderSupervisionBrake(on ? .released : .engaged))
        return
    }
    let name = try requireSupervisionProjectName(raw)
    let result: SuperviseSetProjectMarkResult = try SocketClient().call(
        method: RPCMethod.superviseSetProjectMark,
        params: SuperviseSetProjectMarkParams(project: name, on: on),
        resultType: SuperviseSetProjectMarkResult.self)
    print(renderSupervisionMarkResult(result))
}

// MARK: - status

struct SuperviseStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the brake and every project's supervision state"
    )

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let status: SupervisionStatus = try SocketClient().call(
            method: RPCMethod.superviseStatus,
            resultType: SupervisionStatus.self)
        if json {
            printJSON(status)
        } else {
            print(renderSupervisionStatus(status))
        }
    }
}

// MARK: - mode

struct SuperviseMode: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mode",
        abstract: "Show or select a project's active mode",
        discussion: """
            With no mode name, shows the active mode and the declared choices. \
            A name outside the declared list is refused with the choices \
            listed; the conduct a name stands for is the playbook's prose.
            """
    )

    @Argument(help: "Project name")
    var project: String

    @Argument(help: "Mode to select. Omit to show the active mode and the choices.")
    var mode: String?

    mutating func run() async throws {
        let name = try requireSupervisionProjectName(project)
        let client = SocketClient()
        // The declared list rides on the status readout, so a refusal can name
        // the choices without a second round trip after the write is rejected.
        let status: SupervisionStatus = try client.call(
            method: RPCMethod.superviseStatus,
            resultType: SupervisionStatus.self)
        guard let entry = status.projects.first(where: { $0.name == name }) else {
            throw CLIError.invalidArgument(
                "unknown project \"\(name)\" — run 'tbd supervise project list' to see them")
        }
        guard let requested = mode else {
            print(renderSupervisionMode(
                project: entry.name, active: entry.mode, declared: entry.declaredModes))
            return
        }
        if let refusal = supervisionModeRefusal(
            project: entry.name, requested: requested, declared: entry.declaredModes) {
            throw CLIError.invalidArgument(refusal)
        }
        let result: SuperviseSetModeResult = try client.call(
            method: RPCMethod.superviseSetMode,
            params: SuperviseSetModeParams(project: name, mode: requested),
            resultType: SuperviseSetModeResult.self)
        print(renderSupervisionModeResult(result))
    }
}

// MARK: - project

/// The membership vocabulary is deliberately restricted: `move` and no
/// `add`/`remove` pair, because "every repo belongs to exactly one project" is
/// enforced by having no verb that can express anything else.
struct SuperviseProject: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "project",
        abstract: "Declare and edit multi-repo projects",
        subcommands: [
            SuperviseProjectList.self,
            SuperviseProjectCreate.self,
            SuperviseProjectDelete.self,
            SuperviseProjectMove.self,
        ]
    )
}

struct SuperviseProjectList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List projects — declared ones and singletons alike"
    )

    mutating func run() async throws {
        let result: SuperviseProjectListResult = try SocketClient().call(
            method: RPCMethod.superviseProjectList,
            resultType: SuperviseProjectListResult.self)
        print(renderSupervisionProjectList(result))
    }
}

struct SuperviseProjectCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Declare a project over one or more repos"
    )

    @Argument(help: "Project name")
    var name: String

    @Option(name: .long, help: "Comma-separated repo IDs or names")
    var repos: String

    @Option(name: .long, help: "Playbook policy source: repo:<id> or operator")
    var policy: String

    mutating func run() async throws {
        let project = try requireSupervisionProjectName(name)
        let members = try parseSupervisionRepoList(repos)
        let policySource = try parseSupervisionPolicy(policy)
        let result: SuperviseProjectListResult = try SocketClient().call(
            method: RPCMethod.superviseProjectCreate,
            params: SuperviseProjectCreateParams(
                name: project, repos: members, policy: policySource),
            resultType: SuperviseProjectListResult.self)
        print(renderSupervisionProjectList(result))
    }
}

struct SuperviseProjectDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a declaration, returning its repos to being their own projects"
    )

    @Argument(help: "Project name")
    var name: String

    mutating func run() async throws {
        let project = try requireSupervisionProjectName(name)
        let result: SuperviseProjectListResult = try SocketClient().call(
            method: RPCMethod.superviseProjectDelete,
            params: SuperviseProjectDeleteParams(name: project),
            resultType: SuperviseProjectListResult.self)
        print(renderSupervisionProjectList(result))
    }
}

struct SuperviseProjectMove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move a repo into a project, or back to being its own"
    )

    @Argument(help: "Repo ID or name")
    var repo: String

    @Option(name: .long, help: "Destination project, or \"singleton\"")
    var to: String

    mutating func run() async throws {
        let target = try parseSupervisionMoveTarget(to)
        let result: SuperviseProjectListResult = try SocketClient().call(
            method: RPCMethod.superviseProjectMove,
            params: SuperviseProjectMoveParams(repo: repo, to: target.argument),
            resultType: SuperviseProjectListResult.self)
        print(renderSupervisionProjectList(result))
    }
}
