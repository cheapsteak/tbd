import Foundation

/// A repo as project resolution sees it: an id and the display name a
/// singleton project takes.
public struct SupervisionRepo: Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    public init(_ repo: Repo) {
        self.init(id: repo.id, name: repo.displayName)
    }
}

/// The supervisor arrangement standing for a project: the shipped hosted desk,
/// or a session the operator appointed.
public struct SupervisionSupervisorArrangement: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case hostedDesk
        case appointed
    }

    public let kind: Kind
    /// The bound terminal, when one is bound.
    public let terminal: String?

    public init(kind: Kind, terminal: String?) {
        self.kind = kind
        self.terminal = terminal
    }

    public static let hostedDesk = SupervisionSupervisorArrangement(
        kind: .hostedDesk, terminal: nil)

    public static func appointed(terminal: String) -> SupervisionSupervisorArrangement {
        SupervisionSupervisorArrangement(kind: .appointed, terminal: terminal)
    }
}

/// A resolved supervision project: one policy, one supervisor, one mark.
///
/// **There is no `isSingleton` or `isDeclared` field, and there never will be.**
/// A repo declared nowhere is its own project, and the collapse is a property
/// rather than a branch: a fresh install with no `supervision.json` and an
/// install whose file declares one single-repo project per repo resolve to
/// equal values, down to the policy source. Any consumer able to tell the two
/// apart would be able to behave differently between them, which design §5
/// calls a bug and not a feature.
public struct SupervisionProject: Sendable, Equatable, Identifiable {
    /// The project's name — the declared key, or the repo's display name for a
    /// repo declared nowhere.
    public let name: String
    /// The member repos, in the order the topology gives them.
    public let repos: [UUID]
    /// Where this project's playbook comes from.
    public let policy: SupervisionPolicySource
    /// The project's sweep selection, when it has one.
    public let sweep: SupervisionSweepSelection?
    /// Whether the project's mark is set. Coverage, never protection (§8).
    public let mark: Bool
    public let declaredModes: [String]
    public let activeMode: String
    public let supervisor: SupervisionSupervisorArrangement

    public var id: String { name }

    /// Whether this project can have a directory of its own under
    /// `~/tbd/supervision/projects/` — where its playbook, journal, proposals,
    /// and programs would live.
    ///
    /// False only for a name that is not one path component. Resolution keeps
    /// such a project whole: it has its mark, its mode, and its line in the
    /// readout, and only the directory is unavailable until the repo is
    /// renamed. Refusing to resolve it would take the whole fleet's coverage
    /// offline over one repo's display name, in a file the operator never
    /// edited.
    ///
    /// This is a function of the name and nothing else, so a declared project
    /// and a singleton with the same name answer identically: a validity
    /// condition, not a declared-ness flag.
    public var hasUsableDirectory: Bool { SupervisionFile.isSafeProjectName(name) }

    public init(name: String, repos: [UUID], policy: SupervisionPolicySource,
                sweep: SupervisionSweepSelection?, mark: Bool,
                declaredModes: [String], activeMode: String,
                supervisor: SupervisionSupervisorArrangement) {
        self.name = name
        self.repos = repos
        self.policy = policy
        self.sweep = sweep
        self.mark = mark
        self.declaredModes = declaredModes
        self.activeMode = activeMode
        self.supervisor = supervisor
    }
}

/// Where a `move` puts a repo.
public enum SupervisionMoveTarget: Sendable, Equatable {
    case project(String)
    /// Back to being its own project — the default arrangement.
    case singleton

    /// The word the CLI accepts for `--to singleton`.
    public static let singletonArgument = "singleton"

    /// Reads `--to <project|singleton>`.
    public init(argument: String) {
        self = argument == Self.singletonArgument ? .singleton : .project(argument)
    }

    public var argument: String {
        switch self {
        case .singleton: return Self.singletonArgument
        case .project(let name): return name
        }
    }
}

/// A display name two or more undeclared repos share, and the repos that share
/// it. None of them resolves to a project until one is renamed or a declaration
/// names them.
public struct SupervisionAmbiguousRepoName: Sendable, Equatable {
    public let name: String
    /// The repos sharing the name, in a stable order.
    public let repos: [UUID]

    public init(name: String, repos: [UUID]) {
        self.name = name
        self.repos = repos
    }
}

