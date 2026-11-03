import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// Counts calls to an injected PATH probe. A class behind a lock, because the
/// probe is a `@Sendable` closure that runs off the main actor and must not
/// capture a local `var`. Declared outside the `@MainActor` suite for the same
/// reason.
private final class ProbeCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int {
        lock.withLock { calls }
    }

    /// A probe that records each call and reports an empty PATH.
    var probe: @Sendable () async -> String? {
        { [self] in
            lock.withLock { calls += 1 }
            return nil
        }
    }
}

/// The launch-time CLI check: what it records, when it refreshes without
/// asking, and that a refresh it cannot finish leaves the file alone.
///
/// Every case runs over real files in its own scratch directory and its own
/// throwaway `UserDefaults` suite. Nothing touches `~/.local/bin`, and every
/// installer gets a stub PATH probe, so no login shell is spawned.
@MainActor
@Suite("CLI launch check")
struct CLILaunchCheckTests {
    /// A scratch directory holding the daemon's TBDCLI and an install path
    /// beside it.
    private struct Scratch {
        let root: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("cli-launch-check-\(UUID().uuidString)")
            let fm = FileManager.default
            try fm.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
            try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try Data("new build".utf8).write(to: URL(fileURLWithPath: target))
        }

        /// The TBDCLI beside the running daemon.
        var target: String { root.appendingPathComponent("build/TBDCLI").path }
        var installPath: String { root.appendingPathComponent("bin/tbd").path }

        func installer(
            pathProbe: @escaping @Sendable () async -> String? = { nil },
            linkFunc: (@Sendable (String, String) -> Int32)? = nil
        ) -> CLIInstaller {
            CLIInstaller(installPath: installPath, homeDir: root.path, pathProbe: pathProbe, linkFunc: linkFunc)
        }

        /// A regular file of its own at the install path, as an older build's
        /// link is once the daemon's TBDCLI has been rebuilt.
        func placeStaleFile() throws {
            try Data("old build".utf8).write(to: URL(fileURLWithPath: installPath))
        }

        func installedContents() throws -> String {
            try String(contentsOfFile: installPath, encoding: .utf8)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static let suiteLabel = "TBDAppTests.CLILaunchCheck"

    private func record(_ identity: CLIFileIdentity, in defaults: UserDefaults) {
        defaults.set(identity.storageString, forKey: CLILaunchCheck.recordedIdentityKey)
    }

    // MARK: - Up to date

    @Test func anUpToDateInstallRecordsItsIdentity() throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let suite = TestDefaultsSuite(Self.suiteLabel)
        defer { suite.tearDown() }
        try FileManager.default.linkItem(atPath: scratch.target, toPath: scratch.installPath)
        let check = CLILaunchCheck(installer: scratch.installer(), userDefaults: suite.defaults)
        #expect(check.recordedIdentity == nil)

        let outcome = check.run(target: scratch.target, userPreviouslyDismissed: false)

        guard case .upToDate = outcome else {
            Issue.record("expected .upToDate, got \(outcome)")
            return
        }
        let recorded = check.recordedIdentity
        let source = CLIFileIdentity(regularFileAt: scratch.target)
        #expect(recorded != nil)
        #expect(recorded == source)
    }

    // MARK: - Stale

    @Test func aStaleFileWithTheRecordedIdentityIsRefreshedSilently() throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let suite = TestDefaultsSuite(Self.suiteLabel)
        defer { suite.tearDown() }
        try scratch.placeStaleFile()
        let stale = try #require(CLIFileIdentity(regularFileAt: scratch.installPath))
        record(stale, in: suite.defaults)
        let check = CLILaunchCheck(installer: scratch.installer(), userDefaults: suite.defaults)

        let outcome = check.run(target: scratch.target, userPreviouslyDismissed: false)

