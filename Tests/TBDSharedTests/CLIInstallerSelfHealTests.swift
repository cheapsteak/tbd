import Testing
import Foundation
@testable import TBDShared

private struct TempArea {
    let url: URL
    var path: String { url.path }
    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-cli-installer-selfheal-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base
    }
    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

private func touch(_ path: String) throws {
    let dir = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data())
}

private func makeInstaller(home: TempArea, installPath: String) -> CLIInstaller {
    CLIInstaller(installPath: installPath, homeDir: home.path, pathProbe: { nil })
}

@Test func repairIfDanglingNoInstallPresent() async throws {
    let home = try TempArea()
    defer { home.cleanup() }
    let installer = makeInstaller(home: home, installPath: home.path + "/.local/bin/tbd")
    let outcome = try await installer.repairIfDangling(daemonExecutablePath: home.path + "/nope/TBDDaemon")
    #expect(outcome == .notInstalled)
}

@Test func repairIfDanglingLegacySymlinkHealthyIsNoop() async throws {
    let home = try TempArea()
    defer { home.cleanup() }
    let target = home.path + "/live/TBDCLI"
    try touch(target)
    let installPath = home.path + "/.local/bin/tbd"
    try FileManager.default.createDirectory(atPath: (installPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: installPath, withDestinationPath: target)

    let installer = makeInstaller(home: home, installPath: installPath)
    let outcome = try await installer.repairIfDangling(daemonExecutablePath: home.path + "/other/TBDDaemon")
    #expect(outcome == .healthy(target: target))
    // Symlink still points at original target (left untouched — upgrade
    // happens via launch-time prompt, not the self-heal hook).
    let dest = try FileManager.default.destinationOfSymbolicLink(atPath: installPath)
    #expect(dest == target)
}

@Test func repairIfDanglingHardLinkInstallReportsHealthy() async throws {
    // With hard links the "dangle" case can't happen — the install path
    // owns its own data. Self-heal should be a no-op.
    let home = try TempArea()
    defer { home.cleanup() }
    let target = home.path + "/live/TBDCLI"
    try touch(target)
    let installPath = home.path + "/.local/bin/tbd"
    let installer = makeInstaller(home: home, installPath: installPath)
    _ = try await installer.install(target: target)

    // Remove the source — hard link keeps install path alive.
    try FileManager.default.removeItem(atPath: target)

    let outcome = try await installer.repairIfDangling(daemonExecutablePath: home.path + "/anything/TBDDaemon")
    #expect(outcome == .healthy(target: installPath))
    #expect(FileManager.default.fileExists(atPath: installPath))
}

@Test func repairIfDanglingRepairsLegacyDanglingSymlinkToDaemonSibling() async throws {
    let home = try TempArea()
    defer { home.cleanup() }

    // Old "worktree build" with TBDCLI then deleted to leave a dangling link.
    let oldDir = home.path + "/old-worktree/.build/debug"
    let oldTarget = oldDir + "/TBDCLI"
    try touch(oldTarget)
    let installPath = home.path + "/.local/bin/tbd"
    try FileManager.default.createDirectory(atPath: (installPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: installPath, withDestinationPath: oldTarget)
    try FileManager.default.removeItem(atPath: home.path + "/old-worktree")

    // New daemon path with a live sibling TBDCLI.
    let newDaemon = home.path + "/new-worktree/.build/debug/TBDDaemon"
    let newCLI = home.path + "/new-worktree/.build/debug/TBDCLI"
    try touch(newCLI)

    let installer = makeInstaller(home: home, installPath: installPath)
    let outcome = try await installer.repairIfDangling(daemonExecutablePath: newDaemon)
    #expect(outcome == .repaired(target: newCLI))

    // After repair the install path is now a hard link, not a symlink.
    var st = stat()
    #expect(lstat(installPath, &st) == 0)
    #expect((st.st_mode & S_IFMT) == S_IFREG)
    #expect(FileManager.default.fileExists(atPath: installPath))
}

@Test func repairIfDanglingReportsMissingDaemonSibling() async throws {
    let home = try TempArea()
    defer { home.cleanup() }

    let oldTarget = home.path + "/old/TBDCLI"
    try touch(oldTarget)
    let installPath = home.path + "/.local/bin/tbd"
    try FileManager.default.createDirectory(atPath: (installPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: installPath, withDestinationPath: oldTarget)
    try FileManager.default.removeItem(atPath: oldTarget)

    let daemonPath = home.path + "/ghost/TBDDaemon"
    let installer = makeInstaller(home: home, installPath: installPath)
    let outcome = try await installer.repairIfDangling(daemonExecutablePath: daemonPath)

    let expectedCLI = home.path + "/ghost/TBDCLI"
    #expect(outcome == .noDaemonSibling(path: expectedCLI))

    // Symlink left untouched.
    let dest = try FileManager.default.destinationOfSymbolicLink(atPath: installPath)
    #expect(dest == oldTarget)
}

@Test func repairIfDanglingDetectsUnexpectedFileTypeForDirectory() async throws {
    let home = try TempArea()
    defer { home.cleanup() }
    let installPath = home.path + "/.local/bin/tbd"
    try FileManager.default.createDirectory(atPath: installPath, withIntermediateDirectories: true)
    let installer = makeInstaller(home: home, installPath: installPath)
    let outcome = try await installer.repairIfDangling(daemonExecutablePath: home.path + "/whatever/TBDDaemon")
    #expect(outcome == .unexpectedFileType)
}
