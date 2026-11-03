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
    // Installs from before the hard-link scheme created a symlink. Detecting
    // that as `.stale` lets the launch-time check offer to re-install it as
    // a hard link.
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

// MARK: - launchAction

private let recordedIdentity = CLIFileIdentity(device: 16_777_232, inode: 4_242)
private let otherIdentity = CLIFileIdentity(device: 16_777_232, inode: 9_999)

@Test func launchActionIsNoneWhenInstalled() {
    let state: CLIInstallState = .installed(target: "/bin/tbd")
    let notDismissed = state.launchAction(installedFile: recordedIdentity, recorded: recordedIdentity, userPreviouslyDismissed: false)
    let dismissed = state.launchAction(installedFile: recordedIdentity, recorded: nil, userPreviouslyDismissed: true)
    #expect(notDismissed == CLILaunchAction.none)
    #expect(dismissed == CLILaunchAction.none)
}

@Test func launchActionPromptsMissingWhenNotInstalledAndNotDismissed() {
    let state: CLIInstallState = .notInstalled
    let action = state.launchAction(installedFile: nil, recorded: recordedIdentity, userPreviouslyDismissed: false)
    #expect(action == .prompt(.missing))
}

@Test func launchActionIsNoneWhenNotInstalledAndPreviouslyDismissed() {
    let state: CLIInstallState = .notInstalled
    let action = state.launchAction(installedFile: nil, recorded: recordedIdentity, userPreviouslyDismissed: true)
    #expect(action == CLILaunchAction.none)
}

@Test func launchActionRefreshesSilentlyWhenTheStaleFileIsTheRecordedOne() {
    let state: CLIInstallState = .stale(currentTarget: "/home/.local/bin/tbd")
    // The Not-Now flag belongs to the missing prompt and changes nothing here.
    let notDismissed = state.launchAction(installedFile: recordedIdentity, recorded: recordedIdentity, userPreviouslyDismissed: false)
    let dismissed = state.launchAction(installedFile: recordedIdentity, recorded: recordedIdentity, userPreviouslyDismissed: true)
    #expect(notDismissed == .refreshSilently)
    #expect(dismissed == .refreshSilently)
}

@Test func launchActionPromptsUnrecognizedWhenTheStaleFileIsNotTheRecordedOne() {
    let state: CLIInstallState = .stale(currentTarget: "/home/.local/bin/tbd")
    let action = state.launchAction(installedFile: otherIdentity, recorded: recordedIdentity, userPreviouslyDismissed: false)
    #expect(action == .prompt(.unrecognized(current: "/home/.local/bin/tbd")))
}

@Test func launchActionPromptsUnrecognizedWhenNothingIsRecorded() {
    let state: CLIInstallState = .stale(currentTarget: "/home/.local/bin/tbd")
    let action = state.launchAction(installedFile: otherIdentity, recorded: nil, userPreviouslyDismissed: false)
    #expect(action == .prompt(.unrecognized(current: "/home/.local/bin/tbd")))
}

@Test func launchActionPromptsUnrecognizedForASymlink() {
    // A symlink has no regular-file identity, so it never matches a record,
    // not even an absent one.
    let state: CLIInstallState = .stale(currentTarget: "/old/TBDCLI")
    let withRecord = state.launchAction(installedFile: nil, recorded: recordedIdentity, userPreviouslyDismissed: false)
    let withoutRecord = state.launchAction(installedFile: nil, recorded: nil, userPreviouslyDismissed: false)
    #expect(withRecord == .prompt(.unrecognized(current: "/old/TBDCLI")))
    #expect(withoutRecord == .prompt(.unrecognized(current: "/old/TBDCLI")))
}

@Test func launchActionPromptsUnexpectedFileTypeRegardlessOfDismissal() {
    let state: CLIInstallState = .unexpectedFileType
    let notDismissed = state.launchAction(installedFile: nil, recorded: recordedIdentity, userPreviouslyDismissed: false)
    let dismissed = state.launchAction(installedFile: nil, recorded: recordedIdentity, userPreviouslyDismissed: true)
    #expect(notDismissed == .prompt(.unexpectedFileType))
    #expect(dismissed == .prompt(.unexpectedFileType))
}

// MARK: - menuPromptKind

@Test func menuPromptKindCallsTheRecordedStaleFileAnOlderVersion() {
    let state: CLIInstallState = .stale(currentTarget: "/home/.local/bin/tbd")
    let kind = state.menuPromptKind(installedFile: recordedIdentity, recorded: recordedIdentity)
    #expect(kind == .stale(current: "/home/.local/bin/tbd"))
}

@Test func menuPromptKindCallsAnUnrecordedStaleFileUnrecognized() {
    let state: CLIInstallState = .stale(currentTarget: "/home/.local/bin/tbd")
    let mismatch = state.menuPromptKind(installedFile: otherIdentity, recorded: recordedIdentity)
    let noRecord = state.menuPromptKind(installedFile: otherIdentity, recorded: nil)
    let symlink = state.menuPromptKind(installedFile: nil, recorded: recordedIdentity)
    #expect(mismatch == .unrecognized(current: "/home/.local/bin/tbd"))
    #expect(noRecord == .unrecognized(current: "/home/.local/bin/tbd"))
    #expect(symlink == .unrecognized(current: "/home/.local/bin/tbd"))
}

