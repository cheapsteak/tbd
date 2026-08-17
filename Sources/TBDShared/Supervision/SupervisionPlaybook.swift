import CryptoKit
import Foundation

// MARK: - Tiers

/// Which level of playbook resolution answered
/// (`docs/specs/2026-07-26-fleet-supervision-design.md` §5).
///
/// Three levels, in this order, first existing non-empty file wins, **per
/// project**. The system uses the whole file and never merges levels: a
/// present operator copy is the conduct, and the levels beneath it are not
/// consulted, not appended, and not mentioned in the result except as skipped.
public enum SupervisionPlaybookTier: String, Codable, Sendable, CaseIterable {
    /// The operator's own copy — beside a declared project's definition, or in
    /// a singleton's per-repo config directory.
    case `operator`
    /// The designated repo's in-repo file, `.agents/supervision.md`.
    case repo
    /// The tool's shipped default, the only level TBD owns.
    case shipped
}

/// The two levels the "Customize playbook…" gesture can write. `shipped` is
/// absent deliberately: it is the tool's, replaced by updates, and nothing
/// writes it at runtime.
public enum SupervisionPlaybookLevel: String, Codable, Sendable, CaseIterable {
    case `operator`
    case repo

    public var tier: SupervisionPlaybookTier {
        switch self {
        case .operator: return .operator
        case .repo: return .repo
        }
    }
}

// MARK: - The resolved playbook

/// A level that existed as a path but did not answer, and why.
///
/// Present so a fall-through is visible rather than silent. A playbook an
/// operator wrote and then truncated, or one whose permissions changed, would
/// otherwise resolve to the level below with nothing anywhere saying the copy
/// they are editing is being ignored.
public struct SupervisionPlaybookSkippedLevel: Codable, Sendable, Equatable {
    public enum Reason: String, Codable, Sendable {
        /// The file exists and holds no bytes. An empty copy is not conduct.
        case empty
        /// The file could not be read — absent, or unreadable.
        case unreadable
    }

    public let tier: SupervisionPlaybookTier
    public let path: String
    public let reason: Reason

    public init(tier: SupervisionPlaybookTier, path: String, reason: Reason) {
        self.tier = tier
        self.path = path
        self.reason = reason
    }
}

/// One project's resolved playbook: which level answered, where it came from,
/// its bytes verbatim, and the conduct hash the ledger records per delivery.
///
/// **TBD never parses these bytes.** There is deliberately no line splitting,
/// section extraction, or mode-name derivation anywhere on this type. Mode
/// names come from `supervision.json`; the desk is the only structure-aware
/// reader of the prose.
public struct SupervisionPlaybook: Sendable, Equatable {
    public let project: String
    public let tier: SupervisionPlaybookTier
    /// The absolute path the bytes came from — nil for `.shipped`, which has
    /// no file on disk.
    public let path: String?
    /// The playbook's bytes, exactly as they were read.
    public let bytes: Data
    /// SHA-256 of `bytes`, lowercase hex. What a desk's standing conduct is
    /// versioned by: headers carry deltas only while a session's hash and the
    /// current hash differ (sweep-program design §8).
    public let conductHash: String
    /// Levels that had a path but did not answer, nearest level first.
    public let skipped: [SupervisionPlaybookSkippedLevel]

    public init(project: String, tier: SupervisionPlaybookTier, path: String?,
                bytes: Data, skipped: [SupervisionPlaybookSkippedLevel] = []) {
        self.project = project
        self.tier = tier
        self.path = path
        self.bytes = bytes
        self.conductHash = SupervisionPlaybook.hash(of: bytes)
        self.skipped = skipped
    }

    /// The bytes as text. Decoding is for display and transport only — the
    /// hash is over `bytes`, so a file that is not valid UTF-8 still hashes and
    /// installs as itself.
    ///
    /// Deliberately the lossy decoding rather than the failable initializer: a
    /// playbook has to be showable whatever an editor did to it, and a nil here
    /// would turn "your file has one bad byte" into "there is no playbook".
    // swiftlint:disable:next optional_data_string_conversion
    public var text: String { String(decoding: bytes, as: UTF8.self) }

