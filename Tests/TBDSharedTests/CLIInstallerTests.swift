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

// MARK: - install

@Test func installCreatesParentDirectoryAndSymlink() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/build/TBDCLI"
    try makeFile(target)
    let symlink = home.path + "/.local/bin/tbd"

    let installer = CLIInstaller(symlinkPath: symlink, homeDir: home.path, pathProbe: { "/usr/bin:/bin" })
    let result = try installer.install(target: target)
    #expect(result.symlinkPath == symlink)
    #expect(result.target == target)

    let dest = try FileManager.default.destinationOfSymbolicLink(atPath: symlink)
    #expect(dest == target)
}

@Test func installReplacesExistingSymlink() throws {
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
    _ = try installer.install(target: newTarget)
    let dest = try FileManager.default.destinationOfSymbolicLink(atPath: symlink)
    #expect(dest == newTarget)
}

// MARK: - PATH detection / on-PATH branch

@Test func installReportsOnPathWhenBinDirIsPresent() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/cli"
    try makeFile(target)
    let symlink = home.path + "/.local/bin/tbd"

    let probe: () -> String? = {
        "/usr/bin:\(home.path)/.local/bin:/sbin"
    }
    let installer = CLIInstaller(symlinkPath: symlink, homeDir: home.path, pathProbe: probe)
    let result = try installer.install(target: target)
    #expect(result.onPath == true)
    #expect(result.suggestedShellRC == nil)
    #expect(result.exportLine == nil)
}

@Test func installReportsOnPathWhenBinDirAppearsTildeExpanded() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/cli"
    try makeFile(target)
    let symlink = home.path + "/.local/bin/tbd"

    // Path string contains the tilde-prefixed form — should still match.
    let probe: () -> String? = { "/usr/bin:~/.local/bin:/sbin" }
    let installer = CLIInstaller(symlinkPath: symlink, homeDir: home.path, pathProbe: probe)
    let result = try installer.install(target: target)
    #expect(result.onPath == true)
}

// MARK: - PATH detection / off-PATH branch

@Test func installReportsOffPathAndZshRCByDefault() throws {
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
    let result = try installer.install(target: target)
    #expect(result.onPath == false)
    #expect(result.suggestedShellRC == "~/.zshrc")
    #expect(result.exportLine == "export PATH=\"$HOME/.local/bin:$PATH\"")
}

@Test func installReportsOffPathBashProfileForBash() throws {
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
    let result = try installer.install(target: target)
    #expect(result.onPath == false)
    #expect(result.suggestedShellRC == "~/.bash_profile")
    #expect(result.exportLine == "export PATH=\"$HOME/.local/bin:$PATH\"")
}

@Test func installReportsOffPathFishConfigForFish() throws {
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
    let result = try installer.install(target: target)
    #expect(result.onPath == false)
    #expect(result.suggestedShellRC == "~/.config/fish/config.fish")
    #expect(result.exportLine == "set -gx PATH $HOME/.local/bin $PATH")
}

@Test func pathProbeReturningNilTreatedAsOffPath() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/cli"
    try makeFile(target)
    let symlink = home.path + "/.local/bin/tbd"

    let installer = CLIInstaller(symlinkPath: symlink, homeDir: home.path, pathProbe: { nil })
    let result = try installer.install(target: target)
    #expect(result.onPath == false)
    #expect(result.exportLine != nil)
}
