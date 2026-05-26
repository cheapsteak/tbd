import Testing
import Foundation
@testable import TBDShared

private struct TempHome {
    let url: URL
    var path: String { url.path }

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-cli-installer-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

private func makeFile(_ path: String, contents: Data = Data()) throws {
    let dir = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: contents)
}

private func inodeOf(_ path: String) -> (dev: Int32, ino: UInt64)? {
    var st = stat()
    guard stat(path, &st) == 0 else { return nil }
    return (st.st_dev, st.st_ino)
}

// MARK: - cliPath(forDaemonExecutable:)

@Test func cliPathDerivedFromSiblingOfDaemon() {
    let result = CLIInstaller.cliPath(forDaemonExecutable: "/Users/me/.build/debug/TBDDaemon")
    #expect(result == "/Users/me/.build/debug/TBDCLI")
}

@Test func cliPathHandlesAlternateDaemonName() {
    let result = CLIInstaller.cliPath(forDaemonExecutable: "/opt/tbd/bin/tbdd")
    #expect(result == "/opt/tbd/bin/TBDCLI")
}

// MARK: - currentState

@Test func currentStateNotInstalledWhenPathAbsent() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let installer = CLIInstaller(homeDir: home.path, pathProbe: { nil })
    let state = installer.currentState(expectedTarget: "/some/target")
    #expect(state == .notInstalled)
}

@Test func currentStateInstalledWhenHardLinkMatchesTargetInode() async throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/cli-target"
    try makeFile(target, contents: Data("hello".utf8))
    let installPath = home.path + "/.local/bin/tbd"

    let installer = CLIInstaller(installPath: installPath, homeDir: home.path, pathProbe: { nil })
    _ = try await installer.install(target: target)
    let state = installer.currentState(expectedTarget: target)
    #expect(state == .installed(target: target))
}

@Test func currentStateStaleWhenInstallPathInodeDiffersFromExpected() async throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let expected = home.path + "/expected-cli"
    let other = home.path + "/other-cli"
    try makeFile(expected, contents: Data("new".utf8))
    try makeFile(other, contents: Data("old".utf8))
    let installPath = home.path + "/.local/bin/tbd"

    // Install pointing at "other", then ask whether it matches "expected".
    let installer = CLIInstaller(installPath: installPath, homeDir: home.path, pathProbe: { nil })
    _ = try await installer.install(target: other)
    let state = installer.currentState(expectedTarget: expected)
    if case .stale = state {
        // ok
    } else {
        Issue.record("Expected .stale, got \(state)")
    }
}

@Test func currentStateUnexpectedFileTypeWhenDirectoryAtPath() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let installPath = home.path + "/.local/bin/tbd"
    try FileManager.default.createDirectory(atPath: installPath, withIntermediateDirectories: true)

    let installer = CLIInstaller(installPath: installPath, homeDir: home.path, pathProbe: { nil })
    let state = installer.currentState(expectedTarget: "/some/target")
    #expect(state == .unexpectedFileType)
}

