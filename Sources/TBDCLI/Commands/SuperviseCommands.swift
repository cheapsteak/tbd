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
            SupervisePlaybook.self,
            SuperviseReadoutCommand.self,
            SuperviseBriefCommand.self,
            SuperviseLedgerCommand.self,
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
    let client = SocketClient()
    guard let raw = project else {
        try client.callVoid(
            method: RPCMethod.configSetSupervisionEnabled,
            params: ConfigSetSupervisionEnabledParams(enabled: on))
        print(renderSupervisionBrake(on ? .released : .engaged))
        if on { warnAfterSupervisionGesture(client: client) }
        return
    }
    let name = try requireSupervisionProjectName(raw)
    let result: SuperviseSetProjectMarkResult = try client.call(
        method: RPCMethod.superviseSetProjectMark,
        params: SuperviseSetProjectMarkParams(project: name, on: on),
        resultType: SuperviseSetProjectMarkResult.self)
    print(renderSupervisionMarkResult(result))
    if on { warnAfterSupervisionGesture(client: client) }
}

/// Say so, at the gesture, when what the operator just switched on covers
/// nothing: the brake released over an unmarked fleet, or a mark set while the
/// brake is engaged.
///
/// Runs only for `on`, never `off`. Turning something off is a deliberate
/// reduction of coverage — the operator is not forming a mistaken belief, and a
/// line telling them what they just chose is the noise that teaches people to
/// stop reading the line.
///
/// Best-effort by construction, and in that order for a reason: the switch has
/// already taken effect by the time this runs, so a readout that fails must not
/// turn a gesture that succeeded into a nonzero exit. It stays quiet only when
/// it has read the state and found nothing to say — a readout it could not take
/// is reported as a readout it could not take, never as a calm night.
///
/// The lines go to stderr because the command's data is its one result line;
/// under `status` the same lines are part of the readout and belong on stdout.
private func warnAfterSupervisionGesture(client: SocketClient) {
    let status: SupervisionStatus
    do {
        status = try client.call(
            method: RPCMethod.superviseStatus,
            resultType: SupervisionStatus.self)
    } catch {
        printToStandardError(
            "warning: the change took effect, but supervision state could not be read "
                + "(\(error)) — run 'tbd supervise status'")
        return
    }
    for line in supervisionGestureWarningLines(status) {
        printToStandardError(line)
    }
}

private func printToStandardError(_ line: String) {
    FileHandle.standardError.write(Data("\(line)\n".utf8))
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

// MARK: - playbook

/// `tbd supervise playbook` — read the standing conduct a project's supervisor
/// stands on, and take ownership of a level of it.
///
/// Both subcommands route through the daemon: it is the single reader of
/// `supervision.json`, so it is the only place that knows whether a project is
/// declared — which decides where its operator level lives — and the single
/// writer of `~/tbd/supervision/`.
struct SupervisePlaybook: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "playbook",
        abstract: "Show a project's resolved playbook, or take ownership of a level of it",
        subcommands: [
            SupervisePlaybookShow.self,
            SupervisePlaybookCustomize.self,
        ]
    )
}

struct SupervisePlaybookShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show which playbook level stands for a project, its path and its hash",
        discussion: """
            Resolution runs per project, three levels, first existing \
            non-empty file wins: the operator's copy, then the project's \
            designated repo file, then the shipped default. The whole file is \
            used and levels are never merged.

            TBD never parses a playbook. It resolves the path, hashes the \
            bytes, and installs them verbatim as the supervisor's standing \
            conduct; the hash is what a delivery records as the conduct it ran \
            under.
            """
    )

    @Option(name: .long, help: "Project name")
    var project: String

    @Flag(name: .long, help: "Print the playbook's bytes after the header")
    var content = false

    @Flag(name: .long, help: "Output JSON (always carries the content)")
    var json = false

    mutating func run() async throws {
        let name = try requireSupervisionProjectName(project)
        let view: SupervisionPlaybookView = try SocketClient().call(
            method: RPCMethod.supervisePlaybook,
            params: SupervisePlaybookParams(project: name),
            resultType: SupervisionPlaybookView.self)
        if json {
            printJSON(view)
            return
        }
        print(renderSupervisionPlaybook(view, includeContent: content))
        for line in supervisionPlaybookSkipLines(view) {
            printToStandardError(line)
        }
    }
}

/// The "Customize playbook…" action: copy the current shipped default into a
/// level the operator then owns.
///
/// **Write-once, and refused if the file is already there.** TBD writes these
/// levels exactly once and never again — it does not overwrite them, merge into
/// them, or reconcile them at startup. The copy is yours from that moment.
struct SupervisePlaybookCustomize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "customize",
        abstract:
            "Copy the shipped playbook into the operator level, or with --repo-level the repo level",
        discussion: """
            Writes the current shipped default and prints the path. Refused if \
            that level already exists: TBD writes it exactly once and never \
            touches it again, so an existing copy is edited directly.

            Without --repo-level the copy goes to the operator level — beside a \
            declared project's definition, or in a singleton's per-repo config \
            directory. With --repo-level it goes to the project's designated \
            repo file, .agents/supervision.md in that repo's main checkout, \
            where it is committed and shared with everyone working in the repo.
            """
    )

    @Option(name: .long, help: "Project name")
    var project: String

    /// Named for the *level*, not the repo. Everywhere else in this CLI
    /// `--repo` takes a value naming one — `tbd worktree list --repo <name>`,
    /// `tbd gc --repo <path>` — so a boolean `--repo` here would answer a
    /// typed-out repo id with an opaque "unexpected argument".
    @Flag(name: .long,
          help: "Write the project's designated repo file instead of the operator level")
    var repoLevel = false

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let name = try requireSupervisionProjectName(project)
        let result: SupervisePlaybookCustomizeResult = try SocketClient().call(
            method: RPCMethod.supervisePlaybookCustomize,
            params: SupervisePlaybookCustomizeParams(
                project: name, level: repoLevel ? .repo : .operator),
            resultType: SupervisePlaybookCustomizeResult.self)
        if json {
            printJSON(result)
        } else {
            print(renderSupervisionPlaybookCustomize(result))
        }
    }
}