/// Why a topology operation was refused.
public enum SupervisionTopologyError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case projectNameCollidesWithRepo(project: String, repo: UUID, repoName: String)
    case unknownRepo(repo: UUID)
    case unknownProject(project: String)
    case policySourceWouldLeaveProject(project: String, repo: UUID)

    public var description: String {
        switch self {
        case .projectNameCollidesWithRepo(let project, let repo, let repoName):
            return "Declared project \"\(project)\" has the same name as repo \(repoName) "
                + "(\(repo.uuidString)), which is not one of its members — that repo's own "
                + "project would have the same name. Rename the project or move the repo into it."
        case .unknownRepo(let repo):
            return "There is no repo \(repo.uuidString)."
        case .unknownProject(let project):
            return "There is no declared project \"\(project)\"."
        case .policySourceWouldLeaveProject(let project, let repo):
            return "Repo \(repo.uuidString) is project \"\(project)\"'s policy source, so moving "
                + "it out would leave the project with no playbook. Designate another member's "
                + "policy first."
        }
    }

    public var errorDescription: String? { description }
}

/// Project resolution and the one membership transform.
public enum SupervisionTopology {

    /// The full project set: the declared projects, plus one project per repo
    /// that no declaration names.
    ///
    /// A singleton's implicit values are filled in so that nothing downstream
    /// can tell it from a one-repo declared project — its policy source is
    /// `.repo(thatRepo)`, precisely what such a declaration resolves to.
    ///
    /// **A declared** name that collides is refused whole, and no partial
    /// resolution is served: that name is the operator's own edit, in a file
    /// they can fix. An **undeclared** repo whose display name is not unique is
    /// reported instead — see `ambiguousRepoNames(file:repos:)`.
    public static func resolve(
        file: SupervisionFile, repos: [SupervisionRepo]
    ) throws -> [SupervisionProject] {
        try file.validate()

        let declaredOwner = declaredOwners(file: file)
        let implicitOwner = implicitOwners(file: file, repos: repos)

        // The declared collision first, so it is reported before anything is
        // built.
        for name in implicitOwner.keys.sorted() {
            if file.projects[name] != nil, let repo = implicitOwner[name]?.first {
                throw SupervisionTopologyError.projectNameCollidesWithRepo(
                    project: name, repo: repo, repoName: name)
            }
        }
        let ambiguous = Set(implicitOwner.filter { $0.value.count > 1 }.keys)

        var projects: [SupervisionProject] = []
        for (name, declaration) in file.projects {
            projects.append(project(
                named: name, repos: declaration.repos, policy: declaration.policy,
                sweep: declaration.sweep, file: file))
        }
        for repo in repos
        where declaredOwner[repo.id] == nil && !ambiguous.contains(repo.name) {
            projects.append(project(
                named: repo.name, repos: [repo.id], policy: .repo(repo.id),
                sweep: nil, file: file))
        }
        return projects.sorted { $0.name < $1.name }
    }

    /// The display names shared by two or more repos that no declaration
    /// names, each with its repos, sorted.
    ///
    /// Those repos resolve to **no project**: a project is identified by its
    /// name, so two candidates for one name identify nothing. The rest of the
    /// fleet resolves normally, which is the whole point — display names carry
    /// no uniqueness constraint anywhere in TBD (`RepoStore.addRepo` defaults
    /// to the path's last component and rename accepts anything), so two
    /// clones of `api` under different parents is an ordinary state, and it
    /// must not take `status`, `project list`, every mark and mode gesture, and
    /// the `status.json` heartbeat down together. A fleet whose heartbeat stops
    /// is indistinguishable from a dead daemon to the watchdog, which is the
    /// one distinction that file exists to draw.
    ///
    /// Reported as `SupervisionWarningCode.ambiguousRepoName`. The operator's
    /// fix is to rename one repo, or to declare a project naming them.
    public static func ambiguousRepoNames(
        file: SupervisionFile, repos: [SupervisionRepo]
    ) -> [SupervisionAmbiguousRepoName] {
        implicitOwners(file: file, repos: repos)
            .filter { $0.value.count > 1 }
            .map { SupervisionAmbiguousRepoName(name: $0.key, repos: $0.value) }
            .sorted { $0.name < $1.name }
    }

