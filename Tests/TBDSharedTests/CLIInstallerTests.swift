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

private func makeFile(_ path: String) throws {
    let dir = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data())
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

@Test func currentStateNotInstalledWhenSymlinkAbsent() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let installer = CLIInstaller(homeDir: home.path, pathProbe: { nil })
    let state = installer.currentState(expectedTarget: "/some/target")
    #expect(state == .notInstalled)
}

@Test func currentStateInstalledWhenSymlinkPointsAtExpectedExistingTarget() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/cli-target"
    try makeFile(target)
    let symlink = home.path + "/.local/bin/tbd"
    try FileManager.default.createDirectory(
        atPath: (symlink as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(atPath: symlink, withDestinationPath: target)

    let installer = CLIInstaller(symlinkPath: symlink, homeDir: home.path, pathProbe: { nil })
    let state = installer.currentState(expectedTarget: target)
    #expect(state == .installed(target: target))
}

@Test func currentStateStaleWhenSymlinkPointsElsewhere() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let expected = home.path + "/expected-cli"
    let other = home.path + "/other-cli"
    try makeFile(expected)
    try makeFile(other)
    let symlink = home.path + "/.local/bin/tbd"
    try FileManager.default.createDirectory(
        atPath: (symlink as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(atPath: symlink, withDestinationPath: other)

    let installer = CLIInstaller(symlinkPath: symlink, homeDir: home.path, pathProbe: { nil })
    let state = installer.currentState(expectedTarget: expected)
    #expect(state == .stale(currentTarget: other))
}

@Test func currentStateNonSymlinkWhenRegularFileExistsAtPath() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let symlink = home.path + "/.local/bin/tbd"
    try makeFile(symlink)

    let installer = CLIInstaller(symlinkPath: symlink, homeDir: home.path, pathProbe: { nil })
    let state = installer.currentState(expectedTarget: "/some/target")
    #expect(state == .nonSymlink)
}

@Test func currentStateStaleWhenSymlinkTargetMissing() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/cli-target"
    // Note: do NOT create the file — the symlink will dangle.
    let symlink = home.path + "/.local/bin/tbd"
    try FileManager.default.createDirectory(
        atPath: (symlink as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(atPath: symlink, withDestinationPath: target)

    let installer = CLIInstaller(symlinkPath: symlink, homeDir: home.path, pathProbe: { nil })
    let state = installer.currentState(expectedTarget: target)
    #expect(state == .stale(currentTarget: target))
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

@Test func launchPromptKindNonSymlinkAlwaysSurfacedRegardlessOfDismissal() {
    let state: CLIInstallState = .nonSymlink
    #expect(state.launchPromptKind(userPreviouslyDismissed: false) == .nonSymlink)
    #expect(state.launchPromptKind(userPreviouslyDismissed: true) == .nonSymlink)
}

// MARK: - install

@Test func installCreatesParentDirectoryAndSymlink() async throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/build/TBDCLI"
    try makeFile(target)
    let symlink = home.path + "/.local/bin/tbd"

    let installer = CLIInstaller(symlinkPath: symlink, homeDir: home.path, pathProbe: { "/usr/bin:/bin" })
    let result = try await installer.install(target: target)
    #expect(result.symlinkPath == symlink)
    #expect(result.target == target)

    let dest = try FileManager.default.destinationOfSymbolicLink(atPath: symlink)
    #expect(dest == target)
}

@Test func installRefusesToReplaceDirectory() async throws {
    // FileManager.removeItem deletes directories recursively. If a directory
    // is unexpectedly at the install path, install() must refuse rather than
    // silently rm -rf based on a "Replace the file" confirmation.
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/cli"
    try makeFile(target)
    let symlink = home.path + "/.local/bin/tbd"
    // Create a directory at the symlink path with a file inside (to verify
    // we wouldn't have silently lost it).
    try FileManager.default.createDirectory(atPath: symlink, withIntermediateDirectories: true)
    try makeFile(symlink + "/important.txt")

    let installer = CLIInstaller(symlinkPath: symlink, homeDir: home.path, pathProbe: { nil })
    do {
        _ = try await installer.install(target: target)
        Issue.record("Expected install to throw when a directory exists at the path")
    } catch let error as CLIInstallerError {
        if case .symlinkCreationFailed(let reason) = error {
            #expect(reason.contains("directory"))
        } else {
            Issue.record("Wrong CLIInstallerError case: \(error)")
        }
    }
    // The directory and its contents must still be there.
    #expect(FileManager.default.fileExists(atPath: symlink + "/important.txt"))
}

@Test func installReplacesExistingSymlink() async throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let oldTarget = home.path + "/old-cli"
    let newTarget = home.path + "/new-cli"
    try makeFile(oldTarget)
    try makeFile(newTarget)
    let symlink = home.path + "/.local/bin/tbd"
    try FileManager.default.createDirectory(
        atPath: (symlink as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(atPath: symlink, withDestinationPath: oldTarget)

    let installer = CLIInstaller(symlinkPath: symlink, homeDir: home.path, pathProbe: { "/usr/bin" })
    _ = try await installer.install(target: newTarget)
    let dest = try FileManager.default.destinationOfSymbolicLink(atPath: symlink)
    #expect(dest == newTarget)
}

// MARK: - PATH detection / on-PATH branch

@Test func installReportsOnPathWhenBinDirIsPresent() async throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/cli"
    try makeFile(target)
    let symlink = home.path + "/.local/bin/tbd"

    let homePath = home.path
    let probe: @Sendable () async -> String? = {
        "/usr/bin:\(homePath)/.local/bin:/sbin"
    }
    let installer = CLIInstaller(symlinkPath: symlink, homeDir: home.path, pathProbe: probe)
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
    let symlink = home.path + "/.local/bin/tbd"

    // Path string contains the tilde-prefixed form — should still match.
    let probe: @Sendable () async -> String? = { "/usr/bin:~/.local/bin:/sbin" }
    let installer = CLIInstaller(symlinkPath: symlink, homeDir: home.path, pathProbe: probe)
    let result = try await installer.install(target: target)
    #expect(result.onPath == true)
}

// MARK: - PATH detection / off-PATH branch

@Test func installReportsOffPathAndZshRCByDefault() async throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/cli"
    try makeFile(target)
    let symlink = home.path + "/.local/bin/tbd"

    let installer = CLIInstaller(
        symlinkPath: symlink,
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
    let symlink = home.path + "/.local/bin/tbd"

    let installer = CLIInstaller(
        symlinkPath: symlink,
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
    let symlink = home.path + "/.local/bin/tbd"

    let installer = CLIInstaller(
        symlinkPath: symlink,
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
    let symlink = home.path + "/.local/bin/tbd"

    let installer = CLIInstaller(symlinkPath: symlink, homeDir: home.path, pathProbe: { nil })
    let result = try await installer.install(target: target)
    #expect(result.onPath == false)
    #expect(result.exportLine != nil)
}
