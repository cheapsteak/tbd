import Foundation

/// How a `BuildIdentity` was learned, which is what tells a consumer how much
/// to trust it.
public enum BuildIdentityOrigin: String, Codable, Sendable, CaseIterable {
    /// Read from the `TBDBuildIdentity.json` sidecar the build wrapper wrote
    /// before the compiler ran. Describes the tree this binary came from.
    case stamp
    /// Derived after the fact from `git rev-parse HEAD` of the worktree the
    /// executable path points into. **May be stale**: the worktree has moved on
    /// since the binary was built if anyone committed or checked out in between.
    case worktreeHead
}

/// What commit a running TBD binary was built from.
///
/// TBD has no tags and no release workflow, so "which version am I running" has
/// exactly one honest answer: a commit. Learned once at process start (see
/// `BuildIdentityLoader`) and reported through `daemon.status`, `tbd version`
/// and the app's update notice.
///
/// Every field but `commit` is optional-ish in practice — a sidecar written by
/// a future build wrapper may carry keys this type does not know, and unknown
/// keys are ignored rather than rejected, so an older binary can still read a
/// newer stamp.
public struct BuildIdentity: Codable, Sendable, Equatable {
    /// Full 40-character SHA.
    public let commit: String
    /// Abbreviated SHA as the stamping wrapper spelled it (7+ hex characters).
    public let shortCommit: String
    /// Branch the build came from. `HEAD` for a detached build.
    public let branch: String
    /// ISO-8601 timestamp of the stamp, as a string. Deliberately not a `Date`:
    /// this value is displayed and compared for equality, never arithmetic, and
    /// a parse failure on an odd stamp must not lose the rest of the identity.
    public let builtAt: String?
    /// Absolute path of the worktree the binary was built from. The update path
    /// resolves `scripts/update.sh` relative to this.
    public let sourceWorktree: String?
    /// Whether that worktree had uncommitted changes at stamp time.
    public let dirty: Bool
    /// How this value was learned. Absent from the sidecar on disk — the
    /// loader fills it in, because it is a fact about the *reading*, not about
    /// the build.
    public let origin: BuildIdentityOrigin

    public init(
        commit: String,
        shortCommit: String,
        branch: String,
        builtAt: String? = nil,
        sourceWorktree: String? = nil,
        dirty: Bool = false,
        origin: BuildIdentityOrigin = .stamp
    ) {
        self.commit = commit
        self.shortCommit = shortCommit
        self.branch = branch
        self.builtAt = builtAt
        self.sourceWorktree = sourceWorktree
        self.dirty = dirty
        self.origin = origin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        commit = try c.decode(String.self, forKey: .commit)
        // A sidecar that names only the full SHA is still usable: abbreviate it
        // ourselves rather than refusing the whole stamp.
        shortCommit = try c.decodeIfPresent(String.self, forKey: .shortCommit)
            ?? String(commit.prefix(7))
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? "HEAD"
        builtAt = try c.decodeIfPresent(String.self, forKey: .builtAt)
        sourceWorktree = try c.decodeIfPresent(String.self, forKey: .sourceWorktree)
        dirty = try c.decodeIfPresent(Bool.self, forKey: .dirty) ?? false
        // Absent in the on-disk sidecar, present on the wire. A stamp read off
        // disk is by definition `.stamp`; the loader overrides for the fallback.
        origin = try c.decodeIfPresent(BuildIdentityOrigin.self, forKey: .origin) ?? .stamp
    }

    /// The same identity, re-labelled with how it was learned.
    public func withOrigin(_ origin: BuildIdentityOrigin) -> BuildIdentity {
        BuildIdentity(
            commit: commit, shortCommit: shortCommit, branch: branch,
            builtAt: builtAt, sourceWorktree: sourceWorktree, dirty: dirty,
            origin: origin)
    }

    /// Short display form: `<short>` or `<short>-dirty`.
    public var displayCommit: String {
        dirty ? "\(shortCommit)-dirty" : shortCommit
    }
}

/// Learns a `BuildIdentity` from the filesystem around a running executable.
///
/// Three sources, tried in order:
///
/// 1. `TBDBuildIdentity.json` beside the resolved binary — what the build
///    wrapper stamps into `.build/<config>/`.
/// 2. `Contents/TBDBuildIdentity.json` in the app bundle — the same file,
///    copied in when the bundle is assembled, because the app executable lives
///    at `Contents/MacOS/TBDApp` and its sibling directory is not the build
///    directory.
/// 3. `git rev-parse HEAD` of the worktree derived from the executable path
///    (the parent of `.build`), marked `.worktreeHead` so a consumer knows it
///    may be stale.
///
/// Everything it touches is injected, so the whole decision table is testable
/// without a build directory, a bundle, or a git repository.
public enum BuildIdentityLoader {
    /// The sidecar's file name, in both locations. Load-bearing: the build
    /// wrapper writes this exact name.
    public static let sidecarFileName = "TBDBuildIdentity.json"