    /// SHA-256, lowercase hex. CryptoKit, matching the codebase's existing
    /// digests (`RemoteSessionIdentity`, `ClaudeCodeCredentialsKeychain`).
    public static func hash(of bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Where the levels are

/// The two candidate paths for one project, in resolution order.
///
/// Composed rather than discovered, so resolution itself is a pure walk over
/// paths and the *policy* question — which repo, whether the repo tier applies
/// at all — is answered once, where the topology is known.
public struct SupervisionPlaybookSite: Sendable, Equatable {
    public let project: String
    /// The operator's copy. Optional for the type's sake rather than for any
    /// topology the daemon can produce: a declared project's name is validated
    /// as one path component before resolution runs, and a singleton's path is
    /// keyed by repo id, so both always compose. Nil is left expressible only
    /// for a project that is neither declared nor holds a repo.
    public let operatorPath: String?
    /// The designated repo's `.agents/supervision.md`. Nil when the project's
    /// policy is `{"operator": true}` — that designation *is* "there is no repo
    /// tier" — or when the designated repo's checkout is unknown.
    public let repoPath: String?

    public init(project: String, operatorPath: String?, repoPath: String?) {
        self.project = project
        self.operatorPath = operatorPath
        self.repoPath = repoPath
    }
}

// MARK: - Resolution

/// Resolves a project's playbook: path, bytes, hash. Nothing else.
///
/// Path resolution honors `TBD_HOME` through `TBDConstants` on every call,
/// because the environment is held on the instance and handed to each helper.
/// There is deliberately **no static twin** that builds its own paths — that is
/// exactly how an injected seam becomes decorative and a test suite ends up
/// writing into the developer's real `~/tbd`.
public struct SupervisionPlaybookResolver: Sendable {
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    /// Where a project's two file levels are.
    ///
    /// **Declared-ness is read from the file, not from the resolved project**,
    /// and that is the only honest place it can come from. `SupervisionProject`
    /// carries no `isSingleton` flag by design: a fresh install and one whose
    /// file declares a single-repo project per repo must resolve to equal
    /// values. The *storage layout* of the operator level nonetheless differs —
    /// a declared project's copy lives beside its definition, a singleton's in
    /// the per-repo config directory it already has — so the question "is there
    /// a declaration under this name" is asked of `SupervisionFile`, which is
    /// where declarations live.
    public func site(
        for project: SupervisionProject, in file: SupervisionFile, repos: [SupervisionRepo]
    ) -> SupervisionPlaybookSite {
        let isDeclared = file.projects[project.name] != nil
        let operatorPath: String?
        if isDeclared {
            operatorPath = TBDConstants.supervisionPlaybookPath(
                project: project.name, environment: environment)
        } else if let repo = project.repos.first {
            operatorPath = TBDConstants.repoPlaybookPath(repoID: repo, environment: environment)
        } else {
            operatorPath = nil
        }

        let repoPath: String?
        switch project.policy {
        case .operator:
            // The project designated the operator level as its policy source,
            // so there is no repo tier to fall through to — the shipped default
            // is what stands below it.
            repoPath = nil
        case .repo(let repoID):
            let checkout = repos.first(where: { $0.id == repoID })?.path ?? ""
            repoPath = checkout.isEmpty ? nil : TBDConstants.repoAgentsPlaybookPath(checkout: checkout)
        }

        return SupervisionPlaybookSite(
            project: project.name, operatorPath: operatorPath, repoPath: repoPath)
    }

    /// The resolved playbook for a site: first existing non-empty file wins,
    /// operator then repo, then the shipped default.
    ///
    /// An unreadable or empty file falls through to the next level and is named
    /// in `skipped` — an empty operator copy is not conduct, and reading it as
    /// conduct would install silence over a repo file that says something.
    public func resolve(_ site: SupervisionPlaybookSite) -> SupervisionPlaybook {
        var skipped: [SupervisionPlaybookSkippedLevel] = []
        for candidate in [(SupervisionPlaybookTier.operator, site.operatorPath),
                          (SupervisionPlaybookTier.repo, site.repoPath)] {
            let (tier, maybePath) = candidate
            guard let path = maybePath, !path.isEmpty else { continue }
            guard let bytes = FileManager.default.contents(atPath: path) else {
                // Absent is the ordinary case and unreadable is the rare one,
                // and this cannot tell them apart without a second stat that
                // could disagree with the read. Only a path that *exists* is
                // worth reporting as skipped; a level nobody wrote is not a
                // finding.
                if FileManager.default.fileExists(atPath: path) {
                    skipped.append(SupervisionPlaybookSkippedLevel(
                        tier: tier, path: path, reason: .unreadable))
                }
                continue
            }
            guard !bytes.isEmpty else {
                skipped.append(SupervisionPlaybookSkippedLevel(
                    tier: tier, path: path, reason: .empty))
                continue
            }
            return SupervisionPlaybook(
                project: site.project, tier: tier, path: path, bytes: bytes, skipped: skipped)
        }
        return SupervisionPlaybook(
            project: site.project, tier: .shipped, path: nil,
            bytes: SupervisionPlaybookContent.bytes, skipped: skipped)
    }

    /// Compose the site and resolve it — what every caller that already holds
    /// the topology wants.
    public func resolve(
        project: SupervisionProject, in file: SupervisionFile, repos: [SupervisionRepo]
    ) -> SupervisionPlaybook {
        resolve(site(for: project, in: file, repos: repos))
    }
}

// MARK: - The wire surface

/// Params for `supervise.playbook` — `tbd supervise playbook show`.
public struct SupervisePlaybookParams: Codable, Sendable, Equatable {
    public let project: String
    public init(project: String) { self.project = project }
}

/// Params for `supervise.playbookCustomize` — the "Customize playbook…"
/// gesture, which copies the current shipped default into one level and never
/// writes that level again.
public struct SupervisePlaybookCustomizeParams: Codable, Sendable, Equatable {
    public let project: String
    public let level: SupervisionPlaybookLevel

    public init(project: String, level: SupervisionPlaybookLevel) {
        self.project = project
        self.level = level
    }
}

/// What `supervise.playbook` answers: which level stands, where it is, its
/// hash, and its bytes.
///
/// The content rides along unconditionally rather than behind a parameter. It
/// was already read to be hashed, a playbook is prose sized for a human, and a
/// second round trip to fetch it would be a second answer to a question with
/// one. The CLI decides whether to print it.
public struct SupervisionPlaybookView: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let project: String
    public let tier: SupervisionPlaybookTier
    /// Null for the shipped default, which has no file on disk.
    public let path: String?
    /// SHA-256 of the bytes, lowercase hex.
    public let hash: String
    public let content: String
    /// Levels that had a path and did not answer. Empty in the ordinary case.
    public let skipped: [SupervisionPlaybookSkippedLevel]

    public init(project: String, tier: SupervisionPlaybookTier, path: String?,
                hash: String, content: String,
                skipped: [SupervisionPlaybookSkippedLevel],
                schemaVersion: Int = SupervisionPlaybookView.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.project = project
        self.tier = tier
        self.path = path
        self.hash = hash
        self.content = content
        self.skipped = skipped
    }

    public init(_ playbook: SupervisionPlaybook) {
        self.init(project: playbook.project, tier: playbook.tier, path: playbook.path,
                  hash: playbook.conductHash, content: playbook.text,
                  skipped: playbook.skipped)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, project, tier, path, hash, content, skipped
    }

    /// Written by hand because synthesized `Codable` *omits* a nil optional, and
    /// the shipped tier — every project's answer before anyone customizes
    /// anything — is exactly the case with no path. `"path":null` says "TBD
    /// resolved this and there is no file"; an absent key says nothing, and
    /// leaves a reader unable to tell that answer from an older build that did
    /// not carry the field. Same rule as the readout, ledger and brief surfaces.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(project, forKey: .project)
        try container.encode(tier, forKey: .tier)
        try container.encode(path, forKey: .path)
        try container.encode(hash, forKey: .hash)
        try container.encode(content, forKey: .content)
        try container.encode(skipped, forKey: .skipped)
    }
}

