import Foundation

/// Creates a fresh git repo in a unique temp directory with one empty commit
/// on `main`. The caller owns `tempDir` and is responsible for cleanup
/// (`try? FileManager.default.removeItem(at: tempDir)`).
///
/// The repository is a copy of a per-process template; see
/// ``initTestRepo(at:)`` for what that means for the commit it holds.
public func createTestRepo() async throws -> (tempDir: URL, repoDir: URL) {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-test-\(UUID().uuidString)")
    let repoDir = tempDir.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    try await initTestRepo(at: repoDir)
    return (tempDir: tempDir, repoDir: repoDir)
}

/// Makes the existing directory `repoDir` a git repository holding one empty
/// commit, `init`, on `main` — the repository that
/// `git init -b main && git commit --allow-empty -m 'init'` run through
/// ``shell(_:at:)`` leaves behind — by copying a template's `.git` into it.
/// Files already in `repoDir` are left untracked, as that command would leave
/// them. `repoDir` must not contain a `.git` yet.
///
/// **Why a template.** That command is three child processes per repository,
/// and `createTestRepo()` and `createTestRepoResolvingSymlinks()` have about
/// 250 call sites between them. The template is built once per test process,
/// through `shell(_:at:)` so it has the same hermetic identity and config:
/// the first call waits on that build, and every call after it is an
/// in-process copy with no child to wait for.
///
/// **What the copies share.** Every repository made this way in one process
/// has the same `init` commit: the same SHA and the same timestamp. That was
/// already routine before the template — an empty tree, a fixed message and a
/// fixed identity give the same SHA to any two repositories initialized in
/// the same second — and nothing in TBD keys on a commit SHA across
/// repositories. A test that needs two repositories with unrelated histories
/// must commit something distinct into one of them.
///
/// **Why a copy is safe to mutate.** Nothing in a plain repository's `.git`
/// records its own absolute path, so a copy is a complete, independent
/// repository. `copyItem` writes new files — cloned copy-on-write on APFS,
/// never hard-linked — so a test writing to its copy cannot reach the template
/// or a sibling's copy.
public func initTestRepo(at repoDir: URL) async throws {
    let template = try await TestRepoTemplate.shared.gitDirectory()
    try FileManager.default.copyItem(at: template, to: repoDir.appendingPathComponent(".git"))
}

/// Builds the template behind ``initTestRepo(at:)`` once per process.
///
/// An actor holding the build's `Task`, so concurrent first callers all await
/// the one build instead of racing to write the same directory: the check and
/// the store in `gitDirectory()` have no suspension point between them.
private actor TestRepoTemplate {
    static let shared = TestRepoTemplate()

    /// The build in flight, or the finished one. A failed build is dropped
    /// rather than cached: the callers already waiting on it fail, as each of
    /// them would have failed building its own repository, and the next caller
    /// builds again instead of inheriting one transient failure (a fork refused
    /// under load) for the rest of the run.
    private var build: Task<URL, any Error>?

    func gitDirectory() async throws -> URL {
        let pending: Task<URL, any Error>
        if let build {
            pending = build
        } else {
            pending = Task { try await Self.buildTemplate() }
            build = pending
        }
        do {
            return try await pending.value
        } catch {
            if build == pending { build = nil }
            throw error
        }
    }

    private static func buildTemplate() async throws -> URL {
        let repoDir = URL(fileURLWithPath: testRepoTemplateRoot).appendingPathComponent("repo")
        do {
            try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
            try await shell("git init -b main && git commit --allow-empty -m 'init'", at: repoDir)
        } catch {
            // A failed build removes what it wrote, so a retry starts from an
            // empty root and an unfenced run that never retries leaves no
            // half-written `.git` that no `atexit` handler covers.
            try? FileManager.default.removeItem(atPath: testRepoTemplateRoot)
            throw error
        }
        // Only a successful build gets here, and a successful build is never
        // repeated, so this registers once per process.
        atexit { try? FileManager.default.removeItem(atPath: testRepoTemplateRoot) }
        return repoDir.appendingPathComponent(".git")
    }
}

/// Where the template lives: under the run root that `scripts/test.sh` deletes
/// on exit, killed or not (see `fencedScratchRoot(prefix:)`). The `atexit`
/// removal above covers a run outside the wrapper that exits normally; only an
/// unfenced run that is killed or crashes leaves it behind, in `/tmp`.
///
/// The root holds no socket, so `fencedScratchRoot`'s `sun_path` budget does
/// not constrain the prefix; it is used for the kill-proof reclaim alone. Not
/// under `TBD_HOME`: suites under `TBDHomeSerialized` point that at a
/// directory of their own and delete it in teardown, so a template minted
/// while one of them ran would vanish from under every later copy.
private let testRepoTemplateRoot = fencedScratchRoot(prefix: "tbd-repo-template")

