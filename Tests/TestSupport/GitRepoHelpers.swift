import Foundation

/// Creates a fresh git repo in a unique temp directory with one empty commit
/// on `main`. The caller owns `tempDir` and is responsible for cleanup
/// (`try? FileManager.default.removeItem(at: tempDir)`).
public func createTestRepo() async throws -> (tempDir: URL, repoDir: URL) {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-test-\(UUID().uuidString)")
    let repoDir = tempDir.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    try await shell("git init -b main && git commit --allow-empty -m 'init'", at: repoDir)
    return (tempDir: tempDir, repoDir: repoDir)
}

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
    try await shell("git init -b main && git commit --allow-empty -m 'init'", at: repoDir)
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
