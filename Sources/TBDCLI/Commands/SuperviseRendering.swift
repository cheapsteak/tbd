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
///
/// It has already earned that twice in this subsystem's first day —
/// `unusableProjectName` and then `ambiguousRepoName` / `brakeEngagedWithProjectsOn`
/// each stopped the build until an operator-facing sentence existed. Under a
/// `default` arm all four would have shipped as boilerplate. Keep it exhaustive.
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
    case .ambiguousRepoName:
        return """
            two or more repos share a display name, so none of them resolves to a \
            project and none is supervised — a name with two candidates identifies \
            nothing. Rename one, or declare a project naming them. The rest of the \
            fleet is unaffected.
            """
    case .brakeEngagedWithProjectsOn:
        return """
            the brake is engaged while projects are marked on — nothing is watching \
            them. Release it with `tbd supervise on`.
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
    var seen: Set<SupervisionWarningCode> = []
    for warning in status.warnings {
        seen.insert(warning.code)
        let supplied = warning.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = supplied.isEmpty ? supervisionWarningSentence(warning.code) : supplied
        lines.append("warning: \(message)")
    }
    if !seen.contains(.noProjectsOn) && status.brake == .released
        && !status.effectivelySupervising {
        lines.append("warning: \(supervisionWarningSentence(.noProjectsOn))")
    }
    // The mirror, recomputed for the same reason and worth more: here the
    // operator has performed a gesture and been told it succeeded.
    // `effectivelySupervising` is false in both states and cannot tell them
    // apart, so the condition is read from the brake and the marks.
    if !seen.contains(.brakeEngagedWithProjectsOn) && status.brake == .engaged
        && status.projects.contains(where: { $0.on }) {
        lines.append("warning: \(supervisionWarningSentence(.brakeEngagedWithProjectsOn))")
    }
    return lines
}

/// The lines a switching gesture emits after it has taken effect — bare
/// `tbd supervise on` releasing the brake, and `on <project>` setting a mark.
///
/// Deliberately the very same composition `status` renders, not a second
/// wording. A gesture is where an operator forms the belief that supervision is
/// running, and each of these two is the only gesture that can create the state
/// its warning describes — so they are the highest-value places to say it. One
/// fact gets one sentence, and this seam is what stops the surfaces drifting
/// into three.
///
/// Nothing is filtered to "the warning about this gesture". A finding true of
/// supervision is worth saying at the moment an operator is about to rely on
/// it, and a filter is a rule that can silently drop a warning a later slice
/// adds — the failure this surface exists to prevent, arriving by omission.
func supervisionGestureWarningLines(_ status: SupervisionStatus) -> [String] {
    supervisionStatusWarningLines(status)
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
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
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
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if value == "operator" { return .operator }
    if value.hasPrefix(supervisionPolicyRepoPrefix) {
        let repo = String(value.dropFirst(supervisionPolicyRepoPrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !repo.isEmpty { return .repo(repo) }
    }
    throw CLIError.invalidArgument(
        "--policy must be \"repo:<id>\" or \"operator\" (got \"\(raw)\")")
}

/// Reads `--to <project|singleton>`. `singleton` is the documented sentinel
/// that returns a repo to being its own project.
///
/// The destination is a project name, so it is passed through verbatim for the
/// same reason `requireSupervisionProjectName` does — `--to " staging "` must be
/// able to name the project `status` shows as `" staging "`. The sentinel is the
/// exact word: `--to " singleton "` names a project, not the sentinel, because
/// a caller who quoted those spaces typed them deliberately.
///
/// The emptiness test is `.whitespacesAndNewlines` for the reason spelled out on
/// `requireSupervisionProjectName`: these two guards are twins over the same
/// input class, and they have to move together or one of them is a hole.
func parseSupervisionMoveTarget(_ raw: String) throws -> SupervisionMoveTarget {
    guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CLIError.invalidArgument(
            "--to must name a project or \"\(SupervisionMoveTarget.singletonArgument)\"")
    }
    return SupervisionMoveTarget(argument: raw)
}

// MARK: - `--since`

/// The units a bare relative duration may be spelled with, and what each is
/// worth in seconds. Single letters only: `90s`, `30m`, `2h`, `3d`.
private let supervisionSinceDurationUnits: [Character: Int] = [
    "s": 1, "m": 60, "h": 3600, "d": 86400,
]

/// How far back `parseSupervisionSince` will look for a bare `HH:MM`.
///
/// Two days, because one is not always enough: on the morning the clocks spring
/// forward, a wall-clock time inside the skipped hour never occurs *today*, and
/// its most recent past occurrence is yesterday's. No valid `HH:MM` can be
/// skipped on two consecutive days, so a window of two covers every case.
private let supervisionSinceSearchWindow: TimeInterval = 48 * 3600

/// The refusal every unrecognized `--since` value gets. It names all three
/// accepted shapes with an example of each, because a refusal that does not say
/// what would have worked makes the operator go look.
func supervisionSinceRefusal(_ raw: String) -> String {
    """
    --since must be one of three shapes (got "\(raw)"): \
    a full ISO-8601 timestamp with an offset or Z (e.g. 2026-08-15T02:10:00Z), \
    a bare 24-hour HH:MM resolved to its most recent past occurrence in local \
    time (e.g. 22:00), or a bare relative duration meaning that long ago \
    (e.g. 90s, 30m, 2h, 3d)
    """
}

/// Reads `--since <t>` into the absolute instant the ledger query is bounded by.
///
/// Three shapes, tried in this order — a full ISO-8601 timestamp, a bare
/// `HH:MM`, then a bare relative duration
/// (`docs/specs/2026-08-01-fleet-supervision-sweep-program-design.md` §3). None
/// of the three can be mistaken for another, so the order is documentation
/// rather than precedence.
///
/// **`now` and `calendar` are parameters, not reads of the ambient clock**, so
/// this stays a pure function of its inputs: `Duration` is behavior and `Date`
/// is data, and every rule below — "most recent past", "that long ago" — is a
/// comparison against a timestamp rather than a delay. A test pins the
/// daylight-saving case with a fixed calendar instead of hoping the machine is
/// in the right zone on the right morning.
///
/// The value is resolved here, before the query runs, so the window's lower
/// bound is fixed at the moment the operator invoked the command rather than
/// re-derived while the daemon executes it. That resolved instant is what the
/// result echoes back in `since`.
func parseSupervisionSince(
    _ raw: String, now: Date, calendar: Calendar = .current
) throws -> Date {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    if let instant = supervisionSinceISO8601(value) { return instant }

    if let clock = supervisionSinceClockTime(value) {
        guard let instant = supervisionMostRecentPastOccurrence(
            hour: clock.hour, minute: clock.minute, now: now, calendar: calendar) else {
            throw CLIError.invalidArgument(
                "--since \(value) names no time in the last 48 hours in time zone "
                    + "\(calendar.timeZone.identifier)")
        }
        return instant
    }

    if let ago = supervisionSinceDurationAgo(value) {
        return now.addingTimeInterval(-ago)
    }

    throw CLIError.invalidArgument(supervisionSinceRefusal(raw))
}

/// Shape one: a full ISO-8601 timestamp carrying an offset or `Z`, with or
/// without fractional seconds. `.withInternetDateTime` is what makes the offset
/// mandatory — a timestamp with no zone names a different instant in every time
/// zone, which is the ambiguity a program computing "since my last evaluation"
/// uses this shape to avoid.
private func supervisionSinceISO8601(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: value)
}

/// Shape two's grammar: a bare 24-hour `HH:MM`.
///
/// Out-of-range values are refused rather than clamped — `24:00` and `99:99` are
/// mistakes, and a clamp would answer a question the operator did not ask.
/// Digits are checked explicitly because `Int("+2")` succeeds: the sign would
/// otherwise smuggle `+2:10` through as `02:10`.
private func supervisionSinceClockTime(_ value: String) -> (hour: Int, minute: Int)? {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    guard (1...2).contains(parts[0].count), parts[1].count == 2 else { return nil }
    guard supervisionIsASCIIDigits(parts[0]), supervisionIsASCIIDigits(parts[1]) else {
        return nil
    }
    guard let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
    guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
    return (hour, minute)
}

/// Shape two's resolution: the most recent instant at or before `now` whose
/// local wall clock reads `hour:minute`.
///
/// Walked backwards a minute at a time from `now`, which is the rule stated
/// directly rather than reconstructed from calendar arithmetic. Two properties
/// come out of that for free, and both are the reason it is written this way:
///
/// - **A daylight-saving fall-back resolves to the *later* of the two candidate
///   instants.** On the morning the clocks go back, `01:30` local happens twice;
///   walking backwards from now reaches the second one first, and the second one
///   is what "most recent past occurrence" means. Calendar helpers that match a
///   wall time on a given day answer with the *first* of the pair instead.
/// - A wall time skipped by a spring-forward simply has no match today, and the
///   walk carries on into yesterday, where it does.
///
/// Every time-zone offset in use is a whole number of minutes, so stepping by 60
/// seconds from a minute-aligned start keeps the candidate aligned to `:00`
/// seconds in local time too. The walk costs at most 2,880 component reads,
/// which is nothing in a one-shot CLI and buys an implementation whose
/// correctness is readable.
private func supervisionMostRecentPastOccurrence(
    hour: Int, minute: Int, now: Date, calendar: Calendar
) -> Date? {
    let alignedSeconds = (now.timeIntervalSince1970 / 60).rounded(.down) * 60
    var candidate = Date(timeIntervalSince1970: alignedSeconds)
    let floor = now.addingTimeInterval(-supervisionSinceSearchWindow)
    while candidate >= floor {
        let parts = calendar.dateComponents([.hour, .minute], from: candidate)
        if parts.hour == hour && parts.minute == minute { return candidate }
        candidate = candidate.addingTimeInterval(-60)
    }
    return nil
}

/// Shape three: a bare relative duration — an integer magnitude and a
/// single-letter unit — read as "that long ago".
///
/// `0m` is a legitimate value meaning now. A negative or non-integer magnitude
/// is not: `-5m` and `1.5h` fail the digits test, because a duration that runs
/// forwards is not a lower bound and a fractional one has no spelling here.
private func supervisionSinceDurationAgo(_ value: String) -> TimeInterval? {
    guard let unit = value.last, let secondsPerUnit = supervisionSinceDurationUnits[unit] else {
        return nil
    }
    let magnitude = value.dropLast()
    guard !magnitude.isEmpty, supervisionIsASCIIDigits(magnitude) else { return nil }
    guard let count = Int(magnitude) else { return nil }
    let (seconds, overflowed) = count.multipliedReportingOverflow(by: secondsPerUnit)
    guard !overflowed else { return nil }
    return TimeInterval(seconds)
}

/// `Character.isNumber` accepts every digit Unicode knows, and `Int(_:)` accepts
/// a leading sign. Neither is what these two grammars mean by a digit.
private func supervisionIsASCIIDigits(_ text: Substring) -> Bool {
    !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
}

// MARK: - brief

/// The exit code every `brief` outcome that is neither delivery nor a brake
/// refusal answers with.
///
/// One value, deliberately: `docs/cli-supervise.md` pins 0 and 75 as contract
/// and says the rest are not, so a program branches on 0 / 75 / nonzero and
/// reads `result` for which of the five it got. Splitting these across several
/// codes would invite exactly the branching the document says not to write.
let supervisionBriefRefusedExitCode: Int32 = 1

/// The exit code one briefing outcome earns.
///
/// **Exhaustive with no `default` arm, and that is the whole reason this is a
/// function.** `SupervisionBriefOutcome`'s seven values are contract; an eighth
/// added later must be a compile error here rather than falling through to 0,
/// because "TBD did something new with your briefing" reported as success is
/// precisely the silent failure this surface exists to prevent.
///
/// Only `refused-paused` is 75 — sysexits' `EX_TEMPFAIL`, "not now, retry
/// later", which is exactly what a brake refusal means and the one numeric code
/// a script may branch on. The other four refusals are deliberately not 75: an
/// off project is a standing state, an oversize briefing needs recomposing, a
/// rate-limited one needs the window to lift, and a failed transport needs
/// re-evaluation. A program that retried all of them on a timer because they
/// shared a code would be retrying four things that are not "wait a bit".
func supervisionBriefExitCode(_ outcome: SupervisionBriefOutcome) -> Int32 {
    switch outcome {
    case .delivered:
        return 0
    case .refusedPaused:
        return SupervisionBriefing.pausedExitCode
    case .refusedOff, .refusedRateLimit, .refusedSize, .transportFailed, .noLiveSupervisor:
        return supervisionBriefRefusedExitCode
    }
}

/// Compose one submission's params from the bytes stdin gave us.
///
/// **Every submission is sent, whatever its size, and this function cannot
/// refuse one — it does not throw, and that signature is the guard.** The
/// briefing pipeline's four steps are ordered
/// (`docs/specs/2026-08-01-fleet-supervision-sweep-program-design.md` §3), and
/// the first is unconditional: timestamp and attribute, which is what updates
/// the project's liveness record. Pacing, the refusals and delivery all come
/// after it. A submission the CLI turned away locally never reaches step one,
/// so it moves no liveness record — and a sweep program whose composer had a
/// runaway bug and emitted 300 KiB every tick would read to the watchdog as
/// **silent** rather than broken. Silence is the one signal reserved for
/// "nobody looked", and counterfeiting it is far worse than a wasted socket
/// write.
///
/// The size bound is real and belongs to the daemon
/// (`SupervisionBriefing.maxBriefingBytes`), which enforces it *after*
/// recording contact and answers `refused-size`. **Do not add the early
/// refusal back as an optimization**: it also required the CLI to mint a
/// `SupervisionBriefResult` the daemon never produced, whose `submittedAt`
/// claimed a contact that never happened. The CLI reports results; it does not
/// invent them.
///
/// Invalid UTF-8 is repaired rather than refused, for the same reason: a
/// briefing is prose for a desk and TBD parses none of it, so a mangled byte
/// is the desk's problem to read around, not grounds to lose the contact.
func supervisionBriefParams(project: String, stdin: Data) -> SuperviseBriefParams {
    SuperviseBriefParams(project: project, text: String(decoding: stdin, as: UTF8.self))
}

/// A project name typed on the command line, passed to the daemon **verbatim**.
///
/// A name of nothing but whitespace is refused, because that is the empty case
/// — it would otherwise read as the bare (fleet-brake) form of `on`/`off`. Any
/// other name goes through exactly as typed, surrounding spaces included: a
/// singleton project's name is its repo's display name, and `isSafeProjectName`
/// deliberately rejects only genuinely unsafe components (empty, `.`, `..`, a
/// path separator, NUL) so a repo named `" staging "` keeps its directory. If
/// the CLI trimmed, that project would appear in `status` and be unaddressable
/// by every other verb.
///
/// The CLI resolves no names: the daemon is the single resolver, so a name that
/// matches nothing comes back as a refusal naming the condition rather than
/// being silently repaired into a neighbouring project's.
///
/// **The emptiness test is `.whitespacesAndNewlines`, and the distinction is
/// load-bearing.** `CharacterSet.whitespaces` holds spaces and tabs but no
/// newline, so `"\t \n"` trimmed by it is `"\n"` — not empty, guard passed, a
/// whitespace-only name on its way to the daemon. That is the exact input this
/// guard exists to stop, and a shell-expanded argument is where it comes from.
func requireSupervisionProjectName(_ raw: String) throws -> String {
    guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CLIError.invalidArgument("project name must not be empty")
    }
    return raw
}
