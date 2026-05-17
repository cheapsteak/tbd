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

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/realpath")
    process.arguments = [extDir.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let canonicalPath = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? extDir.path

    return (tempDir, repoDir, canonicalPath, branch)
}