@Test func currentStateStaleForLegacySymlinkTriggersLaunchTimeRefresh() throws {
    // Pre-PR installs created a symlink. Detecting that as `.stale` lets
    // the launch-time CLIInstallerCoordinator prompt re-install as a hard
    // link on the next refresh.
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/cli-target"
    try makeFile(target)
    let installPath = home.path + "/.local/bin/tbd"
    try FileManager.default.createDirectory(
        atPath: (installPath as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(atPath: installPath, withDestinationPath: target)

    let installer = CLIInstaller(installPath: installPath, homeDir: home.path, pathProbe: { nil })
    let state = installer.currentState(expectedTarget: target)
    if case .stale = state {
        // ok — even though the symlink points at the right target, it's
        // a legacy install and should be upgraded to a hard link.
    } else {
        Issue.record("Expected .stale for legacy symlink, got \(state)")
    }
}

@Test func currentStateStaleWhenExpectedTargetMissing() async throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/cli-target"
    try makeFile(target)
    let installPath = home.path + "/.local/bin/tbd"
    let installer = CLIInstaller(installPath: installPath, homeDir: home.path, pathProbe: { nil })
    _ = try await installer.install(target: target)

    // Delete the source. Hard link keeps the data alive, but caller asks
    // about an expected target that no longer exists → stale.
    try FileManager.default.removeItem(atPath: target)
    let state = installer.currentState(expectedTarget: target)
    if case .stale = state {
        // ok
    } else {
        Issue.record("Expected .stale, got \(state)")
    }
}

// MARK: - launchPromptKind

@Test func launchPromptKindIsNilWhenInstalled() {
    let state: CLIInstallState = .installed(target: "/bin/tbd")
    #expect(state.launchPromptKind(userPreviouslyDismissed: false) == nil)
    #expect(state.launchPromptKind(userPreviouslyDismissed: true) == nil)
}

@Test func launchPromptKindMissingWhenNotInstalledAndNotDismissed() {
    let state: CLIInstallState = .notInstalled
    #expect(state.launchPromptKind(userPreviouslyDismissed: false) == .missing)
}

@Test func launchPromptKindNilWhenNotInstalledAndPreviouslyDismissed() {
    let state: CLIInstallState = .notInstalled
    #expect(state.launchPromptKind(userPreviouslyDismissed: true) == nil)
}

@Test func launchPromptKindStaleAlwaysSurfacedRegardlessOfDismissal() {
    let state: CLIInstallState = .stale(currentTarget: "/old/tbd")
    #expect(state.launchPromptKind(userPreviouslyDismissed: false) == .stale(current: "/old/tbd"))
    #expect(state.launchPromptKind(userPreviouslyDismissed: true) == .stale(current: "/old/tbd"))
}

@Test func launchPromptKindUnexpectedFileTypeAlwaysSurfacedRegardlessOfDismissal() {
    let state: CLIInstallState = .unexpectedFileType
    #expect(state.launchPromptKind(userPreviouslyDismissed: false) == .unexpectedFileType)
    #expect(state.launchPromptKind(userPreviouslyDismissed: true) == .unexpectedFileType)
}

// MARK: - install

@Test func installCreatesParentDirectoryAndHardLink() async throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/build/TBDCLI"
    try makeFile(target, contents: Data("binary".utf8))
    let installPath = home.path + "/.local/bin/tbd"

    let installer = CLIInstaller(installPath: installPath, homeDir: home.path, pathProbe: { "/usr/bin:/bin" })
    let result = try await installer.install(target: target)
    #expect(result.installPath == installPath)
    #expect(result.target == target)

    // It's a regular file, not a symlink…
    var st = stat()
    #expect(lstat(installPath, &st) == 0)
    #expect((st.st_mode & S_IFMT) == S_IFREG)

    // …and shares the source's inode.
    let srcInode = inodeOf(target)
    let dstInode = inodeOf(installPath)
    #expect(srcInode != nil && dstInode != nil)
    #expect(srcInode?.ino == dstInode?.ino)
    #expect(srcInode?.dev == dstInode?.dev)

    // Link count should be ≥ 2 (source + install path).
    #expect(st.st_nlink >= 2)
}

@Test func installRefusesToReplaceDirectory() async throws {
    // FileManager.removeItem deletes directories recursively. If a directory
    // is unexpectedly at the install path, install() must refuse rather than
    // silently rm -rf based on a "Replace the file" confirmation.
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/cli"
    try makeFile(target)
    let installPath = home.path + "/.local/bin/tbd"
    // Create a directory at the install path with a file inside (to verify
    // we wouldn't have silently lost it).
    try FileManager.default.createDirectory(atPath: installPath, withIntermediateDirectories: true)
    try makeFile(installPath + "/important.txt")

    let installer = CLIInstaller(installPath: installPath, homeDir: home.path, pathProbe: { nil })
    do {
        _ = try await installer.install(target: target)
        Issue.record("Expected install to throw when a directory exists at the path")
    } catch let error as CLIInstallerError {
        if case .linkCreationFailed(let reason) = error {
            #expect(reason.contains("directory"))
        } else {
            Issue.record("Wrong CLIInstallerError case: \(error)")
        }
    }
    // The directory and its contents must still be there.
    #expect(FileManager.default.fileExists(atPath: installPath + "/important.txt"))
}

@Test func installReplacesExistingLegacySymlink() async throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let oldTarget = home.path + "/old-cli"
    let newTarget = home.path + "/new-cli"
    try makeFile(oldTarget)
    try makeFile(newTarget, contents: Data("new".utf8))
    let installPath = home.path + "/.local/bin/tbd"
    try FileManager.default.createDirectory(
        atPath: (installPath as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(atPath: installPath, withDestinationPath: oldTarget)

    let installer = CLIInstaller(installPath: installPath, homeDir: home.path, pathProbe: { "/usr/bin" })
    _ = try await installer.install(target: newTarget)

    // Now a hard link to newTarget, not a symlink.
    var st = stat()
    #expect(lstat(installPath, &st) == 0)
    #expect((st.st_mode & S_IFMT) == S_IFREG)
    #expect(inodeOf(installPath)?.ino == inodeOf(newTarget)?.ino)
}

@Test func hardLinkInstallSurvivesSourceDeletion() async throws {
    // Core property of the fix: removing the source `.build/.../TBDCLI`
    // (as `git worktree remove` does) does NOT brick `~/.local/bin/tbd`.
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/build/TBDCLI"
    let contents = Data("#!/bin/sh\necho hi\n".utf8)
    try makeFile(target, contents: contents)
    let installPath = home.path + "/.local/bin/tbd"

    let installer = CLIInstaller(installPath: installPath, homeDir: home.path, pathProbe: { nil })
    _ = try await installer.install(target: target)

    // Simulate worktree archive — wipe the source build dir.
    try FileManager.default.removeItem(atPath: home.path + "/build")

    // Install path still exists and still has the original contents.
    #expect(FileManager.default.fileExists(atPath: installPath))
    let recovered = try Data(contentsOf: URL(fileURLWithPath: installPath))
    #expect(recovered == contents)
}

// MARK: - PATH detection / on-PATH branch

@Test func installReportsOnPathWhenBinDirIsPresent() async throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/cli"
    try makeFile(target)
    let installPath = home.path + "/.local/bin/tbd"

    let homePath = home.path
    let probe: @Sendable () async -> String? = {
        "/usr/bin:\(homePath)/.local/bin:/sbin"
    }
    let installer = CLIInstaller(installPath: installPath, homeDir: home.path, pathProbe: probe)
    let result = try await installer.install(target: target)
    #expect(result.onPath == true)
    #expect(result.suggestedShellRC == nil)
    #expect(result.exportLine == nil)
}

