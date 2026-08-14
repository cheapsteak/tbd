import Foundation
import TBDShared

// Pure composition for the `tbd supervise` surface: every function here takes
// the DTO the daemon answered with and returns the exact text a human or a
// program sees. Nothing here talks to the daemon, so the loud cases can be
// asserted on the composed output rather than on an internal boolean.

// MARK: - status

/// The sentence a warning code gets when the daemon supplied no message of its
/// own. The CLI carries its own wording so the loud case cannot be silenced by
/// an empty string arriving over the wire.
///
/// The switch is deliberately exhaustive, with no `default` arm. A code this
/// enum does not know cannot reach here — `SupervisionWarningCode` is one
/// `TBDShared` type compiled into both the daemon and this CLI, and an
/// unrecognized raw value fails to decode in `SocketClient` long before
/// rendering — so a `default` would be unreachable rather than protective. What
/// it would actually buy is silence when a later slice adds a warning: the code
/// would render as boilerplate instead of as words, which is the quiet failure
/// this whole surface exists to prevent. The compile error is the forcing
/// function that makes every new warning get a human sentence.
func supervisionWarningSentence(_ code: SupervisionWarningCode) -> String {
    switch code {
    case .noProjectsOn:
        return "the brake is released but no project is on — nothing is being supervised."
    case .unusableProjectName:
        return """
            a project's name cannot be used as a directory name, so nothing can be \
            written beside it — no playbook, journal, proposals or programs. It is \
            supervised like any other project; rename the repo to give it a directory.
            """
    }
}

/// The loud lines that precede the per-project rows.
///
/// A fleet switched on with nothing marked on is the quiet failure this design
/// fears: an account that looks peaceful because nothing was watched. So the
/// line is composed from the facts the status carries — `brake` released with
/// `effectivelySupervising` false means exactly "nothing is being supervised" —
/// rather than only from the daemon's `warnings` array, which would let a
/// daemon that forgot to warn render a calm night.
func supervisionStatusWarningLines(_ status: SupervisionStatus) -> [String] {
    var lines: [String] = []
    var sawNoProjectsOn = false
    for warning in status.warnings {
        if warning.code == .noProjectsOn { sawNoProjectsOn = true }
        let supplied = warning.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = supplied.isEmpty ? supervisionWarningSentence(warning.code) : supplied
        lines.append("warning: \(message)")
    }
    if !sawNoProjectsOn && status.brake == .released && !status.effectivelySupervising {
        lines.append("warning: \(supervisionWarningSentence(.noProjectsOn))")
    }
    return lines
}

/// Compose the human-readable `tbd supervise status` readout: the brake, the
/// loud lines, then one row per project.
///
/// `now` and `timeZone` are seams so the rendering is a pure function of its
/// inputs — a status rendered in a test reads the same in every timezone.
func renderSupervisionStatus(
    _ status: SupervisionStatus,
    now: Date = Date(),
    timeZone: TimeZone = .current
) -> String {
    var lines = ["brake: \(status.brake.rawValue)"]
    lines.append(contentsOf: supervisionStatusWarningLines(status))

    guard !status.projects.isEmpty else {
        lines.append("(no projects)")
        return lines.joined(separator: "\n")
    }

    let cells = status.projects.map { project in
        (
            name: project.name,
            state: supervisionStateCell(project, timeZone: timeZone),
            mode: "mode \(project.mode)",
            supervisor: supervisionSupervisorCell(project.supervisor),
            contact: supervisionContactCell(project, now: now),
            coverage: supervisionCoverageCell(project)
        )
    }
    let nameWidth = cells.map { $0.name.count }.max() ?? 0
    let stateWidth = cells.map { $0.state.count }.max() ?? 0
    let modeWidth = cells.map { $0.mode.count }.max() ?? 0
    let supervisorWidth = cells.map { $0.supervisor.count }.max() ?? 0
    let contactWidth = cells.map { $0.contact.count }.max() ?? 0

    for cell in cells {
        lines.append(tableRow([
            (cell.name, nameWidth),
            (cell.state, stateWidth),
            (cell.mode, modeWidth),
            (cell.supervisor, supervisorWidth),
            (cell.contact, contactWidth),
            (cell.coverage, 0),
        ]))
    }
    return lines.joined(separator: "\n")
}

/// An untouched project and a turned-off one are the same state, so an off
/// project renders exactly `off` — never a span, never a "was on until" — even
/// when the record still carries an opening instant. A third rendering would
/// be a third tier.
private func supervisionStateCell(
    _ project: SupervisionStatusProject, timeZone: TimeZone
) -> String {
    guard project.on else { return "off" }
    guard let started = project.spanStartedAt else { return "on" }
    return "on since \(supervisionClockTime(started.date, timeZone: timeZone))"
}

private func supervisionSupervisorCell(
    _ supervisor: SupervisionSupervisorArrangement
) -> String {
    switch supervisor.kind {
    case .hostedDesk:
        return "supervisor: hosted desk"
    case .appointed:
        guard let terminal = supervisor.terminal, !terminal.isEmpty else {
            return "supervisor: appointed"
        }
        return "supervisor: appointed (\(terminal))"
    }
}

private func supervisionContactCell(
    _ project: SupervisionStatusProject, now: Date
) -> String {
    guard let contact = project.lastSweepContactAt else {
        return "last sweep contact: never"
    }
    return "last sweep contact: \(supervisionAge(from: contact.date, to: now))"
}

