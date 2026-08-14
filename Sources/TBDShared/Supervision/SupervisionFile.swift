import Foundation

// MARK: - Timestamps

/// A moment on the wire, encoded as ISO-8601 with fractional seconds in UTC
/// (`2026-08-14T02:13:12.482Z`).
///
/// Supervision carries its own instant type rather than a bare `Date` because
/// every one of its surfaces is read by something outside this process — a
/// watchdog reading `status.json`, a sweep program reading `ledger.jsonl`, a
/// human hand-editing a file — so the wire format has to be a property of the
/// value, not of whichever encoder happens to touch it. (`JSONEncoder`'s
/// `.iso8601` strategy also drops fractional seconds, which the ledger needs.)
///
/// It is data, never behavior: producing one is the caller's date seam
/// (`now: @Sendable () -> Date`), never `Date()` inline.
public struct SupervisionInstant: Codable, Sendable, Equatable, Hashable, Comparable {
    public let date: Date

    /// Rounded to the millisecond the wire format carries. An instant holds the
    /// precision it can persist, so a value and its reloaded self are the same
    /// value rather than two that differ by a few microseconds — the drift that
    /// makes "did this line survive a round trip" unanswerable.
    public init(_ date: Date) {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        self.date = Date(timeIntervalSince1970: milliseconds / 1000)
    }

    public static func < (lhs: SupervisionInstant, rhs: SupervisionInstant) -> Bool {
        lhs.date < rhs.date
    }

    /// Identity is the wire form, not the `Date`'s full precision: an instant
    /// means the millisecond it records, so one that survived a round trip
    /// equals the one that was written. Comparing raw `Date`s would make every
    /// value unequal to its own reloaded self by a few microseconds.
    public static func == (lhs: SupervisionInstant, rhs: SupervisionInstant) -> Bool {
        lhs.wireValue == rhs.wireValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(wireValue)
    }

    private static let style = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true, timeZone: TimeZone(identifier: "UTC")!)

    /// The wire representation, e.g. `2026-08-14T02:13:12.482Z`.
    public var wireValue: String { Self.style.format(date) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let parsed = try? Self.style.parse(text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "not an ISO-8601 UTC timestamp with fractional seconds: \(text)")
        }
        self.init(parsed)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

// MARK: - Preserved JSON