@Test func menuPromptKindCoversTheOtherStates() {
    let installed = CLIInstallState.installed(target: "/bin/tbd")
        .menuPromptKind(installedFile: recordedIdentity, recorded: recordedIdentity)
    let missing = CLIInstallState.notInstalled
        .menuPromptKind(installedFile: nil, recorded: recordedIdentity)
    let unexpected = CLIInstallState.unexpectedFileType
        .menuPromptKind(installedFile: nil, recorded: recordedIdentity)
    #expect(installed == nil)
    #expect(missing == .missing)
    #expect(unexpected == .unexpectedFileType)
}

// MARK: - CLIFileIdentity

@Test func fileIdentityRoundTripsThroughItsStorageString() {
    // An inode above Int64.max is why the identity is stored as a string.
    let identity = CLIFileIdentity(device: -3, inode: UInt64.max)
    let stored = identity.storageString
    #expect(stored == "-3:18446744073709551615")
    #expect(CLIFileIdentity(storageString: stored) == identity)
}

@Test func fileIdentityRejectsMalformedStorageStrings() {
    let malformed = ["", "1", "1:", ":2", "1:2:3", "a:2", "1:-2", "1:2 "]
    for text in malformed {
        #expect(CLIFileIdentity(storageString: text) == nil, "accepted \(text)")
    }
}

@Test func installedFileIdentityIsEqualForTwoHardLinksToOneFile() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/cli-target"
    try makeFile(target, contents: Data("one".utf8))
    let installPath = home.path + "/.local/bin/tbd"
    try FileManager.default.createDirectory(
        atPath: (installPath as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    try FileManager.default.linkItem(atPath: target, toPath: installPath)

    let installer = CLIInstaller(installPath: installPath, homeDir: home.path, pathProbe: { nil })
    let installed = installer.installedFileIdentity()
    let source = CLIFileIdentity(regularFileAt: target)
    #expect(installed != nil)
    #expect(installed == source)
}

@Test func installedFileIdentityDiffersForTwoSeparateFiles() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/cli-target"
    let installPath = home.path + "/.local/bin/tbd"
    try makeFile(target, contents: Data("same".utf8))
    try makeFile(installPath, contents: Data("same".utf8))

    let installer = CLIInstaller(installPath: installPath, homeDir: home.path, pathProbe: { nil })
    let installed = installer.installedFileIdentity()
    let source = CLIFileIdentity(regularFileAt: target)
    #expect(installed != nil)
    #expect(source != nil)
    #expect(installed != source)
}

@Test func installedFileIdentityIsNilForASymlinkAndForAMissingPath() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/cli-target"
    try makeFile(target)
    let installPath = home.path + "/.local/bin/tbd"

    let installer = CLIInstaller(installPath: installPath, homeDir: home.path, pathProbe: { nil })
    #expect(installer.installedFileIdentity() == nil)

    try FileManager.default.createDirectory(
        atPath: (installPath as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(atPath: installPath, withDestinationPath: target)
    // The symlink names a regular file; lstat must not follow it there.
    #expect(CLIFileIdentity(regularFileAt: target) != nil)
    #expect(installer.installedFileIdentity() == nil)
}

@Test func installedFileIdentityIsNilForADirectory() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let installPath = home.path + "/.local/bin/tbd"
    try FileManager.default.createDirectory(atPath: installPath, withIntermediateDirectories: true)

    let installer = CLIInstaller(installPath: installPath, homeDir: home.path, pathProbe: { nil })
    #expect(installer.installedFileIdentity() == nil)
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

// MARK: - link(2) error routing

@Test func installThrowsCrossDeviceLinkOnEXDEV() async throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/build/TBDCLI"
    try makeFile(target, contents: Data("binary".utf8))
    let installPath = home.path + "/.local/bin/tbd"

    let installer = CLIInstaller(
        installPath: installPath,
        homeDir: home.path,
        pathProbe: { nil },
        linkFunc: { _, _ in EXDEV }
    )
    do {
        _ = try await installer.install(target: target)
        Issue.record("expected crossDeviceLink to throw")
    } catch CLIInstallerError.crossDeviceLink(let t, let i) {
        #expect(t == target)
        #expect(i == installPath)
        // Sanity-check the user-facing message mentions the actionable bit.
        let desc = (CLIInstallerError.crossDeviceLink(target: t, installPath: i) as LocalizedError).errorDescription ?? ""
        #expect(desc.contains("different filesystems"))
    }
}

@Test func installThrowsLinkCreationFailedOnNonEXDEVError() async throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/build/TBDCLI"
    try makeFile(target, contents: Data("binary".utf8))
    let installPath = home.path + "/.local/bin/tbd"

    let installer = CLIInstaller(
        installPath: installPath,
        homeDir: home.path,
        pathProbe: { nil },
        linkFunc: { _, _ in EACCES }
    )
    do {
        _ = try await installer.install(target: target)
        Issue.record("expected linkCreationFailed to throw")
    } catch CLIInstallerError.linkCreationFailed(let msg) {
        let lower = msg.lowercased()
        #expect(lower.contains("permission") || lower.contains("denied"))
    }
}