    private static func declaredOwners(file: SupervisionFile) -> [UUID: String] {
        var owners: [UUID: String] = [:]
        for (name, declaration) in file.projects {
            for repo in declaration.repos { owners[repo] = name }
        }
        return owners
    }

    /// Repos no declaration names, grouped by the project name they would take,
    /// each group in a stable order.
    private static func implicitOwners(
        file: SupervisionFile, repos: [SupervisionRepo]
    ) -> [String: [UUID]] {
        let declaredOwner = declaredOwners(file: file)
        var implicitOwner: [String: [UUID]] = [:]
        for repo in repos where declaredOwner[repo.id] == nil {
            implicitOwner[repo.name, default: []].append(repo.id)
        }
        return implicitOwner.mapValues { $0.sorted { $0.uuidString < $1.uuidString } }
    }

    /// The resolved projects that cannot have a directory of their own, by
    /// name, sorted. What the daemon reports as
    /// `SupervisionWarningCode.unusableProjectName`: the projects are supervised
    /// like any other, but nothing can be written beside them until the repo is
    /// renamed.
    public static func projectsWithoutUsableDirectory(
        in projects: [SupervisionProject]
    ) -> [String] {
        projects.filter { !$0.hasUsableDirectory }.map(\.name).sorted()
    }

    private static func project(
        named name: String, repos: [UUID], policy: SupervisionPolicySource,
        sweep: SupervisionSweepSelection?, file: SupervisionFile
    ) -> SupervisionProject {
        SupervisionProject(
            name: name,
            repos: repos,
            policy: policy,
            sweep: sweep,
            mark: file.isMarked(name),
            declaredModes: file.declaredModes(for: name),
            activeMode: file.activeMode(for: name),
            supervisor: file.supervisors[name].map { .appointed(terminal: $0.terminal) }
                ?? .hostedDesk)
    }

    /// Moves a repo between projects, returning the new file.
    ///
    /// This is the only membership verb. There is deliberately no `add`/`remove`
    /// pair: `remove` could leave a repo belonging to nothing and `add` could
    /// put it in a second place, so the pair can express states the model
    /// forbids while `move` cannot express them at all (design §5).
    ///
    /// - `--to singleton` takes the repo out of its declared project, and
    ///   **deletes a declaration the move empties**, along with that vanished
    ///   project's mark, mode entry, and supervisor binding. A stale mark left
    ///   behind would silently turn a later project of the same name on without
    ///   an operator gesture.
    /// - Moving a repo that is a project's designated policy source out of a
    ///   project that would survive is refused: the project would be left with
    ///   no playbook.
    /// - A move that changes nothing (already there, already singleton) returns
    ///   an equal value.
    ///
    /// A move that cannot complete throws, and the input is untouched — this
    /// takes the file by value and never mutates through the caller's copy.
    public static func move(
        repo: UUID, to target: SupervisionMoveTarget, in file: SupervisionFile,
        repos: [SupervisionRepo]
    ) throws -> SupervisionFile {
        try file.validate()
        guard repos.contains(where: { $0.id == repo }) else {
            throw SupervisionTopologyError.unknownRepo(repo: repo)
        }

        let currentOwner = file.projects.first { $0.value.repos.contains(repo) }?.key

        switch target {
        case .project(let name):
            guard file.projects[name] != nil else {
                throw SupervisionTopologyError.unknownProject(project: name)
            }
            if currentOwner == name { return file }
        case .singleton:
            if currentOwner == nil { return file }
        }

        var updated = file
        if let owner = currentOwner, var declaration = updated.projects[owner] {
            let survives = declaration.repos.count > 1
            if survives, case .repo(let policyRepo) = declaration.policy, policyRepo == repo {
                throw SupervisionTopologyError.policySourceWouldLeaveProject(
                    project: owner, repo: repo)
            }
            declaration.repos.removeAll { $0 == repo }
            if declaration.repos.isEmpty {
                updated.projects.removeValue(forKey: owner)
                updated.supervised.removeAll { $0 == owner }
                updated.modes.removeValue(forKey: owner)
                updated.supervisors.removeValue(forKey: owner)
            } else {
                updated.projects[owner] = declaration
            }
        }

        if case .project(let name) = target, var declaration = updated.projects[name] {
            declaration.repos.append(repo)
            updated.projects[name] = declaration
        }

        try updated.validate()
        return updated
    }
}