/// A JSON value carried through `supervision.json` verbatim.
///
/// Used for the per-project `sweep` selection, whose vocabulary belongs to the
/// sweep program (`docs/specs/2026-08-01-fleet-supervision-sweep-program-design.md`)
/// rather than to this loader. Modeling it as preserved JSON means a rewrite
/// after an unrelated edit cannot drop a key this version does not know about,
/// and it keeps this file from inventing fields it does not own.
public enum SupervisionJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([SupervisionJSONValue])
    case object([String: SupervisionJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .integer(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([SupervisionJSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: SupervisionJSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// The value as a string, when it is one.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

// MARK: - Policy source

/// Which playbook a project's supervisor stands on: a member repo's
/// `.agents/supervision.md`, or the operator-level file beside the project's
/// definition. Encodes as `{"repo":"<repo-id>"}` or `{"operator":true}`.
public enum SupervisionPolicySource: Codable, Sendable, Equatable {
    case repo(UUID)
    case `operator`

    private enum CodingKeys: String, CodingKey {
        case repo
        case `operator`
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let repo = try container.decodeIfPresent(UUID.self, forKey: .repo) {
            self = .repo(repo)
            return
        }
        if let isOperator = try container.decodeIfPresent(Bool.self, forKey: .operator) {
            guard isOperator else {
                throw DecodingError.dataCorruptedError(
                    forKey: .operator, in: container,
                    debugDescription: "a policy of {\"operator\": false} names no policy source")
            }
            self = .operator
            return
        }
        throw DecodingError.dataCorruptedError(
            forKey: .repo, in: container,
            debugDescription: "a policy must be {\"repo\": \"<repo-id>\"} or {\"operator\": true}")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .repo(let id): try container.encode(id, forKey: .repo)
        case .operator: try container.encode(true, forKey: .operator)
        }
    }
}

// MARK: - Sweep selection

/// A project's sweep selection — the schedule, the declared contact window, and
/// the custom-program pointer. Preserved verbatim (see `SupervisionJSONValue`);
/// this slice reads only `script` and writes nothing.
public struct SupervisionSweepSelection: Codable, Sendable, Equatable {
    public var fields: [String: SupervisionJSONValue]

    public init(fields: [String: SupervisionJSONValue]) { self.fields = fields }

    /// The project's own sweep program, when the "Customize sweep…" gesture has
    /// pointed at one.
    public var script: String? { fields["script"]?.stringValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        fields = try container.decode([String: SupervisionJSONValue].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fields)
    }
}

// MARK: - Supervisor binding

/// The operator-appointed supervisor for a project: the TBD-managed terminal
/// bound into the role. Absence means the shipped default, the hosted desk.
///
/// The terminal is held as a string rather than a `UUID` deliberately. A
/// binding is made real by the appointment relaunch, not by the registry write,
/// so a hand-edited binding — including one naming something that is not a
/// terminal id at all — is an anomaly for the daemon to report, never a reason
/// to reject the whole file and take supervision offline.
public struct SupervisionSupervisorBinding: Codable, Sendable, Equatable {
    public var terminal: String

    public init(terminal: String) { self.terminal = terminal }
    public init(terminalID: UUID) { self.terminal = terminalID.uuidString }

    /// The bound terminal as an id, or nil when the binding does not name one.
    public var terminalID: UUID? { UUID(uuidString: terminal) }
}

// MARK: - Mode entry

/// A project's entry in `modes`: the declared mode names an operator may
/// select, and the selection among them.
///
/// Polymorphic on the wire (design §8): a bare string is a selection against
/// the built-in list, an object carries `declared` (complete when present) and
/// `selected`. The shape a value arrived in is carried on the value and
/// reproduced on rewrite, so an unrelated edit never rewrites an operator's
/// bare `"autonomous"` into an object.
public struct SupervisionModeEntry: Codable, Sendable, Equatable {
    /// The two shapes design §8 gives this value.
    public enum WireShape: Sendable, Equatable {
        /// `"autonomous"` — a selection against the built-in list.
        case bareSelection
        /// `{"selected": …, "declared": […]}`.
        case object
    }

    /// The names an operator may select for this project, or nil when the entry
    /// declares none and the built-in pair stands.
    public let declared: [String]?
    /// The operator's selection, or nil when the entry carries none and the
    /// default stands.
    public let selected: String?
    public let wireShape: WireShape

    /// The two modes the shipped playbook defines, available to every project
    /// without authoring anything (design §3, §8).
    public static let builtInModes = ["attended", "autonomous"]
    /// The selection when an entry names none (design §8).
    public static let defaultMode = "attended"

    private init(declared: [String]?, selected: String?, wireShape: WireShape) {
        self.declared = declared
        self.selected = selected
        self.wireShape = wireShape
    }

    /// A bare selection against the built-in list — the common case.
    public static func bare(_ selected: String) -> SupervisionModeEntry {
        SupervisionModeEntry(declared: nil, selected: selected, wireShape: .bareSelection)
    }

    /// An object entry. Either half may be absent; the defaults chain fills it.
    public static func declaring(
        declared: [String]? = nil, selected: String? = nil
    ) -> SupervisionModeEntry {
        SupervisionModeEntry(declared: declared, selected: selected, wireShape: .object)
    }

    /// The names selectable for this project — the declared list when present,
    /// the built-in pair when absent.
    public var declaredModes: [String] { declared ?? Self.builtInModes }

    /// The project's active mode — the selection when present, `attended` when
    /// absent.
    public var activeMode: String { selected ?? Self.defaultMode }

    /// The same entry with a different selection, keeping the wire shape a bare
    /// entry arrived in.
    public func selecting(_ mode: String) -> SupervisionModeEntry {
        SupervisionModeEntry(declared: declared, selected: mode, wireShape: wireShape)
    }

    private enum CodingKeys: String, CodingKey {
        case selected
        case declared
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let name = try? single.decode(String.self) {
            self = .bare(name)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        declared = try container.decodeIfPresent([String].self, forKey: .declared)
        selected = try container.decodeIfPresent(String.self, forKey: .selected)
        wireShape = .object
    }

    public func encode(to encoder: Encoder) throws {
        switch wireShape {
        case .bareSelection:
            var container = encoder.singleValueContainer()
            try container.encode(activeMode)
        case .object:
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(selected, forKey: .selected)
            try container.encodeIfPresent(declared, forKey: .declared)
        }
    }
}

// MARK: - Project declaration

/// One declared multi-repo project. Singletons are declared nowhere — see
/// `SupervisionTopology.resolve(file:repos:)`.
public struct SupervisionProjectDeclaration: Codable, Sendable, Equatable {
    /// The member repos, in the order the operator declared them.
    public var repos: [UUID]
    /// The one playbook source the project designates.
    public var policy: SupervisionPolicySource
    /// The project's sweep selection, preserved verbatim.
    public var sweep: SupervisionSweepSelection?

    public init(repos: [UUID], policy: SupervisionPolicySource,
                sweep: SupervisionSweepSelection? = nil) {
        self.repos = repos
        self.policy = policy
        self.sweep = sweep
    }
}

// MARK: - The file

/// `~/tbd/supervision/supervision.json` — the operator's selections, and
/// nothing a machine evaluates (design §8). Topology, the per-project marks,
/// mode declarations and selections, supervisor bindings, sweep selection.
///
/// **Untouched and turned-off are one state.** A mark is membership in
/// `supervised`; absence is off. There is no "never configured" third tier
/// anywhere in this type, and an absent file loads as the value
/// `SupervisionFile()` returns rather than as an error or an optional.
public struct SupervisionFile: Codable, Sendable, Equatable {
    /// The only version this build reads and writes.
    public static let currentVersion = 1

    public var version: Int
    /// Declared multi-repo projects, keyed by project name. Absent or empty is
    /// the normal state — an installation that groups nothing declares nothing.
    public var projects: [String: SupervisionProjectDeclaration]
    /// The projects turned on. Unknown names are kept verbatim (a project may
    /// be declared later); they resolve to nothing.
    public var supervised: [String]
    public var modes: [String: SupervisionModeEntry]
    public var supervisors: [String: SupervisionSupervisorBinding]

    public init(version: Int = SupervisionFile.currentVersion,
                projects: [String: SupervisionProjectDeclaration] = [:],
                supervised: [String] = [],
                modes: [String: SupervisionModeEntry] = [:],
                supervisors: [String: SupervisionSupervisorBinding] = [:]) {
        self.version = version
        self.projects = projects
        self.supervised = supervised
        self.modes = modes
        self.supervisors = supervisors
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case projects
        case supervised
        case modes
        case supervisors
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        projects = try container.decodeIfPresent(
            [String: SupervisionProjectDeclaration].self, forKey: .projects) ?? [:]
        supervised = try container.decodeIfPresent([String].self, forKey: .supervised) ?? []
        modes = try container.decodeIfPresent(
            [String: SupervisionModeEntry].self, forKey: .modes) ?? [:]
        supervisors = try container.decodeIfPresent(
            [String: SupervisionSupervisorBinding].self, forKey: .supervisors) ?? [:]
    }

    /// Empty collections are omitted, so a fleet that declared nothing keeps a
    /// one-line file rather than accumulating empty scaffolding it never asked
    /// for.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        if !projects.isEmpty { try container.encode(projects, forKey: .projects) }
        if !supervised.isEmpty { try container.encode(supervised, forKey: .supervised) }
        if !modes.isEmpty { try container.encode(modes, forKey: .modes) }
        if !supervisors.isEmpty { try container.encode(supervisors, forKey: .supervisors) }
    }

    // MARK: Marks and modes

    /// Whether the project's mark is set. Absent is off; there is no third
    /// state to distinguish.
    public func isMarked(_ project: String) -> Bool { supervised.contains(project) }

    /// The same file with a project's mark set or cleared. Setting a mark that
    /// already stands, or clearing one that does not, returns an equal value —
    /// a no-op is not a decision, and callers use that to decline writing a
    /// ledger line.
    public func settingMark(_ project: String, on: Bool) -> SupervisionFile {
        var copy = self
        if on {
            guard !copy.supervised.contains(project) else { return self }
            copy.supervised.append(project)
        } else {
            guard copy.supervised.contains(project) else { return self }
            copy.supervised.removeAll { $0 == project }
        }
        return copy
    }

    /// The declared mode names for a project, defaults chain applied.
    public func declaredModes(for project: String) -> [String] {
        modes[project]?.declaredModes ?? SupervisionModeEntry.builtInModes
    }

    /// A project's active mode, defaults chain applied.
    public func activeMode(for project: String) -> String {
        modes[project]?.activeMode ?? SupervisionModeEntry.defaultMode
    }

    /// The same file with a project's selection changed, keeping an existing
    /// entry's wire shape. A project with no entry gains a bare one.
    public func settingMode(_ project: String, to mode: String) -> SupervisionFile {
        var copy = self
        if let existing = modes[project] {
            copy.modes[project] = existing.selecting(mode)
        } else {
            copy.modes[project] = .bare(mode)
        }
        return copy
    }

    // MARK: Validation

    /// Rejects a file no consumer should act on, naming the offending repo,
    /// project, or condition.
    ///
    /// Every rejection here is loud and whole-file: nothing is repaired and
    /// nothing is partially loaded, because "every repo belongs to exactly one
    /// project" is the property the whole grouping rests on (design §5, §8).
    public func validate() throws {
        guard version == Self.currentVersion else {
            throw SupervisionFileError.unsupportedVersion(
                found: version, supported: Self.currentVersion)
        }

        var ownerOfRepo: [UUID: String] = [:]
        for name in projects.keys.sorted() {
            guard let declaration = projects[name] else { continue }
            guard Self.isSafeProjectName(name) else {
                throw SupervisionFileError.invalidProjectName(project: name)
            }
            guard !declaration.repos.isEmpty else {
                throw SupervisionFileError.projectHasNoRepos(project: name)
            }
            var seenHere: Set<UUID> = []
            for repo in declaration.repos {
                guard seenHere.insert(repo).inserted else {
                    throw SupervisionFileError.repoListedTwice(repo: repo, project: name)
                }
                if let owner = ownerOfRepo[repo], owner != name {
                    let (first, second) = owner < name ? (owner, name) : (name, owner)
                    throw SupervisionFileError.repoInTwoProjects(
                        repo: repo, first: first, second: second)
                }
                ownerOfRepo[repo] = name
            }
            if case .repo(let policyRepo) = declaration.policy,
               !declaration.repos.contains(policyRepo) {
                throw SupervisionFileError.policyRepoNotAMember(
                    project: name, repo: policyRepo)
            }
        }

        for project in modes.keys.sorted() {
            guard let entry = modes[project] else { continue }
            if let declared = entry.declared, declared.isEmpty {
                throw SupervisionFileError.emptyDeclaredModeList(project: project)
            }
            guard entry.declaredModes.contains(entry.activeMode) else {
                throw SupervisionFileError.selectedModeNotDeclared(
                    project: project, selected: entry.activeMode,
                    declared: entry.declaredModes)
            }
        }
    }

    /// A declared project name has to be one safe path component: it names a
    /// directory under `~/tbd/supervision/projects/` holding the project's
    /// playbook, journal, and programs.
    public static func isSafeProjectName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        guard !name.contains("/"), !name.contains("\0") else { return false }
        guard !name.hasPrefix(" "), !name.hasSuffix(" ") else { return false }
        return true
    }
}

// MARK: - Errors

/// Why a supervision file was refused. Every message names the offending repo,
/// project, or condition — these reach a human on stderr.
public enum SupervisionFileError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case unsupportedVersion(found: Int, supported: Int)
    case repoInTwoProjects(repo: UUID, first: String, second: String)
    case repoListedTwice(repo: UUID, project: String)
    case policyRepoNotAMember(project: String, repo: UUID)
    case projectHasNoRepos(project: String)
    case invalidProjectName(project: String)
    case emptyDeclaredModeList(project: String)
    case selectedModeNotDeclared(project: String, selected: String, declared: [String])
    case malformed(path: String, detail: String)

    public var description: String {
        switch self {
        case .unsupportedVersion(let found, let supported):
            return "The supervision file is version \(found); this build reads version \(supported)."
        case .repoInTwoProjects(let repo, let first, let second):
            return "Repo \(repo.uuidString) is a member of both \"\(first)\" and \"\(second)\". "
                + "Every repo belongs to exactly one project, so the supervision file was rejected "
                + "whole; move the repo with \"tbd supervise project move\" or remove one membership by hand."
        case .repoListedTwice(let repo, let project):
            return "Repo \(repo.uuidString) is listed twice in project \"\(project)\"."
        case .policyRepoNotAMember(let project, let repo):
            return "Project \"\(project)\" designates repo \(repo.uuidString) as its policy source, "
                + "but that repo is not one of its members."
        case .projectHasNoRepos(let project):
            return "Project \"\(project)\" declares no member repos."
        case .invalidProjectName(let project):
            return "Project name \"\(project)\" is not usable: a name must be a single path "
                + "component with no slashes and no leading or trailing spaces."
        case .emptyDeclaredModeList(let project):
            return "Project \"\(project)\" declares an empty mode list, so no mode could be selected."
        case .selectedModeNotDeclared(let project, let selected, let declared):
            return "Project \"\(project)\" selects mode \"\(selected)\", which is not one of its "
                + "declared modes (\(declared.joined(separator: ", ")))."
        case .malformed(let path, let detail):
            return "The supervision file at \(path) could not be read: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}