/// Like `createTestRepo()` but resolves all symlinks in the returned paths so
/// the path matches what `git worktree list` reports.
///
/// On macOS, `FileManager.default.temporaryDirectory` returns `/var/folders/…`
/// which is a symlink to `/private/var/folders/…`. `URL.resolvingSymlinksInPath()`
/// does NOT resolve this particular symlink, but the C `realpath()` function does.
/// Git resolves the real path when recording worktree entries, so DB paths must
/// also use the real path for reconcile path-matching to succeed.
public func createTestRepoResolvingSymlinks() async throws -> (tempDir: URL, repoDir: URL) {
    let (rawTempDir, _) = try await createTestRepo()
    let resolved: URL
    if let cReal = realpath(rawTempDir.path, nil) {
        resolved = URL(fileURLWithPath: String(cString: cReal))
        free(cReal)
    } else {
        resolved = rawTempDir
    }
    let repoDir = resolved.appendingPathComponent("repo")
    return (tempDir: resolved, repoDir: repoDir)
}

/// Thrown when `realpath()` refuses a directory this process just created —
/// never expected, but it is the one way `makeCanonicalScratchDirectory` can
/// hand back a path that is not actually canonical, so it fails loudly instead.
public struct CanonicalScratchDirectoryFailure: Error, CustomStringConvertible {
    public let path: String
    public let errnoValue: Int32
    public var description: String {
        "realpath() failed with errno \(errnoValue) on the freshly created scratch directory \(path)"
    }
}

/// Creates a unique empty scratch directory and returns its `realpath`-resolved
/// path, so every path built underneath it is already canonical. The caller
/// owns it (`try? FileManager.default.removeItem(atPath: dir)`).
///
/// For tests whose subject canonicalizes the paths it is handed, which TBD
/// does everywhere it compares a path against git's always-canonical worktree
/// output. A hardcoded literal is the wrong fixture there, because `realpath(3)`
/// takes a different branch depending on whether the path happens to exist:
/// it resolves an existing one (following `/tmp` -> `/private/tmp`) and fails
/// with `ENOENT` on a missing one, leaving callers to fall back to the input.
/// So `/tmp/a` means `/private/tmp/a` on a machine where some unrelated
/// process left that file lying around and `/tmp/a` on one where it did not —
/// a unit test silently reading the developer's filesystem.
///
/// Paths built under this directory close that branch by construction: every
/// component is already symlink-free, so resolving one of them is the identity
/// whether or not it exists on disk.
public func makeCanonicalScratchDirectory(prefix: String) throws -> String {
    let raw = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    errno = 0
    guard let resolved = realpath(raw.path, nil) else {
        throw CanonicalScratchDirectoryFailure(path: raw.path, errnoValue: errno)
    }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Sets up a temp git repo with one worktree at a non-canonical (external)
/// path. Returns the canonicalized worktree path (via `realpath`) so it
/// matches what `git worktree list` reports.
///
/// Used for adoption tests where the worktree lives outside TBD's canonical
/// `<repo>/.tbd/worktrees/` layout.
public func makeRepoWithExternalWorktree(
    branch: String = "feature-x",
    folder: String = "feature-x"
) async throws -> (tempDir: URL, repoDir: URL, worktreePath: String, worktreeBranch: String) {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-adopt-test-\(UUID().uuidString)")
    let repoDir = tempDir.appendingPathComponent("repo")
    let extDir = tempDir.appendingPathComponent("external-worktrees/\(folder)")
    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: extDir.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try await initTestRepo(at: repoDir)
    try await shell("git worktree add -b \(branch) '\(extDir.path)'", at: repoDir)

    // Use C realpath() (same approach as createTestRepoResolvingSymlinks) so the
    // returned path matches what `git worktree list` reports. On macOS,
    // /var/folders/… is a symlink to /private/var/folders/… that
    // URL.resolvingSymlinksInPath() does not resolve, but C realpath() does.
    let canonicalPath: String
    if let cReal = realpath(extDir.path, nil) {
        canonicalPath = String(cString: cReal)
        free(cReal)
    } else {
        canonicalPath = extDir.path
    }

    return (tempDir, repoDir, canonicalPath, branch)
}