// MARK: - the sweep program's three surfaces

/// `tbd supervise readout --project <name>` — the project's whole current
/// picture, read-only.
///
/// **There is no `--json` flag, because JSON is the only output this surface
/// has.** Its consumer is a program: the sweep program's opening move
/// (`docs/specs/2026-08-01-fleet-supervision-sweep-program-design.md` §3), and
/// an operator reaching for one fact reaches for `jq`. A second rendering would
/// be a second contract to keep, and the readout is far too wide for a table.
/// The result carries its own `schemaVersion`, so nothing is wrapped here.
struct SuperviseReadoutCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "readout",
        abstract: "Print the project's live-agent, supervisor and machinery facts as JSON",
        discussion: """
            Read-only: it prints and changes nothing else. Every fact that is \
            unknown is present and null rather than absent, so a reader never \
            has to guess whether a value was unestablished or the writer was an \
            older build.
            """
    )

    @Option(name: .long, help: "Project name")
    var project: String

    mutating func run() async throws {
        let name = try requireSupervisionProjectName(project)
        let readout: SupervisionReadout = try SocketClient().call(
            method: RPCMethod.superviseReadout,
            params: SuperviseReadoutParams(project: name),
            resultType: SupervisionReadout.self)
        printJSON(readout)
    }
}

/// `tbd supervise ledger --project <name> --since <t>` — the joined per-project
/// record since an instant, read-only.
struct SuperviseLedgerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ledger",
        abstract: "Print the joined per-project record since <t> as JSON",
        discussion: """
            --since takes a full ISO-8601 timestamp with an offset or Z \
            (2026-08-15T02:10:00Z), a bare 24-hour HH:MM resolved to its most \
            recent past occurrence in local time (22:00), or a bare relative \
            duration meaning that long ago (90s, 30m, 2h, 3d).

            The value is resolved to an absolute instant before the query runs, \
            so the window's lower bound is fixed at the moment you invoked the \
            command rather than re-derived while it executes. That instant is \
            what the result echoes back in "since".
            """
    )

    @Option(name: .long, help: "Project name")
    var project: String

    @Option(name: .long, help: "Window lower bound: ISO-8601, HH:MM, or a duration like 30m")
    var since: String

    mutating func run() async throws {
        let name = try requireSupervisionProjectName(project)
        // Refused here, before any socket call: an unreadable `--since` is a
        // thing the CLI can refuse honestly on its own.
        let lowerBound = try parseSupervisionSince(since, now: Date())
        let view: SupervisionLedgerView = try SocketClient().call(
            method: RPCMethod.superviseLedger,
            params: SuperviseLedgerParams(
                project: name, since: SupervisionInstant(lowerBound)),
            resultType: SupervisionLedgerView.self)
        printJSON(view)
    }
}

/// `tbd supervise brief --project <name>` — submit a composed briefing, with the
/// text on stdin.
///
/// **Stdin, and read to EOF, with no TTY check.** The briefing is composed by a
/// program and piped in; a check that refused a non-terminal stdin would refuse
/// the only way this command is actually called. Closed stdin reads as EOF
/// immediately rather than hanging.
///
/// **Every submission is sent, and none is refused locally.** An empty one is
/// valid and meaningful — the attested "looked, found nothing" that keeps the
/// project's liveness contact fresh while delivering nothing — and an oversize
/// one is sent too, because the pipeline records contact before it refuses
/// anything (see `supervisionBriefParams`). A briefing this command turned away
/// itself would move no liveness record, and a broken composer would then read
/// as a silent one.
///
/// **The streams split**: the result goes to stdout as JSON, carrying the
/// machine-readable `result` a program branches on, and the human sentence goes
/// to stderr. `$(… | tbd supervise brief --project acme-platform)` captures the
/// JSON and nothing else.
struct SuperviseBriefCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "brief",
        abstract: "Submit a composed briefing for the project's supervisor (text on stdin)",
        discussion: """
            The briefing text is read from stdin to EOF and delivered verbatim; \
            TBD never parses it. An empty submission is still a submission — the \
            attested "looked, found nothing" — and is never rate-limited.

            Exit codes: 0 when delivered, 75 when the fleet brake is engaged \
            (retry when supervision resumes), nonzero otherwise. Branch on the \
            "result" value in the JSON for which refusal it was.
            """
    )

    @Option(name: .long, help: "Project name")
    var project: String

    mutating func run() async throws {
        let name = try requireSupervisionProjectName(project)
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        let result: SupervisionBriefResult = try SocketClient().call(
            method: RPCMethod.superviseBrief,
            params: supervisionBriefParams(project: name, stdin: stdin),
            resultType: SupervisionBriefResult.self)

        printJSON(result)
        printToStandardError(result.detail)
        let code = supervisionBriefExitCode(result.result)
        guard code == 0 else { throw ExitCode(code) }
    }
}