        guard case .refreshedSilently = outcome else {
            Issue.record("expected .refreshedSilently, got \(outcome)")
            return
        }
        let installed = CLIFileIdentity(regularFileAt: scratch.installPath)
        let source = CLIFileIdentity(regularFileAt: scratch.target)
        let recorded = check.recordedIdentity
        #expect(source != nil)
        #expect(installed == source)
        #expect(recorded == source)
        #expect(recorded != stale)
    }

    @Test func aStaleFileWithADifferentIdentityIsAskedAboutAndLeftAlone() throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let suite = TestDefaultsSuite(Self.suiteLabel)
        defer { suite.tearDown() }
        try scratch.placeStaleFile()
        let stale = try #require(CLIFileIdentity(regularFileAt: scratch.installPath))
        let someOtherFile = CLIFileIdentity(device: stale.device, inode: stale.inode &+ 1)
        record(someOtherFile, in: suite.defaults)
        let check = CLILaunchCheck(installer: scratch.installer(), userDefaults: suite.defaults)

        let outcome = check.run(target: scratch.target, userPreviouslyDismissed: false)

        guard case .prompt(.unrecognized(let current)) = outcome else {
            Issue.record("expected .prompt(.unrecognized), got \(outcome)")
            return
        }
        #expect(current == scratch.installPath)
        let installed = CLIFileIdentity(regularFileAt: scratch.installPath)
        let contents = try scratch.installedContents()
        let recorded = check.recordedIdentity
        #expect(installed == stale)
        #expect(contents == "old build")
        #expect(recorded == someOtherFile)
    }

    @Test func aStaleFileWithNoRecordIsAskedAboutAndLeftAlone() throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let suite = TestDefaultsSuite(Self.suiteLabel)
        defer { suite.tearDown() }
        try scratch.placeStaleFile()
        let stale = try #require(CLIFileIdentity(regularFileAt: scratch.installPath))
        let check = CLILaunchCheck(installer: scratch.installer(), userDefaults: suite.defaults)

        let outcome = check.run(target: scratch.target, userPreviouslyDismissed: false)

        guard case .prompt(.unrecognized) = outcome else {
            Issue.record("expected .prompt(.unrecognized), got \(outcome)")
            return
        }
        let installed = CLIFileIdentity(regularFileAt: scratch.installPath)
        let contents = try scratch.installedContents()
        #expect(installed == stale)
        #expect(contents == "old build")
        #expect(check.recordedIdentity == nil)
    }

    @Test func aSymlinkIsAskedAboutEvenWithARecord() throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let suite = TestDefaultsSuite(Self.suiteLabel)
        defer { suite.tearDown() }
        try FileManager.default.createSymbolicLink(atPath: scratch.installPath, withDestinationPath: scratch.target)
        // Recorded as the very file the symlink names: a symlink still has no
        // identity of its own to match it.
        let source = try #require(CLIFileIdentity(regularFileAt: scratch.target))
        record(source, in: suite.defaults)
        let check = CLILaunchCheck(installer: scratch.installer(), userDefaults: suite.defaults)

        let outcome = check.run(target: scratch.target, userPreviouslyDismissed: false)

        guard case .prompt(.unrecognized) = outcome else {
            Issue.record("expected .prompt(.unrecognized), got \(outcome)")
            return
        }
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: scratch.installPath)
        #expect(destination == scratch.target)
    }

    @Test func aFailedSilentRefreshLeavesTheFileAndTheRecordAlone() throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let suite = TestDefaultsSuite(Self.suiteLabel)
        defer { suite.tearDown() }
        try scratch.placeStaleFile()
        let stale = try #require(CLIFileIdentity(regularFileAt: scratch.installPath))
        record(stale, in: suite.defaults)
        let check = CLILaunchCheck(
            installer: scratch.installer(linkFunc: { _, _ in EXDEV }),
            userDefaults: suite.defaults
        )

        let outcome = check.run(target: scratch.target, userPreviouslyDismissed: false)

        guard case .silentRefreshFailed(let error) = outcome else {
            Issue.record("expected .silentRefreshFailed, got \(outcome)")
            return
        }
        let installerError = error as? CLIInstallerError
        let expectedError = CLIInstallerError.crossDeviceLink(target: scratch.target, installPath: scratch.installPath)
        #expect(installerError == expectedError)
        let installed = CLIFileIdentity(regularFileAt: scratch.installPath)
        let contents = try scratch.installedContents()
        let recorded = check.recordedIdentity
        #expect(installed == stale)
        #expect(contents == "old build")
        #expect(recorded == stale)
    }

    /// The PATH probe starts the user's login shell, and a silent refresh has
    /// nowhere to show its answer, so it must not run it. The second half is
    /// the control: the same probe does count a prompted install's call, so a
    /// zero above is not a probe that never records.
    @Test func aSilentRefreshDoesNotRunThePathProbe() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let suite = TestDefaultsSuite(Self.suiteLabel)
        defer { suite.tearDown() }
        try scratch.placeStaleFile()
        let stale = try #require(CLIFileIdentity(regularFileAt: scratch.installPath))
        record(stale, in: suite.defaults)
        let probeCalls = ProbeCalls()
        let installer = scratch.installer(pathProbe: probeCalls.probe)
        let check = CLILaunchCheck(installer: installer, userDefaults: suite.defaults)

        let outcome = check.run(target: scratch.target, userPreviouslyDismissed: false)

        guard case .refreshedSilently = outcome else {
            Issue.record("expected .refreshedSilently, got \(outcome)")
            return
        }
        let callsDuringRefresh = probeCalls.count
        #expect(callsDuringRefresh == 0)

        _ = try await installer.install(target: scratch.target)
        let callsDuringInstall = probeCalls.count
        #expect(callsDuringInstall == 1)
    }

    // MARK: - Missing

    @Test func aMissingCLIIsAskedAboutUnlessTheUserDeclinedBefore() throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let suite = TestDefaultsSuite(Self.suiteLabel)
        defer { suite.tearDown() }
        let check = CLILaunchCheck(installer: scratch.installer(), userDefaults: suite.defaults)

        let notDismissed = check.run(target: scratch.target, userPreviouslyDismissed: false)
        let dismissed = check.run(target: scratch.target, userPreviouslyDismissed: true)

        if case .prompt(.missing) = notDismissed {} else {
            Issue.record("expected .prompt(.missing), got \(notDismissed)")
        }
        if case .nothing = dismissed {} else {
            Issue.record("expected .nothing after a Not Now, got \(dismissed)")
        }
        let installPathExists = FileManager.default.fileExists(atPath: scratch.installPath)
        #expect(!installPathExists)
    }

    // MARK: - Recording after an install

    @Test func recordingAfterAnInstallStoresTheNewIdentity() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let suite = TestDefaultsSuite(Self.suiteLabel)
        defer { suite.tearDown() }
        try scratch.placeStaleFile()
        let stale = try #require(CLIFileIdentity(regularFileAt: scratch.installPath))
        record(stale, in: suite.defaults)
        let installer = scratch.installer()
        let check = CLILaunchCheck(installer: installer, userDefaults: suite.defaults)

        _ = try await installer.install(target: scratch.target)
        check.recordInstalledIdentity()

        let recorded = check.recordedIdentity
        let source = CLIFileIdentity(regularFileAt: scratch.target)
        let stored = suite.defaults.string(forKey: CLILaunchCheck.recordedIdentityKey)
        #expect(source != nil)
        #expect(recorded == source)
        #expect(stored == source?.storageString)
    }
}