/// What `supervise.playbookCustomize` answers: the level it took ownership of,
/// and the path it wrote.
public struct SupervisePlaybookCustomizeResult: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let project: String
    public let level: SupervisionPlaybookLevel
    public let path: String
    /// The hash of the bytes just written — the shipped default's, since that
    /// is what a customize copies.
    public let hash: String

    public init(project: String, level: SupervisionPlaybookLevel, path: String, hash: String,
                schemaVersion: Int = SupervisePlaybookCustomizeResult.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.project = project
        self.level = level
        self.path = path
        self.hash = hash
    }
}

// MARK: - Errors

/// Why a playbook gesture was refused. Every message names the path or the
/// condition — these reach a human on stderr.
public enum SupervisionPlaybookError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case alreadyCustomized(project: String, level: SupervisionPlaybookLevel, path: String)
    case noOperatorLevel(project: String)
    case noRepoLevel(project: String)
    case unknownRepoCheckout(project: String, repo: UUID)
    case missingRepoCheckout(project: String, checkout: String)
    case writeFailed(path: String, detail: String)

    public var description: String {
        switch self {
        case .alreadyCustomized(let project, let level, let path):
            return "The \(level.rawValue)-level playbook for project \"\(project)\" already "
                + "exists at \(path), and TBD writes that level exactly once. Edit the file "
                + "directly; nothing here will overwrite it."
        case .noOperatorLevel(let project):
            return "Project \"\(project)\" has neither a declaration nor a member repo, so "
                + "there is no operator-level playbook location to write: the operator level "
                + "lives beside a declaration or in a member repo's config directory."
        case .noRepoLevel(let project):
            return "Project \"\(project)\" designates the operator level as its policy source, "
                + "so it has no repo-level playbook. Customize the operator level instead, or "
                + "designate a member repo's policy first."
        case .unknownRepoCheckout(let project, let repo):
            return "Project \"\(project)\" designates repo \(repo.uuidString) as its policy "
                + "source, but TBD does not know that repo's checkout, so there is no "
                + "repo-level playbook path to write."
        case .missingRepoCheckout(let project, let checkout):
            return "Project \"\(project)\" designates a repo whose checkout \(checkout) is not "
                + "on disk. Writing there would create a directory tree outside any repository "
                + "and then refuse to write it again. Restore the checkout first."
        case .writeFailed(let path, let detail):
            return "The playbook at \(path) could not be written: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}