// MARK: - Replacing a file atomically

/// The names in the install path's directory: what an install left there.
private func entriesBeside(_ installPath: String) throws -> [String] {
    let directory = (installPath as NSString).deletingLastPathComponent
    return try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
}

@Test func stagingPathIsAHiddenSiblingOfTheInstallPath() {
    let staging = CLIInstaller.stagingPath(forInstallPath: "/x/.local/bin/tbd")
    #expect(staging == "/x/.local/bin/.tbd.tbd-install")
}

/// The launch check refreshes without asking, so a refresh that fails must
/// leave the user's working `tbd` exactly as it was, and leave nothing beside
/// it.
@Test(arguments: [EXDEV, EACCES])
func aFailedLinkLeavesTheExistingFileIntact(linkError: Int32) async throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/build/TBDCLI"
    try makeFile(target, contents: Data("new".utf8))
    let installPath = home.path + "/.local/bin/tbd"
    let original = Data("#!/bin/sh\necho old\n".utf8)
    try makeFile(installPath, contents: original)
    let before = try #require(CLIFileIdentity(regularFileAt: installPath))

    let installer = CLIInstaller(
        installPath: installPath,
        homeDir: home.path,
        pathProbe: { nil },
        linkFunc: { _, _ in linkError }
    )
    await #expect(throws: CLIInstallerError.self) {
        _ = try await installer.install(target: target)
    }

    let after = CLIFileIdentity(regularFileAt: installPath)
    let contents = try Data(contentsOf: URL(fileURLWithPath: installPath))
    let entries = try entriesBeside(installPath)
    #expect(after == before)
    #expect(contents == original)
    #expect(entries == ["tbd"])
}

@Test func installReplacesAnExistingRegularFileAndLeavesNoStagingLink() async throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/build/TBDCLI"
    try makeFile(target, contents: Data("new".utf8))
    let installPath = home.path + "/.local/bin/tbd"
    try makeFile(installPath, contents: Data("old".utf8))

    let installer = CLIInstaller(installPath: installPath, homeDir: home.path, pathProbe: { nil })
    _ = try await installer.install(target: target)

    let installed = installer.installedFileIdentity()
    let source = CLIFileIdentity(regularFileAt: target)
    let entries = try entriesBeside(installPath)
    #expect(installed != nil)
    #expect(installed == source)
    #expect(entries == ["tbd"])
}

@Test func reinstallingACurrentInstallLeavesNoStagingLink() async throws {
    // The second install renames a link to `target` over another link to the
    // same file, which rename(2) may treat as nothing to do.
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/build/TBDCLI"
    try makeFile(target, contents: Data("binary".utf8))
    let installPath = home.path + "/.local/bin/tbd"

    let installer = CLIInstaller(installPath: installPath, homeDir: home.path, pathProbe: { nil })
    _ = try await installer.install(target: target)
    _ = try await installer.install(target: target)

    let installed = installer.installedFileIdentity()
    let source = CLIFileIdentity(regularFileAt: target)
    let entries = try entriesBeside(installPath)
    #expect(installed == source)
    #expect(entries == ["tbd"])
}

@Test func replaceLinkLinksWithoutRunningThePathProbe() throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/build/TBDCLI"
    try makeFile(target, contents: Data("new".utf8))
    let installPath = home.path + "/.local/bin/tbd"
    try makeFile(installPath, contents: Data("old".utf8))

    let installer = CLIInstaller(
        installPath: installPath,
        homeDir: home.path,
        pathProbe: {
            Issue.record("replaceLink ran the PATH probe")
            return nil
        }
    )
    try installer.replaceLink(target: target)

    let installed = installer.installedFileIdentity()
    let source = CLIFileIdentity(regularFileAt: target)
    let entries = try entriesBeside(installPath)
    #expect(installed != nil)
    #expect(installed == source)
    #expect(entries == ["tbd"])
}

@Test func installRemovesAStagingLinkLeftByAnInterruptedInstall() async throws {
    let home = try TempHome()
    defer { home.cleanup() }
    let target = home.path + "/build/TBDCLI"
    try makeFile(target, contents: Data("binary".utf8))
    let installPath = home.path + "/.local/bin/tbd"
    try makeFile(installPath, contents: Data("old".utf8))
    try makeFile(CLIInstaller.stagingPath(forInstallPath: installPath), contents: Data("leftover".utf8))

    let installer = CLIInstaller(installPath: installPath, homeDir: home.path, pathProbe: { nil })
    _ = try await installer.install(target: target)

    let installed = installer.installedFileIdentity()
    let source = CLIFileIdentity(regularFileAt: target)
    let entries = try entriesBeside(installPath)
    #expect(installed == source)
    #expect(entries == ["tbd"])
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