    /// What `gitHead` returns for a worktree: the commit and the branch it was
    /// on, or nil when the path is not a git worktree (or git failed).
    public struct WorktreeHead: Sendable, Equatable {
        public let commit: String
        public let branch: String
        public let dirty: Bool
        public init(commit: String, branch: String, dirty: Bool = false) {
            self.commit = commit
            self.branch = branch
            self.dirty = dirty
        }
    }

    /// Resolve the identity of the binary at `executablePath`.
    ///
    /// - Parameters:
    ///   - executablePath: absolute path of the resolved (symlink-followed)
    ///     binary. `nil` skips both the sibling sidecar and the git fallback.
    ///   - bundleContentsPath: absolute path of the app bundle's `Contents`
    ///     directory, when the caller runs from a bundle. `nil` for the daemon
    ///     and the CLI.
    ///   - fileReader: reads a file's bytes, or nil when it does not exist.
    ///   - gitHead: resolves a worktree path to its HEAD, or nil.
    /// - Returns: the identity, or nil when nothing on disk could say.
    public static func load(
        executablePath: String?,
        bundleContentsPath: String? = nil,
        fileReader: (String) -> Data? = { FileManager.default.contents(atPath: $0) },
        gitHead: (String) -> WorktreeHead? = { _ in nil }
    ) -> BuildIdentity? {
        let decoder = JSONDecoder()

        // 1. Beside the binary.
        if let executablePath, !executablePath.isEmpty {
            let sibling = URL(fileURLWithPath: executablePath)
                .deletingLastPathComponent()
                .appendingPathComponent(sidecarFileName).path
            if let data = fileReader(sibling),
               let identity = try? decoder.decode(BuildIdentity.self, from: data) {
                return identity.withOrigin(.stamp)
            }
        }

        // 2. In the bundle. Checked second so a bundled binary that also has a
        //    sibling stamp (an in-place `.build/debug/TBD.app`) prefers the one
        //    written for that exact binary.
        if let bundleContentsPath, !bundleContentsPath.isEmpty {
            let bundled = URL(fileURLWithPath: bundleContentsPath)
                .appendingPathComponent(sidecarFileName).path
            if let data = fileReader(bundled),
               let identity = try? decoder.decode(BuildIdentity.self, from: data) {
                return identity.withOrigin(.stamp)
            }
        }

        // 3. The worktree the executable sits inside. May be stale — the tree
        //    can have moved on since this binary was linked — hence the origin.
        if let worktree = sourceWorktree(fromExecutablePath: executablePath),
           let head = gitHead(worktree) {
            return BuildIdentity(
                commit: head.commit,
                shortCommit: String(head.commit.prefix(7)),
                branch: head.branch,
                builtAt: nil,
                sourceWorktree: worktree,
                dirty: head.dirty,
                origin: .worktreeHead)
        }

        return nil
    }

    /// Production `gitHead`: one `git rev-parse` in `worktree`, returning its
    /// HEAD commit and branch.
    ///
    /// Synchronous and bounded by construction — `rev-parse` reads refs and
    /// exits, touching no network and no index — and called at most once per
    /// process, behind the `static let` that memoizes the identity. It reports
    /// `dirty: false` always: deciding dirtiness needs `git status`, which walks
    /// the whole worktree, and this fallback path is already the one that
    /// cannot be trusted for precision (see `BuildIdentityOrigin.worktreeHead`).
    public static func systemGitHead(_ worktree: String) -> WorktreeHead? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", worktree, "rev-parse", "HEAD", "--abbrev-ref", "HEAD"]
        // Pin the locale for the same reason `GitManager.gitEnvironment` does:
        // a localized git speaks a language the parser does not.
        process.environment = ProcessInfo.processInfo.environment
            .merging(["LC_ALL": "C", "LANG": "C"]) { _, pinned in pinned }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let commit = lines.first, !commit.isEmpty else { return nil }
        let branch = lines.count > 1 ? lines[1] : "HEAD"
        return WorktreeHead(commit: commit, branch: branch, dirty: false)
    }

    /// The worktree a `.build`-relative executable path points into: everything
    /// before the last `/.build/`. Nil when the path has no `.build` component,
    /// which is the case for an installed binary (`/Applications/TBD.app/…`,
    /// `~/.local/bin/tbd`).
    ///
    /// Same derivation `SourceWorktreePathResolver` uses in the app, kept here
    /// so the daemon and the CLI — neither of which has a bundle — can reach it.
    public static func sourceWorktree(fromExecutablePath path: String?) -> String? {
        guard let path, !path.isEmpty,
              let range = path.range(of: "/.build/", options: .backwards)
        else { return nil }
        let worktree = String(path[..<range.lowerBound])
        return worktree.isEmpty ? nil : worktree
    }
}