@Test func installReportsOnPathWhenBinDirAppearsTildeExpanded() async throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/cli"
    try makeFile(target)
    let installPath = home.path + "/.local/bin/tbd"

    // Path string contains the tilde-prefixed form — should still match.
    let probe: @Sendable () async -> String? = { "/usr/bin:~/.local/bin:/sbin" }
    let installer = CLIInstaller(installPath: installPath, homeDir: home.path, pathProbe: probe)
    let result = try await installer.install(target: target)
    #expect(result.onPath == true)
}

// MARK: - PATH detection / off-PATH branch

@Test func installReportsOffPathAndZshRCByDefault() async throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/cli"
    try makeFile(target)
    let installPath = home.path + "/.local/bin/tbd"

    let installer = CLIInstaller(
        installPath: installPath,
        homeDir: home.path,
        shellPath: "/bin/zsh",
        pathProbe: { "/usr/bin:/bin" }
    )
    let result = try await installer.install(target: target)
    #expect(result.onPath == false)
    #expect(result.suggestedShellRC == "~/.zshrc")
    #expect(result.exportLine == "export PATH=\"$HOME/.local/bin:$PATH\"")
}

@Test func installReportsOffPathBashProfileForBash() async throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/cli"
    try makeFile(target)
    let installPath = home.path + "/.local/bin/tbd"

    let installer = CLIInstaller(
        installPath: installPath,
        homeDir: home.path,
        shellPath: "/bin/bash",
        pathProbe: { "/usr/bin:/bin" }
    )
    let result = try await installer.install(target: target)
    #expect(result.onPath == false)
    #expect(result.suggestedShellRC == "~/.bash_profile")
    #expect(result.exportLine == "export PATH=\"$HOME/.local/bin:$PATH\"")
}

@Test func installReportsOffPathFishConfigForFish() async throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/cli"
    try makeFile(target)
    let installPath = home.path + "/.local/bin/tbd"

    let installer = CLIInstaller(
        installPath: installPath,
        homeDir: home.path,
        shellPath: "/usr/local/bin/fish",
        pathProbe: { "/usr/bin:/bin" }
    )
    let result = try await installer.install(target: target)
    #expect(result.onPath == false)
    #expect(result.suggestedShellRC == "~/.config/fish/config.fish")
    #expect(result.exportLine == "set -gx PATH \"$HOME/.local/bin\" $PATH")
}

@Test func fishExportLineUsesHomeAndDoubleQuotesForNonDefaultBinDirWithSpaces() {
    // Tilde is NOT expanded inside fish single quotes, and $HOME is NOT
    // expanded inside single quotes either — so we use $HOME inside double
    // quotes, which both expands and preserves spaces.
    let (rc, line) = CLIInstaller.shellRCAndExport(
        forShellPath: "/usr/local/bin/fish",
        binDir: "/Users/me/Library/Application Support/tbd/bin",
        homeDir: "/Users/me"
    )
    #expect(rc == "~/.config/fish/config.fish")
    #expect(line == "set -gx PATH \"$HOME/Library/Application Support/tbd/bin\" $PATH")
}

@Test func bashExportLineUsesHomeForPathsOutsideHome() {
    // $HOME prefix only applies under the home dir; absolute paths elsewhere
    // are embedded as-is and the surrounding double quotes keep them intact.
    let (rc, line) = CLIInstaller.shellRCAndExport(
        forShellPath: "/bin/bash",
        binDir: "/opt/tbd/bin",
        homeDir: "/Users/me"
    )
    #expect(rc == "~/.bash_profile")
    #expect(line == "export PATH=\"/opt/tbd/bin:$PATH\"")
}

@Test func pathProbeReturningNilTreatedAsOffPath() async throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/cli"
    try makeFile(target)
    let installPath = home.path + "/.local/bin/tbd"

    let installer = CLIInstaller(installPath: installPath, homeDir: home.path, pathProbe: { nil })
    let result = try await installer.install(target: target)
    #expect(result.onPath == false)
    #expect(result.exportLine != nil)
}