/// A project with no declared contact window reports `coverage unknown` — the
/// honest not-yet value. Nothing here invents a coverage claim.
private func supervisionCoverageCell(_ project: SupervisionStatusProject) -> String {
    guard let window = project.coverageWindow, !window.isEmpty else {
        return "coverage unknown"
    }
    return "coverage \(window)"
}

func supervisionClockTime(_ date: Date, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

func supervisionAge(from: Date, to now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(from).rounded()))
    if seconds < 60 { return "\(seconds)s ago" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m ago" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h ago" }
    return "\(hours / 24)d ago"
}

// MARK: - marks and modes

func renderSupervisionMarkResult(_ result: SuperviseSetProjectMarkResult) -> String {
    let state = result.on ? "on" : "off"
    return result.changed
        ? "\(state): \(result.project)"
        : "\(state): \(result.project) (already \(state))"
}

func renderSupervisionBrake(_ brake: SupervisionBrakeState) -> String {
    "brake: \(brake.rawValue)"
}

func renderSupervisionMode(project: String, active: String, declared: [String]) -> String {
    let choices = declared.isEmpty ? "(none declared)" : declared.joined(separator: ", ")
    return "mode: \(project) is \(active)   choices: \(choices)"
}

func renderSupervisionModeResult(_ result: SuperviseSetModeResult) -> String {
    let head = result.changed
        ? "mode: \(result.project) is now \(result.mode)"
        : "mode: \(result.project) was already \(result.mode)"
    guard !result.declaredModes.isEmpty else { return head }
    return head + "   choices: " + result.declaredModes.joined(separator: ", ")
}

/// The refusal a mode outside the project's declared list gets, or nil when the
/// name is one of the choices. The choices ride along because a refusal that
/// does not say what would have worked makes the operator go look.
func supervisionModeRefusal(
    project: String, requested: String, declared: [String]
) -> String? {
    guard !declared.contains(requested) else { return nil }
    let choices = declared.isEmpty ? "(none declared)" : declared.joined(separator: ", ")
    return "mode \"\(requested)\" is not declared for project \"\(project)\" — choices: \(choices)"
}

// MARK: - projects

func renderSupervisionProjectList(_ result: SuperviseProjectListResult) -> String {
    guard !result.projects.isEmpty else { return "(no projects)" }
    let cells = result.projects.map { project in
        (
            name: project.name,
            repos: project.repos.map(\.name).joined(separator: ", "),
            policy: "policy: \(supervisionPolicyDescription(project.policy, repos: project.repos))",
            sweep: "sweep: \(project.sweepScript ?? "shipped")"
        )
    }
    let nameWidth = cells.map { $0.name.count }.max() ?? 0
    let reposWidth = cells.map { $0.repos.count }.max() ?? 0
    let policyWidth = cells.map { $0.policy.count }.max() ?? 0
    return cells.map { cell in
        tableRow([
            (cell.name, nameWidth),
            (cell.repos, reposWidth),
            (cell.policy, policyWidth),
            (cell.sweep, 0),
        ])
    }.joined(separator: "\n")
}

private func supervisionPolicyDescription(
    _ policy: SupervisionPolicySource, repos: [SupervisionProjectRepoRef]
) -> String {
    switch policy {
    case .operator:
        return "operator"
    case .repo(let id):
        let name = repos.first(where: { $0.id == id })?.name
        return "repo:\(name ?? id.uuidString)"
    }
}

// MARK: - argument parsing

/// Reads `--repos <id,…>`: repo UUIDs or display names, as typed. Resolving
/// them is the daemon's job; the CLI only refuses an empty list.
func parseSupervisionRepoList(_ raw: String) throws -> [String] {
    let repos = raw.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard !repos.isEmpty else {
        throw CLIError.invalidArgument("--repos must name at least one repo (comma-separated)")
    }
    return repos
}

/// The prefix `--policy repo:<id>` is spelled with.
let supervisionPolicyRepoPrefix = "repo:"

/// Reads `--policy repo:<id>|operator`.
func parseSupervisionPolicy(_ raw: String) throws -> SupervisionPolicyRequest {
    let value = raw.trimmingCharacters(in: .whitespaces)
    if value == "operator" { return .operator }
    if value.hasPrefix(supervisionPolicyRepoPrefix) {
        let repo = String(value.dropFirst(supervisionPolicyRepoPrefix.count))
            .trimmingCharacters(in: .whitespaces)
        if !repo.isEmpty { return .repo(repo) }
    }
    throw CLIError.invalidArgument(
        "--policy must be \"repo:<id>\" or \"operator\" (got \"\(raw)\")")
}

/// Reads `--to <project|singleton>`. `singleton` is the documented sentinel
/// that returns a repo to being its own project.
func parseSupervisionMoveTarget(_ raw: String) throws -> SupervisionMoveTarget {
    let value = raw.trimmingCharacters(in: .whitespaces)
    guard !value.isEmpty else {
        throw CLIError.invalidArgument(
            "--to must name a project or \"\(SupervisionMoveTarget.singletonArgument)\"")
    }
    return SupervisionMoveTarget(argument: value)
}

/// A project name typed on the command line. Empty is refused rather than
/// silently read as the bare (fleet-brake) form of `on`/`off`.
func requireSupervisionProjectName(_ raw: String) throws -> String {
    let value = raw.trimmingCharacters(in: .whitespaces)
    guard !value.isEmpty else {
        throw CLIError.invalidArgument("project name must not be empty")
    }
    return value
}
